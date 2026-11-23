// RayPrompt editor link protocol (VS Code side). Pure Node, no VS Code APIs, so it is unit-testable.
//
// Security (mirrors App/EditorSecurity.swift):
//  - Pairing: X25519 key agreement; keys derived with HKDF-SHA256 from the shared secret, the server nonce and
//    SHA-256 of the one-time pairing code (10 base32 chars, ~50 bits, 2 minutes, single use). Both sides prove
//    knowledge of the code with HMACs over the transcript; a long-term trust key is derived for reconnection.
//  - Reconnection: fresh ephemeral X25519 keys every session, authenticated with the trust key (forward secrecy).
//  - Messages: ChaCha20-Poly1305 with a per-direction counter nonce; strict sequence numbers (no replay or
//    reordering) and timestamps (stale messages are rejected).
'use strict';
const crypto = require('crypto');

const VERSION = 1;
const MAX_LINE = 32 * 1024;
const MAX_SKEW_MS = 120_000;
const X25519_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const X25519_SPKI = Buffer.from('302a300506032b656e032100', 'hex');

const b64 = (buffer) => Buffer.from(buffer).toString('base64');
const unb64 = (text) => Buffer.from(text, 'base64');
const sha256 = (data) => crypto.createHash('sha256').update(data).digest();
const hmac = (key, ...parts) => { const h = crypto.createHmac('sha256', key); parts.forEach((p) => h.update(p)); return h.digest(); };
const hkdf = (ikm, salt, info, length) => Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, length));

function normalizeCode(code) { return String(code).toUpperCase().replace(/[^A-Z2-7]/g, ''); }

function keyPair(privateRaw) {
  const privateKey = privateRaw
    ? crypto.createPrivateKey({ key: Buffer.concat([X25519_PKCS8, privateRaw]), format: 'der', type: 'pkcs8' })
    : crypto.generateKeyPairSync('x25519').privateKey;
  const publicRaw = crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(X25519_SPKI.length);
  return { privateKey, publicRaw };
}

function sharedSecret(privateKey, peerPublicRaw) {
  const publicKey = crypto.createPublicKey({ key: Buffer.concat([X25519_SPKI, peerPublicRaw]), format: 'der', type: 'spki' });
  return crypto.diffieHellman({ privateKey, publicKey });
}

function transcript(serverKey, clientKey, nonce, deviceID) {
  return Buffer.concat([Buffer.from(`rayprompt v${VERSION}|`), serverKey, clientKey, nonce, Buffer.from(deviceID)]);
}

/// Keys for one session: c2s, s2c (32 bytes each) and the authentication key for the handshake proofs.
function deriveKeys(shared, nonce, secret, mode) {
  const okm = hkdf(shared, nonce, Buffer.concat([Buffer.from(`rayprompt ${mode} v${VERSION}`), secret]), 96);
  return { c2s: okm.subarray(0, 32), s2c: okm.subarray(32, 64), auth: okm.subarray(64, 96) };
}

function trustKeyFor(shared, nonce, codeHash) {
  return hkdf(shared, nonce, Buffer.concat([Buffer.from(`rayprompt trust v${VERSION}`), codeHash]), 32);
}

/// Client side of the handshake. `trust` = { deviceID, key (Buffer) } for reconnection, or null with `code` to pair.
function clientHandshake(hello, { deviceID, name, code, trust, privateRaw }) {
  if (hello.type !== 'hello' || hello.v !== VERSION) throw new Error('unsupported server hello');
  const serverKey = unb64(hello.serverKey), nonce = unb64(hello.nonce);
  const { privateKey, publicRaw } = keyPair(privateRaw);
  const shared = sharedSecret(privateKey, serverKey);
  const t = transcript(serverKey, publicRaw, nonce, deviceID);
  if (trust) {
    const keys = deriveKeys(shared, nonce, trust.key, 'session');
    return {
      message: { type: 'resume', v: VERSION, clientKey: b64(publicRaw), deviceID, mac: b64(hmac(keys.auth, 'client', t)) },
      keys, expect: b64(hmac(keys.auth, 'server', t)), trustKey: trust.key,
    };
  }
  const codeHash = sha256(normalizeCode(code));
  const keys = deriveKeys(shared, nonce, codeHash, 'pair');
  return {
    message: { type: 'pair', v: VERSION, clientKey: b64(publicRaw), deviceID, name, mac: b64(hmac(keys.auth, 'client', t)) },
    keys, expect: b64(hmac(keys.auth, 'server', t)), trustKey: trustKeyFor(shared, nonce, codeHash),
  };
}

