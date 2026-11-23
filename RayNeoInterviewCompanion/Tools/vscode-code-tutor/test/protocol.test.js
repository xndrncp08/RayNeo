'use strict';
const test = require('node:test');
const assert = require('node:assert');
const p = require('../protocol');

// The same vectors are checked by the Swift tests (EditorSecurityTests), so both sides speak one protocol.
const VECTORS = {
  serverPublic: 'pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk=', clientPublic: 'zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk=',
  shared: 'LtdqtUmx5zwDHrSclEjweYrqgbaYJ5oMPcPkn7/EuVM=', pairMac: '/7kWSiJlvf874gl0pgCxonECiPTu5zXOovtrWgQOMCo=',
  pairServerMac: 'Ge6qTrQD2GXAFHb1FmhAYZC9zxjBNmP7qd+7BNAKino=', trustKey: 'rPgYCKKHoooiJh4D31kqY5EAwbFYaO3IX52knk/QlVI=',
  resumeMac: 'XBpm4KleML9OxbdLsqPyDCnoit+3IXgxAMwzM7FSd3s=', resumeServerMac: '1wWiB8biHiNxUFPE7r5fLzxVIB77pwE4bflIM+8lsCA=',
  sealedBox: '/NbikK7QKYoRPpWMO4MGDPeWZHDb8dMpPzyAS8lc61mTi59gdPNmXUN7s7vejY2hCSg=',
};

/// Minimal server (mirrors EditorServerSession in Swift) for exercising the client.
function server({ code = null, trusted = new Map(), privateRaw, nonce } = {}) {
  const { privateKey, publicRaw } = p.keyPair(privateRaw);
  nonce = nonce || require('crypto').randomBytes(16);
  return {
    hello: { type: 'hello', v: 1, serverKey: p.b64(publicRaw), nonce: p.b64(nonce), mode: code ? 'pair' : 'resume', service: 'RayPrompt-ABC123' },
    handle(message) {
      const clientKey = p.unb64(message.clientKey);
      const shared = p.sharedSecret(privateKey, clientKey);
      const t = p.transcript(publicRaw, clientKey, nonce, message.deviceID);
      let keys, trustKey;
      if (message.type === 'pair') {
        if (!code) return { reply: { type: 'rejected', reason: 'pairing is not open' } };
        const codeHash = p.sha256(p.normalizeCode(code));
        keys = p.deriveKeys(shared, nonce, codeHash, 'pair');
        trustKey = p.trustKeyFor(shared, nonce, codeHash);
      } else {
        const known = trusted.get(message.deviceID);
        if (!known) return { reply: { type: 'rejected', reason: 'not paired' } };
        keys = p.deriveKeys(shared, nonce, known, 'session');
      }
      if (p.b64(p.hmac(keys.auth, 'client', t)) !== message.mac) return { reply: { type: 'rejected', reason: 'authentication failed' } };
      return { reply: { type: message.type === 'pair' ? 'paired' : 'resumed', mac: p.b64(p.hmac(keys.auth, 'server', t)) }, keys, trustKey };
    },
  };
}

test('cross-language vectors', () => {
  const serverPriv = Buffer.alloc(32, 1), clientPriv = Buffer.alloc(32, 2), nonce = Buffer.alloc(16, 3);
  const s = p.keyPair(serverPriv), c = p.keyPair(clientPriv);
  assert.equal(p.b64(s.publicRaw), VECTORS.serverPublic);
  assert.equal(p.b64(c.publicRaw), VECTORS.clientPublic);
  assert.equal(p.b64(p.sharedSecret(s.privateKey, c.publicRaw)), VECTORS.shared);
  const hello = { type: 'hello', v: 1, serverKey: VECTORS.serverPublic, nonce: p.b64(nonce) };
  const pair = p.clientHandshake(hello, { deviceID: 'test-device', name: 'VS Code', code: 'abcde-fgh23', privateRaw: clientPriv });
  assert.equal(pair.message.mac, VECTORS.pairMac);
  assert.equal(pair.expect, VECTORS.pairServerMac);
  assert.equal(p.b64(pair.trustKey), VECTORS.trustKey);
  const resume = p.clientHandshake(hello, { deviceID: 'test-device', trust: { key: pair.trustKey }, privateRaw: clientPriv });
  assert.equal(resume.message.mac, VECTORS.resumeMac);
  assert.equal(resume.expect, VECTORS.resumeServerMac);
  assert.equal(new p.SecureChannel(resume.keys, 'client', () => 1700000000000).seal({ type: 'ping' }).box, VECTORS.sealedBox);
});

