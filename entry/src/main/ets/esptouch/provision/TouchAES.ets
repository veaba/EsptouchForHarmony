import cryptoFramework from '@ohos.security.cryptoFramework';

const TRANSFORMATION: string = 'AES128|CBC|PKCS7';

export class TouchAES {
  private readonly key: Uint8Array;
  private readonly iv: Uint8Array;

  constructor(key: Uint8Array, iv: Uint8Array | null = null) {
    this.key = key;

    this.iv = new Uint8Array(16);
    if (iv != null) {
      let copyLen: number = Math.min(iv.length, this.iv.length);
      for (let i = 0; i < copyLen; i++) {
        this.iv[i] = iv[i];
      }
    }
  }

  async encrypt(content: Uint8Array): Promise<Uint8Array | null> {
    try {
      let cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(TRANSFORMATION);
      let symKey: cryptoFramework.SymKey = await this.generateKey();
      let ivParam: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: {
          data: this.iv
        }
      };

      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParam);
      let blob: cryptoFramework.DataBlob = {
        data: content
      };
      let result: cryptoFramework.DataBlob = await cipher.doFinal(blob);
      return new Uint8Array(result.data);
    } catch (_e) {
      return null;
    }
  }

  async decrypt(content: Uint8Array): Promise<Uint8Array | null> {
    try {
      let cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(TRANSFORMATION);
      let symKey: cryptoFramework.SymKey = await this.generateKey();
      let ivParam: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: {
          data: this.iv
        }
      };

      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivParam);
      let blob: cryptoFramework.DataBlob = {
        data: content
      };
      let result: cryptoFramework.DataBlob = await cipher.doFinal(blob);
      return new Uint8Array(result.data);
    } catch (_e) {
      return null;
    }
  }

  private async generateKey(): Promise<cryptoFramework.SymKey> {
    let keyGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    let keyBlob: cryptoFramework.DataBlob = {
      data: this.key
    };
    return await keyGen.convertKey(keyBlob);
  }
}
