import crypto from 'node:crypto';

/** Ed25519 licence signer. The app verifies with the matching public key compiled into it. */
export function createSigner(privateKeyB64) {
  const key = crypto.createPrivateKey({ key: Buffer.from(privateKeyB64, 'base64'), format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ type: 'spki', format: 'der' });
  const hmacKey = crypto.createHash('sha256').update('cb-licence-hmac:' + privateKeyB64).digest();
  return {
    publicKeyHex: Buffer.from(spki.subarray(spki.length - 32)).toString('hex'),
    sign: (data) => crypto.sign(null, Buffer.from(data), key).toString('base64url'),
    hmac: (data) => crypto.createHmac('sha256', hmacKey).update(data).digest(),
  };
}

export function generateKeyPair() {
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  const b64 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
  return { privateKeyB64: b64, publicKeyHex: createSigner(b64).publicKeyHex };
}
