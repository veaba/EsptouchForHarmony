import { util } from '@kit.ArkTS';
import { wifiManager } from '@kit.ConnectivityKit';
import { getAddress, convertBssid2Bytes } from './TouchNetUtil';
import { SSID_MAX, PWD_MAX, BSSID_LEN, AES_KEY_LEN, RESERVED_MAX } from './IEspProvisioner';

export class EspProvisioningRequest {
  readonly address: string | null;
  readonly ssid: Uint8Array;
  readonly bssid: Uint8Array;
  readonly password: Uint8Array;
  readonly reservedData: Uint8Array;
  readonly aesKey: Uint8Array;
  readonly securityVer: number;

  constructor(
    address: string | null,
    ssid: Uint8Array,
    bssid: Uint8Array,
    password: Uint8Array,
    reservedData: Uint8Array,
    aesKey: Uint8Array,
    securityVer: number
  ) {
    this.address = address;
    this.ssid = ssid;
    this.bssid = bssid;
    this.password = password;
    this.reservedData = reservedData;
    this.aesKey = aesKey;
    this.securityVer = securityVer;
  }

  static readonly SECURITY_V1: number = 1;
  static readonly SECURITY_V2: number = 2;
}

export class EspProvisioningRequestBuilder {
  address: string | null = null;
  ssid: Uint8Array | null = null;
  bssid: Uint8Array | null = null;
  password: Uint8Array | null = null;
  reservedData: Uint8Array | null = null;
  aesKey: Uint8Array | null = null;
  secretVer: number = EspProvisioningRequest.SECURITY_V1;

  constructor() {
  }

  setSSID(ssid: Uint8Array | null): EspProvisioningRequestBuilder {
    if (ssid != null && ssid.length > SSID_MAX) {
      throw new Error('SSID length is greater than 32');
    }
    this.ssid = ssid;
    return this;
  }

  setBSSID(bssid: Uint8Array): EspProvisioningRequestBuilder {
    if (bssid.length !== BSSID_LEN) {
      throw new Error('Invalid BSSID data');
    }
    this.bssid = bssid;
    return this;
  }

  setPassword(password: Uint8Array | null): EspProvisioningRequestBuilder {
    if (password != null && password.length > PWD_MAX) {
      throw new Error('Password length is greater than 64');
    }
    this.password = password;
    return this;
  }

  setReservedData(data: Uint8Array | null): EspProvisioningRequestBuilder {
    if (data != null && data.length > RESERVED_MAX) {
      throw new Error('ReservedData length is greater than 64');
    }
    this.reservedData = data;
    return this;
  }

  setAESKey(aesKey: Uint8Array | null): EspProvisioningRequestBuilder {
    if (aesKey != null && aesKey.length !== AES_KEY_LEN) {
      throw new Error('AES Key must be null or 16 bytes');
    }
    this.aesKey = aesKey;
    return this;
  }

  setSecurityVer(securityVer: number): EspProvisioningRequestBuilder {
    if (securityVer !== EspProvisioningRequest.SECURITY_V1 &&
      securityVer !== EspProvisioningRequest.SECURITY_V2) {
      throw new Error('Security ver is illegal');
    }
    this.secretVer = securityVer;
    return this;
  }

  async build(): Promise<EspProvisioningRequest> {
    try {
      let linkedInfo = await wifiManager.getLinkedInfo();
      if (linkedInfo != null) {
        if (this.ssid == null || this.ssid.length === 0) {
          let encoder = new util.TextEncoder();
          this.ssid = encoder.encodeInto(linkedInfo.ssid);
        }

        if (this.bssid == null && linkedInfo.bssid != null) {
          this.bssid = convertBssid2Bytes(linkedInfo.bssid.toLowerCase());
        }

        if (this.address == null) {
          let ipInfo = wifiManager.getIpInfo();
          if (ipInfo != null && ipInfo.ipAddress !== 0) {
            this.address = getAddress(ipInfo.ipAddress);
          }
        }
      }
    } catch (_e) { /* ignore */ }

    if (this.address == null) {
      this.address = '255.255.255.255';
    }

    return new EspProvisioningRequest(
      this.address,
      this.ssid ?? new Uint8Array(0),
      this.bssid ?? new Uint8Array(0),
      this.password ?? new Uint8Array(0),
      this.reservedData ?? new Uint8Array(0),
      this.aesKey ?? new Uint8Array(0),
      this.secretVer
    );
  }
}
