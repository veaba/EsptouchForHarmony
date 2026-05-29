interface DeviceStatusJson {
  status?: number;
  ip?: string;
  mac?: string;
  ssid?: string;
  reason?: number;
  chip?: string;
}

export const WIFI_NOTIFY_STATUS_SUCCESS: number = 0;
export const WIFI_NOTIFY_STATUS_FAIL: number = 1;
export const WIFI_NOTIFY_STATUS_DISCONNECT: number = 2;

export class DeviceStatus {
  readonly success: boolean;
  readonly disconnected: boolean;
  readonly ip: string;
  readonly mac: string;
  readonly ssid: string;
  readonly reason: number;
  readonly chip: string;
  readonly address: string;

  private constructor(
    success: boolean,
    disconnected: boolean,
    ip: string,
    mac: string,
    ssid: string,
    reason: number,
    chip: string,
    address: string
  ) {
    this.success = success;
    this.disconnected = disconnected;
    this.ip = ip;
    this.mac = mac;
    this.ssid = ssid;
    this.reason = reason;
    this.chip = chip;
    this.address = address;
  }

  static parse(json: string, senderIp: string): DeviceStatus | null {
    try {
      let obj: DeviceStatusJson = JSON.parse(json) as DeviceStatusJson;
      let status: number = obj.status ?? -1;
      let success: boolean = status === WIFI_NOTIFY_STATUS_SUCCESS;
      let disconnected: boolean = status === WIFI_NOTIFY_STATUS_DISCONNECT;
      let ip: string = obj.ip ?? '';
      let mac: string = obj.mac ?? '';
      let ssid: string = obj.ssid ?? '';
      let reason: number = obj.reason ?? 0;
      let chip: string = obj.chip ?? '';
      return new DeviceStatus(success, disconnected, ip, mac, ssid, reason, chip, senderIp);
    } catch (_e) {
      return null;
    }
  }
}
