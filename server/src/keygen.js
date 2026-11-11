import { generateKeyPair } from './sign.js';

const { privateKeyB64, publicKeyHex } = generateKeyPair();
console.log('LICENCE_SIGNING_KEY (server secret):\n' + privateKeyB64);
console.log('\nlicencePublicKeyHex (app, public, lib/core/licence.dart):\n' + publicKeyHex);
