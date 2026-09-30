#!/usr/bin/env python3
"""把 CI 产出的安装包推到 Cloudflare R2（dl.miaomiaowux.com/meowx/），并更新 latest.json。

latest.json 是 App 检查更新读的清单（lib/common/request.dart checkForUpdate），格式：
  {"platforms": {"<platform>": {"version", "build", "releasedAt", "files": [{kind, arch, name, url, size, sha256}]}},
   "updatedAt": ...}
同一个文件里还有 MeowX 其它端（macos）的条目，由别的仓库写——这里只改本次发布的平台，其余原样保留。

顺序：先传包，再改清单（清单永远不会指向还没传完的包）；清单用 If-Match 条件写，别的仓库同时发版时重读重试，
不互相覆盖；最后逐个校验公网地址的大小与 SHA-256。

依赖：python3 + aws cli（GitHub runner 自带）。环境变量：R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY，
可选 R2_BUCKET（默认 mmwx-dl）。

用法：
  python3 scripts/publish_cdn.py --dist dist --version 0.1.6 --build 7
  python3 scripts/publish_cdn.py --dist dist --version 0.1.6 --build 7 --dry-run   # 只打印，不写 R2
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

PUBLIC_BASE = 'https://dl.miaomiaowux.com'
PREFIX = 'meowx'
MANIFEST_KEY = f'{PREFIX}/latest.json'

# MeowX-<version>-<platform>-<rest>；rest 决定 kind / arch
_NAME = re.compile(r'^MeowX-(?P<version>[0-9][^-]*)-(?P<platform>android|windows)-(?P<rest>.+)$')


def classify(name: str) -> dict | None:
    """从文件名认出平台 / 版本 / kind / arch；认不出（符号表、日志等）返回 None。"""
    m = _NAME.match(name)
    if not m:
        return None
    platform, rest = m['platform'], m['rest']
    if platform == 'android':
        if not rest.endswith('.apk'):
            return None
        return {'platform': platform, 'version': m['version'], 'kind': 'apk', 'arch': rest[: -len('.apk')]}
    for suffix, kind in (('-setup.exe', 'setup'), ('-portable.zip', 'portable')):
        if rest.endswith(suffix):
            return {'platform': platform, 'version': m['version'], 'kind': kind, 'arch': rest[: -len(suffix)]}
    return None


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r'\d+', v.split('+')[0]))


def merge_manifest(manifest: dict, platform: str, version: str, build: str, files: list[dict], now: str) -> dict:
    """把一个平台的新条目并进清单。

    - 新版本：整条替换（旧版本的包不再列出）
    - 同版本（补传某个架构、重跑）：按文件名合并，同名覆盖
    - 比线上旧：拒绝（避免在老提交上手动构建把所有人「更新」回旧版）
    """
    platforms = dict(manifest.get('platforms') or {})
    current = platforms.get(platform) or {}
    current_version = str(current.get('version') or '')
    if current_version and version_key(version) < version_key(current_version):
        raise SystemExit(f'{platform}: 线上已是 {current_version}，不发布更旧的 {version}')
    if current_version == version:
        by_name = {f['name']: f for f in current.get('files') or []}
        by_name.update({f['name']: f for f in files})
        merged = sorted(by_name.values(), key=lambda f: f['name'])
    else:
        merged = sorted(files, key=lambda f: f['name'])
    platforms[platform] = {'version': version, 'build': build, 'releasedAt': now, 'files': merged}
    return {**manifest, 'platforms': platforms, 'updatedAt': now}


def collect(dist: Path, version: str) -> dict[str, list[tuple[Path, dict]]]:
    by_platform: dict[str, list[tuple[Path, dict]]] = {}
    for path in sorted(dist.rglob('*')):
        info = classify(path.name) if path.is_file() else None
        if info is None:
            continue
        if info['version'] != version:
            raise SystemExit(f'{path.name} 的版本不是 {version}（pubspec 与产物不一致？）')
        by_platform.setdefault(info['platform'], []).append((path, info))
    return by_platform


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def file_entry(path: Path, info: dict) -> dict:
    return {
        'kind': info['kind'],
        'arch': info['arch'],
        'name': path.name,
        'url': f"{PUBLIC_BASE}/{PREFIX}/{info['platform']}/{path.name}",
        'size': path.stat().st_size,
        'sha256': sha256_of(path),
    }


class R2:
    def __init__(self) -> None:
        missing = [k for k in ('R2_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY') if not os.environ.get(k)]
        if missing:
            raise SystemExit(f'缺少仓库 secret：{", ".join(missing)}')
        self.bucket = os.environ.get('R2_BUCKET') or 'mmwx-dl'
        self.endpoint = f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com"
        self.env = {
            **os.environ,
            'AWS_ACCESS_KEY_ID': os.environ['R2_ACCESS_KEY_ID'],
            'AWS_SECRET_ACCESS_KEY': os.environ['R2_SECRET_ACCESS_KEY'],
            'AWS_DEFAULT_REGION': 'auto',
            # aws cli 2.23 起默认带 CRC 校验头，R2 不一定认；只在 API 要求时才算
            'AWS_REQUEST_CHECKSUM_CALCULATION': 'when_required',
            'AWS_RESPONSE_CHECKSUM_VALIDATION': 'when_required',
        }

    def _aws(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ['aws', '--endpoint-url', self.endpoint, *args],
            env=self.env, capture_output=True, text=True,
        )

    def put_file(self, key: str, path: Path, content_type: str, cache_control: str) -> None:
        r = self._aws('s3api', 'put-object', '--bucket', self.bucket, '--key', key, '--body', str(path),
                      '--content-type', content_type, '--cache-control', cache_control)
        if r.returncode != 0:
            raise SystemExit(f'上传 {key} 失败：{r.stderr.strip()}')

    def get_manifest(self) -> tuple[dict, str | None]:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'latest.json'
            r = self._aws('s3api', 'get-object', '--bucket', self.bucket, '--key', MANIFEST_KEY, str(out))
            if r.returncode != 0:
                if 'NoSuchKey' in r.stderr or 'Not Found' in r.stderr:
                    return {}, None
                raise SystemExit(f'读取 {MANIFEST_KEY} 失败：{r.stderr.strip()}')
            etag = json.loads(r.stdout).get('ETag')
            return json.loads(out.read_text(encoding='utf-8')), etag

    def put_manifest(self, manifest: dict, etag: str | None) -> bool:
        """条件写：线上被别人改过（ETag 变了）返回 False 让调用方重读重试。"""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'latest.json'
            out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            cond = ['--if-match', etag] if etag else ['--if-none-match', '*']
            r = self._aws('s3api', 'put-object', '--bucket', self.bucket, '--key', MANIFEST_KEY, '--body', str(out),
                          '--content-type', 'application/json', '--cache-control', 'no-cache', *cond)
            if r.returncode == 0:
                return True
            if 'PreconditionFailed' in r.stderr or '412' in r.stderr:
                return False
            raise SystemExit(f'写 {MANIFEST_KEY} 失败：{r.stderr.strip()}')


def _open(url: str, timeout: int):
    # Cloudflare 会拦 Python-urllib 默认 UA（403），带一个明确的 UA
    req = urllib.request.Request(f'{url}?t={int(time.time())}', headers={'User-Agent': 'MeowX-publish/1.0'})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_public_manifest() -> dict:
    with _open(f'{PUBLIC_BASE}/{MANIFEST_KEY}', 30) as resp:
        return json.load(resp)


def verify_public(entries: list[dict]) -> None:
    """公网逐个下回来比大小与 SHA-256（走 CDN，确认用户真能下到对的包）。"""
    for e in entries:
        h = hashlib.sha256()
        size = 0
        with _open(e['url'], 300) as resp:
            for chunk in iter(lambda: resp.read(1 << 20), b''):
                h.update(chunk)
                size += len(chunk)
        if size != e['size'] or h.hexdigest() != e['sha256']:
            raise SystemExit(f"公网校验失败：{e['name']} size={size} sha256={h.hexdigest()}")
        print(f"  OK {e['name']} {size} bytes")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dist', required=True, type=Path)
    ap.add_argument('--version', required=True)
    ap.add_argument('--build', required=True)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    by_platform = collect(args.dist, args.version)
    if not by_platform:
        raise SystemExit(f'{args.dist} 里没有 MeowX-{args.version}-* 安装包')
    now = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    entries = {p: [file_entry(path, info) for path, info in items] for p, items in by_platform.items()}

    if args.dry_run:
        manifest = fetch_public_manifest()
        for platform, files in entries.items():
            manifest = merge_manifest(manifest, platform, args.version, args.build, files, now)
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        return

    r2 = R2()
    # 先查一遍版本，旧版本在传包之前就拦下
    current, _ = r2.get_manifest()
    for platform, files in entries.items():
        merge_manifest(current, platform, args.version, args.build, files, now)

    for platform, items in by_platform.items():
        for path, info in items:
            key = f'{PREFIX}/{platform}/{path.name}'
            ctype = {'apk': 'application/vnd.android.package-archive', 'setup': 'application/vnd.microsoft.portable-executable',
                     'portable': 'application/zip'}[info['kind']]
            print(f'上传 {key}')
            r2.put_file(key, path, ctype, 'public, max-age=31536000, immutable')

    for attempt in range(6):
        manifest, etag = r2.get_manifest()
        for platform, files in entries.items():
            manifest = merge_manifest(manifest, platform, args.version, args.build, files, now)
        if r2.put_manifest(manifest, etag):
            break
        print('latest.json 被并发修改，重读重试')
        time.sleep(2 + attempt * 2)
    else:
        raise SystemExit('latest.json 多次条件写冲突，放弃')
    print(f'已更新 {MANIFEST_KEY}：' + ', '.join(f'{p} {args.version}' for p in entries))

    print('校验公网地址：')
    verify_public([e for files in entries.values() for e in files])
    published = fetch_public_manifest()
    for platform in entries:
        got = published['platforms'][platform]['version']
        if got != args.version:
            raise SystemExit(f'公网 latest.json 的 {platform} 还是 {got}（CDN 缓存？）')
    print('完成')


if __name__ == '__main__':
    sys.exit(main())
