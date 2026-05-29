import { EspProvisioningResult } from './EspProvisioningResult';
import { DeviceStatus } from './DeviceStatus';

export interface EspProvisioningListener {
  onStart(): void;

  onResponse(result: EspProvisioningResult): void;

  onStop(): void;

  onError(error: Error): void;

  onDeviceStatus?(status: DeviceStatus): void;
}