/// Encrypted channel for one direction pair. Sequence numbers start at 1 and must increase by exactly 1.
class SecureChannel {
  constructor(keys, side, now = () => Date.now()) {
    this.sendKey = side === 'client' ? keys.c2s : keys.s2c;
    this.receiveKey = side === 'client' ? keys.s2c : keys.c2s;
    this.sendDirection = side === 'client' ? 'c2s' : 's2c';
    this.receiveDirection = side === 'client' ? 's2c' : 'c2s';
    this.sent = 0; this.received = 0; this.now = now;
  }

  static nonce(seq) { const n = Buffer.alloc(12); n.writeBigUInt64BE(BigInt(seq), 4); return n; }

  seal(body) {
    this.sent += 1;
    const plain = Buffer.from(JSON.stringify({ ...body, ts: this.now() }));
    const cipher = crypto.createCipheriv('chacha20-poly1305', this.sendKey, SecureChannel.nonce(this.sent), { authTagLength: 16 });
    cipher.setAAD(Buffer.from(`rayprompt ${this.sendDirection} ${this.sent}`));
    const box = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
    return { seq: this.sent, box: b64(box) };
  }

  open(envelope) {
    if (!Number.isInteger(envelope.seq) || envelope.seq !== this.received + 1) throw new Error('replayed or out-of-order message');
    const box = unb64(envelope.box);
    if (box.length < 16 || box.length > MAX_LINE) throw new Error('bad message size');
    const decipher = crypto.createDecipheriv('chacha20-poly1305', this.receiveKey, SecureChannel.nonce(envelope.seq), { authTagLength: 16 });
    decipher.setAAD(Buffer.from(`rayprompt ${this.receiveDirection} ${envelope.seq}`));
    decipher.setAuthTag(box.subarray(box.length - 16));
    const plain = Buffer.concat([decipher.update(box.subarray(0, box.length - 16)), decipher.final()]);
    const body = JSON.parse(plain.toString('utf8'));
    if (typeof body.ts !== 'number' || Math.abs(this.now() - body.ts) > MAX_SKEW_MS) throw new Error('stale message');
    this.received = envelope.seq;
    return body;
  }
}

/// Reconnection delays: 1, 2, 4, … capped at 30 s, with ±20 % jitter.
function backoff(attempt, random = Math.random) {
  const base = Math.min(30_000, 1000 * 2 ** Math.max(0, attempt));
  return Math.round(base * (0.8 + 0.4 * random()));
}

// Files and values that never leave the Mac.
const SENSITIVE_FILE = /(^|\/)(\.env[^/]*|.*\.(pem|key|p12|pfx|keystore|jks)|id_rsa[^/]*|id_ed25519[^/]*|.*(secret|credential|password|token)[^/]*)$/i;
const SECRET_PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, /AIza[0-9A-Za-z_-]{30,}/g, /\bsk-[A-Za-z0-9_-]{16,}/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}/g, /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
  /\b(postgres(ql)?|mongodb(\+srv)?|mysql|redis):\/\/[^\s'"]+/gi,
  /\b([A-Z0-9_]*(api[_-]?key|secret|password|passwd|token|private[_-]?key|access[_-]?key)[A-Z0-9_]*)\s*[:=]\s*['"]?[^\s'",]{6,}/gi,
];
function isSensitiveFile(fileName) { return SENSITIVE_FILE.test(fileName); }
function redact(text) { return SECRET_PATTERNS.reduce((out, pattern) => out.replace(pattern, '[redacted]'), String(text)); }

/// An authorized excerpt: never from a sensitive file, secrets redacted, at most 4 KB.
function excerpt(fileName, text) {
  if (isSensitiveFile(fileName)) return null;
  return redact(text).slice(0, 4096);
}

/// Which expected lines are present (whitespace-insensitive) and which expected names exist as symbols.
function structurePresence(documentText, structures, symbolNames = null) {
  const squash = (t) => t.replace(/\s+/g, '');
  const text = squash(documentText);
  return structures.map((line) => {
    if (!text.includes(squash(line))) return false;
    if (!symbolNames) return true;
    const declared = /\b(?:function|const|let|var|def|class)\s+([A-Za-z_]\w*)/.exec(line);
    return !declared || symbolNames.has(declared[1]);
  });
}

module.exports = {
  VERSION, MAX_LINE, b64, unb64, sha256, hmac, hkdf, keyPair, sharedSecret, transcript, deriveKeys, trustKeyFor,
  clientHandshake, SecureChannel, backoff, normalizeCode, isSensitiveFile, redact, excerpt, structurePresence,
};
