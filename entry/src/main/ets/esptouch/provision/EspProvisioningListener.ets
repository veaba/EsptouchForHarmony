import { EspProvisioningResult } from './EspProvisioningResult';

export interface EspProvisioningListener {
  onStart(): void;

  onResponse(result: EspProvisioningResult): void;

  onStop(): void;

  onError(error: Error): void;
}
