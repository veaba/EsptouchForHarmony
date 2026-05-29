import { IEspProvisioner } from './IEspProvisioner';
import { EspProvisionerImpl } from './EspProvisionerImpl';
import { EspProvisioningRequest } from './EspProvisioningRequest';
import { EspProvisioningListener } from './EspProvisioningListener';

export class EspProvisioner implements IEspProvisioner {
  private readonly delegate: EspProvisionerImpl;

  constructor() {
    this.delegate = new EspProvisionerImpl();
  }

  isProvisioning(): boolean {
    return this.delegate.isProvisioning();
  }

  startProvisioning(request: EspProvisioningRequest, listener: EspProvisioningListener | null): void {
    this.delegate.startProvisioning(request, listener);
  }

  stopProvisioning(): void {
    this.delegate.stopProvisioning();
  }

  close(): void {
    this.delegate.close();
  }
}
