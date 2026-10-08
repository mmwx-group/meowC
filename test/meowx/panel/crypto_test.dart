import 'dart:convert';
import 'dart:io';

import 'package:bett_box/meowx/panel/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 对拍向量由 CryptoKit 从规格生成（test/meowx/fixtures/vectors.json），逐字节比较。
void main() {
  final v = json.decode(File('test/meowx/fixtures/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final masterPub = base64.decode(v['masterPub'] as String);
  final ePriv = base64.decode(v['ePriv'] as String);

  test('内置信任根是合法的 32 字节 Ed25519 公钥', () {
    expect(base64.decode(MeowCrypto.trustRootB64).length, 32);
  });

  test('X25519 公钥 / HKDF 方向密钥与 CryptoKit 一致', () async {
    final e = await MeowCrypto.ephemeralFromSeed(ePriv);
    expect(base64.encode((await e.extractPublicKey()).bytes), v['ePub']);
    final keys = v['keys'] as Map<String, dynamic>;
    for (final (info, name) in [(MeowCrypto.rpcC2S, 'rpc_c2s'), (MeowCrypto.rpcS2C, 'rpc_s2c'), (MeowCrypto.wsC2S, 'ws_c2s'), (MeowCrypto.wsS2C, 'ws_s2c')]) {
      final k = await MeowCrypto.deriveKey(ephemeral: e, masterPub: masterPub, info: info);
      expect(base64.encode(await k.extractBytes()), keys[name], reason: info);
    }
  });

  test('RPC 上行信封 / 下行解密', () async {
    final rpc = v['rpc'] as Map<String, dynamic>;
    final e = await MeowCrypto.ephemeralFromSeed(ePriv);
    final env = await MeowCrypto.sealRpcRequest(
      ephemeral: e,
      masterPub: masterPub,
      plain: utf8.encode(rpc['reqPlain'] as String),
      nonce: base64.decode(rpc['reqNonce'] as String),
    );
    expect(base64.encode(env), rpc['reqEnvelope']);
    final plain = await MeowCrypto.openRpcResponse(ephemeral: e, masterPub: masterPub, body: base64.decode(rpc['respBody'] as String));
    expect(utf8.decode(plain), rpc['respPlain']);
  });

  test('RPC 两把方向密钥一次派生（共享密钥只算一次）：密钥、信封、解包都与逐把派生一致', () async {
    final rpc = v['rpc'] as Map<String, dynamic>;
    final keysV = v['keys'] as Map<String, dynamic>;
    final e = await MeowCrypto.ephemeralFromSeed(ePriv);
    final keys = await MeowCrypto.rpcKeys(ephemeral: e, masterPub: masterPub);
    expect(base64.encode(await keys.c2s.extractBytes()), keysV['rpc_c2s']);
    expect(base64.encode(await keys.s2c.extractBytes()), keysV['rpc_s2c']);
    final env = await MeowCrypto.sealRpcRequest(
      ephemeral: e,
      masterPub: masterPub,
      plain: utf8.encode(rpc['reqPlain'] as String),
      nonce: base64.decode(rpc['reqNonce'] as String),
      key: keys.c2s,
    );
    expect(base64.encode(env), rpc['reqEnvelope']);
    final plain = await MeowCrypto.openRpcResponse(
      ephemeral: e,
      masterPub: masterPub,
      body: base64.decode(rpc['respBody'] as String),
      key: keys.s2c,
    );
    expect(utf8.decode(plain), rpc['respPlain']);
  });

  test('WS 帧：计数器 nonce、单调校验', () async {
    final ws = v['ws'] as Map<String, dynamic>;
    final e = await MeowCrypto.ephemeralFromSeed(ePriv);
    final s = await SecureSession.create(ephemeral: e, masterPub: masterPub);
    expect(base64.encode(await s.seal(utf8.encode(ws['authPlain'] as String))), ws['authFrame']);
    expect(base64.encode(await s.seal(utf8.encode(ws['pingPlain'] as String))), ws['pingFrame']);
    final event = base64.decode(ws['eventFrame'] as String);
    expect(utf8.decode(await s.open(event)), ws['eventPlain']);
    // 同一帧再收一次 = 计数器回退，必须拒绝
    expect(() => s.open(event), throwsFormatException);
  });

  test('主控证书验签：正常 / 坏签名 / 过期 / 域名不符 / 大小写不敏感', () async {
    final c = v['cert'] as Map<String, dynamic>;
    final root = base64.decode(c['rootPub'] as String);
    const now = 1758380000;
    final pub = await MeowCrypto.verifyCert(c['ok'] as Map<String, dynamic>, host: 'PANEL.example.com', rootPub: root, nowUnix: now);
    expect(base64.encode(pub), v['masterPub']);
    expect(() => MeowCrypto.verifyCert(c['bad_sig'] as Map<String, dynamic>, host: 'panel.example.com', rootPub: root, nowUnix: now), throwsA(isA<CertException>()));
    expect(() => MeowCrypto.verifyCert(c['expired'] as Map<String, dynamic>, host: 'panel.example.com', rootPub: root, nowUnix: now), throwsA(isA<CertException>()));
    expect(() => MeowCrypto.verifyCert(c['other_domain'] as Map<String, dynamic>, host: 'panel.example.com', rootPub: root, nowUnix: now), throwsA(isA<CertException>()));
  });

  test('后台 isolate 验签：结果一致，失败仍是 CertException（带原文案）', () async {
    final c = v['cert'] as Map<String, dynamic>;
    final root = base64.decode(c['rootPub'] as String);
    const now = 1758380000;
    // 主控的 JSON 里还会有别的字段，不影响验签
    final ok = {...c['ok'] as Map<String, dynamic>, 'extra': 'ignored'};
    final pub = await MeowCrypto.verifyCertOffThread(ok, host: 'panel.example.com', rootPub: root, nowUnix: now);
    expect(base64.encode(pub), v['masterPub']);
    await expectLater(
      MeowCrypto.verifyCertOffThread(c['bad_sig'] as Map<String, dynamic>, host: 'panel.example.com', rootPub: root, nowUnix: now),
      throwsA(isA<CertException>().having((e) => e.message, 'message', '主控证书签名无效')),
    );
    await expectLater(
      MeowCrypto.verifyCertOffThread(c['expired'] as Map<String, dynamic>, host: 'panel.example.com', rootPub: root, nowUnix: now),
      throwsA(isA<CertException>().having((e) => e.message, 'message', '主控证书已过期')),
    );
  });
}