test('pairing then trusted reconnection; a wrong code is rejected', () => {
  const pairing = server({ code: 'KQ7MA-2XPB9' });
  const client = p.clientHandshake(pairing.hello, { deviceID: 'mac-1', name: 'VS Code', code: 'kq7ma-2xpb9' });
  const result = pairing.handle(client.message);
  assert.equal(result.reply.type, 'paired');
  assert.equal(result.reply.mac, client.expect); // the iPhone proved the code too
  assert.deepEqual(result.trustKey, client.trustKey);

  const resume = server({ trusted: new Map([['mac-1', result.trustKey]]) });
  const again = p.clientHandshake(resume.hello, { deviceID: 'mac-1', trust: { key: client.trustKey } });
  const resumed = resume.handle(again.message);
  assert.equal(resumed.reply.type, 'resumed');
  assert.notDeepEqual(resumed.keys.c2s, result.keys.c2s); // fresh keys every session

  const wrong = server({ code: 'KQ7MA-2XPB9' });
  assert.equal(wrong.handle(p.clientHandshake(wrong.hello, { deviceID: 'x', name: 'x', code: 'AAAAA-AAAAA' }).message).reply.type, 'rejected');
  const forgotten = server({ trusted: new Map() });
  assert.equal(forgotten.handle(p.clientHandshake(forgotten.hello, { deviceID: 'mac-1', trust: { key: client.trustKey } }).message).reply.reason, 'not paired');
});

test('encrypted channel rejects replay, reordering, staleness and tampering', () => {
  const s = server({ code: 'KQ7MA-2XPB9' });
  const c = p.clientHandshake(s.hello, { deviceID: 'mac', name: 'n', code: 'KQ7MA-2XPB9' });
  const keys = s.handle(c.message).keys;
  let clock = 1_700_000_000_000;
  const client = new p.SecureChannel(c.keys, 'client', () => clock);
  const srv = new p.SecureChannel(keys, 'server', () => clock);
  const first = client.seal({ type: 'state', file: 'a.js' }), second = client.seal({ type: 'ping' });
  assert.equal(srv.open(first).file, 'a.js');
  assert.throws(() => srv.open(first), /replayed/);
  const third = client.seal({ type: 'ping' });
  assert.throws(() => srv.open(third), /out-of-order/);
  assert.equal(srv.open(second).type, 'ping');
  const tampered = { ...third, box: p.b64(Buffer.from(p.unb64(third.box)).map((b, i) => (i === 0 ? b ^ 1 : b))) };
  assert.throws(() => srv.open(tampered));
  clock += 300_000;
  const late = new p.SecureChannel(c.keys, 'client', () => clock - 300_000);
  late.sent = srv.received; // next sequence number, but an old timestamp
  assert.throws(() => srv.open(late.seal({ type: 'ping' })), /stale/);
});

test('backoff grows exponentially with jitter and is capped', () => {
  assert.equal(p.backoff(0, () => 0.5), 1000);
  assert.equal(p.backoff(3, () => 0.5), 8000);
  assert.equal(p.backoff(10, () => 0.5), 30000);
  assert.ok(p.backoff(2, () => 0) >= 3200 && p.backoff(2, () => 1) <= 4800);
});

test('sensitive files and secrets never leave the Mac', () => {
  for (const name of ['/repo/.env', '/repo/.env.local', '/k/server.pem', '/home/id_rsa', '/a/credentials.json', '/a/secret-config.ts']) {
    assert.ok(p.isSensitiveFile(name), name);
    assert.equal(p.excerpt(name, 'x'), null);
  }
  assert.ok(!p.isSensitiveFile('/repo/src/students.ts'));
  const redacted = p.redact('const key = "AIzaSyA1234567890abcdefghijklmnopqrstuv"; DATABASE_URL=postgresql://u:p@h/db; password = hunter2hunter2');
  for (const secret of ['AIzaSyA1234', 'u:p@h', 'hunter2']) assert.ok(!redacted.includes(secret), secret);
  assert.equal(p.excerpt('/a/b.js', 'x'.repeat(10000)).length, 4096);
});

test('structure checks use text and language-service symbols', () => {
  const doc = 'function getActiveStudents(students) {\n  return students.filter(s => s.status === "active");\n}';
  const structures = ['function getActiveStudents(students) {', 'return students.filter(s => s.status === "active");'];
  assert.deepEqual(p.structurePresence(doc, structures), [true, true]);
  assert.deepEqual(p.structurePresence(doc, structures, new Set(['getActiveStudents'])), [true, true]);
  assert.deepEqual(p.structurePresence(doc, structures, new Set(['somethingElse'])), [false, true]); // text alone is not enough
  assert.deepEqual(p.structurePresence('function getActiveStudents(students) {}', structures), [true, false]);
});
