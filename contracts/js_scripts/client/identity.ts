// The member's identity: one secp256k1 key signs transactions and decrypts recourse data.

import { ethers } from "ethers";
import { config } from "./config.js";

export class Identity {
  readonly wallet: ethers.Wallet;

  constructor(provider?: ethers.Provider) {
    this.wallet = new ethers.Wallet(config.prosumerKey, provider); // PROSUMER_KEY, connected to the chain if a provider is given
  }

  get address(): string {
    return this.wallet.address;
  }

  get encryptionPubKey(): string { // key registered with MarketV4.register
    return config.compressedKey // COMPRESSED_KEY=1: 33-byte form
      ? this.wallet.signingKey.compressedPublicKey
      : this.wallet.signingKey.publicKey;
  }

  get decryptionKeyHex(): string { // hex private key for ECIES decryption
    return this.wallet.privateKey.slice(2);
  }

  // True if the key registered on chain is this wallet's key (compressed or not).
  ownsKey(onchainKey: string): boolean {
    if (!onchainKey || onchainKey === "0x") return false;
    try {
      const a = ethers.SigningKey.computePublicKey(onchainKey, true); // normalise to compressed form before comparing
      const b = this.wallet.signingKey.compressedPublicKey;
      return a.toLowerCase() === b.toLowerCase();
    } catch {
      return false;
    }
  }
}
