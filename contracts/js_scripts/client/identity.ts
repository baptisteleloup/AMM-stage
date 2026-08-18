import { ethers } from "ethers";
import { config } from "./config.js";

export class Identity {
  readonly wallet: ethers.Wallet;

  constructor(provider?: ethers.Provider) {
    this.wallet = new ethers.Wallet(config.prosumerKey, provider);
  }

  get address(): string {
    return this.wallet.address;
  }

  get encryptionPubKey(): string {
    return config.compressedKey
      ? this.wallet.signingKey.compressedPublicKey
      : this.wallet.signingKey.publicKey;
  }

  get decryptionKeyHex(): string {
    return this.wallet.privateKey.slice(2);
  }

  ownsKey(onchainKey: string): boolean {
    if (!onchainKey || onchainKey === "0x") return false;
    try {
      const a = ethers.SigningKey.computePublicKey(onchainKey, true);
      const b = this.wallet.signingKey.compressedPublicKey;
      return a.toLowerCase() === b.toLowerCase();
    } catch {
      return false;
    }
  }
}
