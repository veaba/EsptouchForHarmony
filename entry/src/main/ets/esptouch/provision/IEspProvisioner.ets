import { EspProvisioningRequest } from './EspProvisioningRequest';
import { EspProvisioningListener } from './EspProvisioningListener';

export const DEVICE_PORT: number = 7001;
export const DEVICE_ACK_PORT: number = 7002;
export const APP_PORTS: number[] = [18266, 28266, 38266, 48266];

export const DATA_PKG_INTERVAL: number = 15;
export const DATA_PKG_INTERVAL2: number = 100;
export const DATA_PKG_TIMEOUT_SEND: number = 90_000;
export const DATA_PKG_TIMEOUT_RECEIVE: number = DATA_PKG_TIMEOUT_SEND + 2_000;

export const SSID_MAX: number = 32;
export const PWD_MAX: number = 64;
export const BSSID_LEN: number = 6;
export const AES_KEY_LEN: number = 16;
export const RESERVED_MAX: number = 64;
export const CRC_POLYNOM: number = 0x8c;
export const MIN_RESPONSE_LEN: number = 7;
export const SEQUENCE_FIRST: number = -1;

export interface IEspProvisioner {
  startProvisioning(request: EspProvisioningRequest, listener: EspProvisioningListener | null): void;

  stopProvisioning(): void;

  isProvisioning(): boolean;

  close(): void;
}
