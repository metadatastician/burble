// verify-e2ee-vectors.mjs — check the committed E2EE vectors with WebCrypto.
//
// Re-derives every value in client/web/tests/fixtures/e2ee-vectors.json using
// the same primitives the browser client must use (X25519, HKDF-SHA256,
// AES-256-GCM), and fails if the two implementations disagree.
//
//   node scripts/verify-e2ee-vectors.mjs
//   node scripts/verify-e2ee-vectors.mjs path/to/vectors.json
//
// Anything that matches here can be implemented in the browser without
// renegotiating the protocol; anything that does not is a protocol bug that
// would only have shown up when the client half shipped.

import fs from 'node:fs';
import crypto from 'node:crypto';

const vectorsPath =
  process.argv[2] ?? new URL('../client/web/tests/fixtures/e2ee-vectors.json', import.meta.url);
const v = JSON.parse(fs.readFileSync(vectorsPath, 'utf8'));
const hex = h => Buffer.from(h, 'hex');
const hexOut = b => Buffer.from(b).toString('hex');

const enc = s => new TextEncoder().encode(s);
const PAIRWISE_LABEL = 'burble-e2ee-pairwise-v1';
const GROUP_LABEL = 'burble-e2ee-group-v1';
const FRAME_LABEL = 'burble-e2ee-frame-v1';

let failures = 0;
const check = (name, got, want) => {
  const ok = got === want;
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n        got  ${got}\n        want ${want}`}`);
};

// ── 1. X25519 agreement + HKDF, exactly as pairwise_key/6 specifies ─────────

// WebCrypto does not accept a raw X25519 *private* key: it must be wrapped in
// PKCS#8 (`importKey('raw', ...)` is public-key-only for CFRG curves). This is
// the wrapper the browser client will need — 1.3.101.110 with the 32-byte key
// as an inner OCTET STRING.
const pkcs8 = raw => {
  const prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
  return Buffer.concat([prefix, raw]);
};

const privA = await crypto.subtle.importKey('pkcs8', pkcs8(hex(v.rfc7748_private_a)), { name: 'X25519' }, false, [
  'deriveBits'
]);

const shared = await crypto.subtle.deriveBits(
  { name: 'X25519', public: await crypto.subtle.importKey('raw', hex(v.public_b), { name: 'X25519' }, false, []) },
  privA,
  256
);

// salt = SHA-256("pairwise|" + room + "|" + epoch)
const salt = new Uint8Array(
  await crypto.subtle.digest('SHA-256', enc(`pairwise|${v.room}|${v.epoch}`))
);

// info = label + "|" + sorted peer ids
const info = enc(`${PAIRWISE_LABEL}|${[v.from, v.to].sort().join('|')}`);

const hkdfKey = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveBits']);

const pairwise = await crypto.subtle.deriveBits(
  { name: 'HKDF', hash: 'SHA-256', salt, info },
  hkdfKey,
  256
);

check('pairwise_key (X25519 + HKDF-SHA256)', hexOut(pairwise), v.pairwise_key);

// ── 2. Open the sealed room key produced by the Elixir side ─────────────────

const wire = Buffer.from(v.sealed_wire_b64, 'base64');
const iv = wire.subarray(0, 12);
const tag = wire.subarray(12, 28);
const ct = wire.subarray(28);
const aad = enc(`${GROUP_LABEL}|${v.room}|${v.epoch}|${v.from}|${v.to}`);

const aesKey = await crypto.subtle.importKey('raw', pairwise, 'AES-GCM', false, ['decrypt']);
const opened = await crypto.subtle.decrypt(
  { name: 'AES-GCM', iv, additionalData: aad, tagLength: 128 },
  aesKey,
  Buffer.concat([ct, tag])
);

check('open_group_key (AES-256-GCM, AAD-bound)', hexOut(opened), v.group_key);

// AAD must actually bind: swapping the recipient must fail.
let rejected = false;
try {
  await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv, additionalData: enc(`${GROUP_LABEL}|${v.room}|${v.epoch}|${v.to}|${v.from}`), tagLength: 128 },
    aesKey,
    Buffer.concat([ct, tag])
  );
} catch {
  rejected = true;
}
check('AAD rejects a swapped recipient', String(rejected), 'true');

// ── 3. Per-frame key derivation ────────────────────────────────────────────

const groupKey = await crypto.subtle.importKey('raw', hex(v.group_key), 'HKDF', false, ['deriveBits']);
const frameSalt = new Uint8Array(await crypto.subtle.digest('SHA-256', enc(`frame|${v.epoch}`)));

const frameKey = async counter => {
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: frameSalt, info: enc(`${FRAME_LABEL}|${counter}`) },
    groupKey,
    256
  );
  return hexOut(bits);
};

check('derive_frame_key (counter 0)', await frameKey(0), v.frame_key_0);
check('derive_frame_key (counter 1)', await frameKey(1), v.frame_key_1);
check('frame keys differ per counter', String((await frameKey(0)) !== (await frameKey(1))), 'true');

console.log(`\n${failures === 0 ? 'all vectors agree' : `${failures} mismatch(es)`}`);
process.exit(failures ? 1 : 0);
