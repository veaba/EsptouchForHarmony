import { DeviceStatus } from './DeviceStatus';
import { EspProvisioningResult } from './EspProvisioningResult';

export enum DeviceOnlineState {
  ONLINE = 'online',
  OFFLINE = 'offline',
  DISCONNECTED = 'disconnected',
  UNKNOWN = 'unknown'
}

export class DeviceInfo {
  bssid: string = '';
  ip: string = '';
  mac: string = '';
  ssid: string = '';
  reason: number = 0;
  chip: string = '';
  state: DeviceOnlineState = DeviceOnlineState.UNKNOWN;
  lastSeen: number = 0;

  static fromDeviceStatus(status: DeviceStatus, provisionResult: EspProvisioningResult | null): DeviceInfo {
    let info: DeviceInfo = new DeviceInfo();
    if (provisionResult != null) {
      info.bssid = provisionResult.bssid;
      info.ip = provisionResult.address;
    }
    if (status.ip.length > 0) {
      info.ip = status.ip;
    }
    if (status.mac.length > 0) {
      info.mac = status.mac;
    }
    info.ssid = status.ssid;
    info.reason = status.reason;
    info.chip = status.chip;
    if (status.disconnected) {
      info.state = DeviceOnlineState.DISCONNECTED;
    } else if (status.success) {
      info.state = DeviceOnlineState.ONLINE;
    } else {
      info.state = DeviceOnlineState.OFFLINE;
    }
    info.lastSeen = Date.now();
    return info;
  }

  static fromProvisionResult(result: EspProvisioningResult): DeviceInfo {
    let info: DeviceInfo = new DeviceInfo();
    info.bssid = result.bssid;
    info.ip = result.address;
    info.state = DeviceOnlineState.UNKNOWN;
    info.lastSeen = Date.now();
    return info;
  }

  updateFromStatus(status: DeviceStatus): void {
    if (status.ip.length > 0) {
      this.ip = status.ip;
    }
    if (status.mac.length > 0) {
      this.mac = status.mac;
    }
    this.ssid = status.ssid;
    this.reason = status.reason;
    this.chip = status.chip;
    if (status.disconnected) {
      this.state = DeviceOnlineState.DISCONNECTED;
    } else if (status.success) {
      this.state = DeviceOnlineState.ONLINE;
    } else {
      this.state = DeviceOnlineState.OFFLINE;
    }
    this.lastSeen = Date.now();
  }

  updateOffline(): void {
    this.state = DeviceOnlineState.OFFLINE;
  }

  get stateLabel(): string {
    switch (this.state) {
      case DeviceOnlineState.ONLINE:
        return 'Connected';
      case DeviceOnlineState.OFFLINE:
        return 'Failed';
      case DeviceOnlineState.DISCONNECTED:
        return 'Disconnected';
      default:
        return 'Provisioned';
    }
  }

  get stateColor(): string {
    switch (this.state) {
      case DeviceOnlineState.ONLINE:
        return '#2E7D32';
      case DeviceOnlineState.OFFLINE:
        return '#C62828';
      case DeviceOnlineState.DISCONNECTED:
        return '#E65100';
      default:
        return '#F57F17';
    }
  }

  get bgColor(): string {
    switch (this.state) {
      case DeviceOnlineState.ONLINE:
        return '#E8F5E9';
      case DeviceOnlineState.OFFLINE:
        return '#FFEBEE';
      case DeviceOnlineState.DISCONNECTED:
        return '#FFF3E0';
      default:
        return '#FFF8E1';
    }
  }
}