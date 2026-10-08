"""publish_cdn.py 的纯逻辑单测：python3 -m unittest scripts/test_publish_cdn.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import tempfile

from publish_cdn import classify, collect, merge_manifest, version_key  # noqa: E402

NOW = '2026-09-30T00:00:00Z'


def f(name, sha='x'):
    return {'kind': 'apk', 'arch': 'a', 'name': name, 'url': 'u', 'size': 1, 'sha256': sha}


class ClassifyTest(unittest.TestCase):
    def test_android(self):
        self.assertEqual(
            classify('MeowX-0.1.6-android-arm64-v8a.apk'),
            {'platform': 'android', 'version': '0.1.6', 'kind': 'apk', 'arch': 'arm64-v8a'},
        )
        self.assertEqual(classify('MeowX-0.1.6-android-universal.apk')['arch'], 'universal')

    def test_windows(self):
        self.assertEqual(classify('MeowX-0.1.6-windows-amd64-setup.exe')['kind'], 'setup')
        p = classify('MeowX-0.1.6-windows-amd64-portable.zip')
        self.assertEqual((p['kind'], p['arch']), ('portable', 'amd64'))

    def test_ignores_other_files(self):
        for name in ('MeowX-0.1.6-android-arm64-v8a.apk.sha1', 'output-metadata.json',
                     'MeowX-0.1.6-macos-arm64.dmg', 'MeowX-0.1.6-windows-amd64.msix'):
            self.assertIsNone(classify(name), name)


class MergeTest(unittest.TestCase):
    base = {
        'platforms': {
            'macos': {'version': '0.3.2', 'build': '40', 'files': [f('mac.dmg')]},
            'android': {'version': '0.1.5', 'files': [f('MeowX-0.1.5-android-arm64-v8a.apk')]},
        },
        'updatedAt': 'old',
    }

    def test_new_version_replaces_platform_and_keeps_others(self):
        m = merge_manifest(self.base, 'android', '0.1.6', '7', [f('MeowX-0.1.6-android-arm64-v8a.apk')], NOW)
        self.assertEqual(m['platforms']['macos'], self.base['platforms']['macos'])
        a = m['platforms']['android']
        self.assertEqual((a['version'], a['build'], a['releasedAt']), ('0.1.6', '7', NOW))
        self.assertEqual([x['name'] for x in a['files']], ['MeowX-0.1.6-android-arm64-v8a.apk'])
        self.assertEqual(m['updatedAt'], NOW)

    def test_same_version_merges_by_name(self):
        m = merge_manifest(self.base, 'android', '0.1.5', '6', [
            f('MeowX-0.1.5-android-universal.apk'),
            f('MeowX-0.1.5-android-arm64-v8a.apk', sha='new'),
        ], NOW)
        files = {x['name']: x for x in m['platforms']['android']['files']}
        self.assertEqual(set(files), {'MeowX-0.1.5-android-arm64-v8a.apk', 'MeowX-0.1.5-android-universal.apk'})
        self.assertEqual(files['MeowX-0.1.5-android-arm64-v8a.apk']['sha256'], 'new')

    def test_new_platform(self):
        m = merge_manifest(self.base, 'windows', '0.1.6', '7', [f('w.exe')], NOW)
        self.assertEqual(m['platforms']['windows']['version'], '0.1.6')

    def test_refuses_downgrade(self):
        with self.assertRaises(SystemExit):
            merge_manifest(self.base, 'android', '0.1.4', '5', [f('x.apk')], NOW)

    def test_does_not_mutate_input(self):
        merge_manifest(self.base, 'android', '0.1.6', '7', [f('y.apk')], NOW)
        self.assertEqual(self.base['platforms']['android']['version'], '0.1.5')

    def test_version_key(self):
        self.assertLess(version_key('0.1.9'), version_key('0.1.10'))
        self.assertEqual(version_key('0.1.6+7'), (0, 1, 6))


class CollectTest(unittest.TestCase):
    """dist/ 目录 → 各平台的包。CI 的 download-artifact 必须带 skip-decompress，便携版才是一个 zip 文件。"""

    def _dist(self, names):
        root = Path(tempfile.mkdtemp())
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'x')
        return root

    def kinds(self, dist, platform):
        return sorted(info['kind'] for _, info in collect(dist, '0.1.9').get(platform, []))

    def test_setup_and_portable_files(self):
        dist = self._dist([
            'MeowX-0.1.9-windows-amd64-setup.exe', 'MeowX-0.1.9-windows-amd64-portable.zip',
            'MeowX-0.1.9-android-arm64-v8a.apk', 'MeowX-0.1.9-android-universal.apk',
        ])
        self.assertEqual(self.kinds(dist, 'windows'), ['portable', 'setup'])
        self.assertEqual(self.kinds(dist, 'android'), ['apk', 'apk'])

    def test_unpacked_portable_is_not_a_package(self):
        # 便携版 zip 被自动解压成 dist/MeowX/…（0.1.7 – 0.1.9 三次发版都这样漏掉）：散文件认不成包，
        # 所以工作流里有一步「Check Windows packages」在这种情况下直接失败，而不是悄悄只发安装版。
        dist = self._dist(['MeowX-0.1.9-windows-amd64-setup.exe', 'MeowX/MeowX.exe', 'MeowX/portable', 'MeowX/data/flutter_assets/x'])
        self.assertEqual(self.kinds(dist, 'windows'), ['setup'])

    def test_version_mismatch_is_fatal(self):
        dist = self._dist(['MeowX-0.1.8-windows-amd64-setup.exe'])
        with self.assertRaises(SystemExit):
            collect(dist, '0.1.9')


if __name__ == '__main__':
    unittest.main()
