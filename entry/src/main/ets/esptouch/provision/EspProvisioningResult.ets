export class EspProvisioningResult {
  readonly address: string;
  readonly bssid: string;

  constructor(address: string, bssid: string) {
    this.address = address;
    this.bssid = bssid;
  }
}
