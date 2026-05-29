import { socket } from '@kit.NetworkKit';
import { IEspProvisioner } from './IEspProvisioner';
import {
  DEVICE_PORT, DEVICE_ACK_PORT, APP_PORTS,
  DATA_PKG_INTERVAL, DATA_PKG_INTERVAL2,
  DATA_PKG_TIMEOUT_SEND, DATA_PKG_TIMEOUT_RECEIVE, MIN_RESPONSE_LEN
} from './IEspProvisioner';
import { EspProvisioningRequest } from './EspProvisioningRequest';
import { EspProvisioningListener } from './EspProvisioningListener';
import { EspProvisioningResult } from './EspProvisioningResult';
import { EspProvisioningParams } from './EspProvisioningParams';
import { getBroadcastAddress } from './TouchNetUtil';

const TAG: string = 'EspProvisionerImpl';

function delay(ms: number): Promise<void> {
  return new Promise<void>(resolve => setTimeout(resolve, ms));
}

function bssidBytesToString(bytes: Uint8Array): string {
  let parts: string[] = [];
  for (let i = 0; i < bytes.length && i < 6; i++) {
    parts.push(bytes[i].toString(16).padStart(2, '0'));
  }
  return parts.join(':');
}

function uint8ArrayToArrayBuffer(data: Uint8Array): ArrayBuffer {
  if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
    return data.buffer as ArrayBuffer;
  }
  return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
}

export class EspProvisionerImpl implements IEspProvisioner {
  private readonly broadcastAddress: string;
  private provisionSocket: socket.UDPSocket | null = null;
  private provisioning: boolean = false;
  private closed: boolean = false;
  private responseMacs: Set<string> = new Set();
  private provisionListener: EspProvisioningListener | null = null;

  constructor() {
    this.broadcastAddress = getBroadcastAddress();
  }

  isProvisioning(): boolean {
    return this.provisioning;
  }

  close(): void {
    this.closed = true;
    this.stopProvisioning();
  }

  startProvisioning(request: EspProvisioningRequest, listener: EspProvisioningListener | null): void {
    if (this.closed) {
      if (listener != null) {
        listener.onError(new Error('The provisioner has closed'));
      }
      return;
    }

    if (this.provisioning) {
      if (listener != null) {
        listener.onError(new Error('startProvision Error, Provision task is running'));
      }
      return;
    }

    this.doStartProvisioning(request, listener).catch((e: Error) => {
      console.warn(TAG, `doStartProvisioning failed: ${e.message}`);
      if (listener != null) {
        listener.onError(e);
      }
    });
  }

  private async doStartProvisioning(
    request: EspProvisioningRequest,
    listener: EspProvisioningListener | null
  ): Promise<void> {
    let udpSocket: socket.UDPSocket = socket.constructUDPSocketInstance();

    let portMark: number = -1;
    for (let i = 0; i < APP_PORTS.length; ++i) {
      try {
        await udpSocket.bind({ address: '0.0.0.0', port: APP_PORTS[i], family: 1 });
        await udpSocket.setExtraOptions({ broadcast: true });
        portMark = i;
        console.info(TAG, `bind: SUCCESS on port ${APP_PORTS[i]}`);
        break;
      } catch (e) {
        console.warn(TAG, `bind: port ${APP_PORTS[i]} failed: ${e}`);
      }
    }

    if (portMark < 0) {
      console.error(TAG, 'bind: ALL ports failed');
      try {
        udpSocket.close();
      } catch (_e) { /* ignore */ }
      if (listener != null) {
        listener.onError(new Error('Create provision socket failed'));
      }
      return;
    }

    this.provisionSocket = udpSocket;
    this.provisioning = true;
    this.responseMacs.clear();
    this.provisionListener = listener;

    console.info(TAG, `provisioning started on port ${APP_PORTS[portMark]}, broadcast to ${this.broadcastAddress}:${DEVICE_PORT}`);

    if (listener != null) {
      listener.onStart();
    }

    this.setupReceiveHandler(udpSocket, listener);

    await this.runProvisionSendLoop(request, listener, portMark);

    // Keep socket open to receive device ACK after send loop ends
    // (mirrors Android: ProvisionReceiveRunnable keeps running after ProvisionPostRunnable ends)
    let receiveStart: number = Date.now();
    while (this.provisioning) {
      if (Date.now() - receiveStart > DATA_PKG_TIMEOUT_RECEIVE) {
        break;
      }
      await delay(500);
    }

    if (this.provisioning) {
      this.stopProvisioning();
    }
  }

  private setupReceiveHandler(sock: socket.UDPSocket, listener: EspProvisioningListener | null): void {
    sock.on('message', (data: socket.SocketMessageInfo) => {
      if (!this.provisioning) {
        console.warn(TAG, 'setupReceiveHandler: message received but not provisioning, drop');
        return;
      }

      let message: ArrayBuffer = data.message;
      let remoteInfo = data.remoteInfo;
      console.info(TAG, `recv: ${message.byteLength} bytes from ${remoteInfo.address}:${remoteInfo.port}`);

      if (message.byteLength < MIN_RESPONSE_LEN) {
        console.warn(TAG, `recv: too short (${message.byteLength} < ${MIN_RESPONSE_LEN}), drop`);
        return;
      }

      let response: Uint8Array = new Uint8Array(message);
      let deviceAddress: string = remoteInfo.address;
      let bssidStr: string = bssidBytesToString(response.slice(1, 7));
      console.info(TAG, `recv: from=${deviceAddress}, bssid=${bssidStr}, firstByte=${response[0]}`);

      this.sendAck(deviceAddress);

      if (listener != null) {
        if (!this.responseMacs.has(bssidStr)) {
          this.responseMacs.add(bssidStr);
          let result: EspProvisioningResult = new EspProvisioningResult(deviceAddress, bssidStr);
          listener.onResponse(result);
        }
      }
    });

    sock.on('error', (err: Error) => {
      console.warn(TAG, `Provision socket error: ${err.message}`);
    });
  }

  private async sendAck(deviceAddress: string): Promise<void> {
    let ackData: Uint8Array = new Uint8Array([1]);
    let ackBuf: ArrayBuffer = uint8ArrayToArrayBuffer(ackData);

    try {
      let ackSocket: socket.UDPSocket = socket.constructUDPSocketInstance();
      await ackSocket.bind({ address: '0.0.0.0', port: 0, family: 1 });

      await ackSocket.send({
        data: ackBuf,
        address: {
          address: deviceAddress,
          port: DEVICE_ACK_PORT,
          family: 1
        }
      });
      await ackSocket.send({
        data: ackBuf,
        address: {
          address: deviceAddress,
          port: DEVICE_ACK_PORT,
          family: 1
        }
      });

      try {
        ackSocket.close();
      } catch (_e) { /* ignore */ }
    } catch (_e) { /* ignore */ }
  }

  private async runProvisionSendLoop(
    request: EspProvisioningRequest,
    listener: EspProvisioningListener | null,
    portMark: number
  ): Promise<void> {
    await delay(300);

    if (!this.provisioning) {
      return;
    }

    let params: EspProvisioningParams;
    try {
      params = await EspProvisioningParams.create(request, portMark);
    } catch (e) {
      this.stopProvisioning();
      if (listener != null) {
        listener.onError(e instanceof Error ? e : new Error(String(e)));
      }
      return;
    }

    let packetList: Uint8Array[] = params.getPacketList();
    let startTime: number = Date.now();
    let interval: number = DATA_PKG_INTERVAL;

    TASK:
    while (this.provisioning) {
      for (let data of packetList) {
        if (!this.provisioning) {
          break TASK;
        }

        let sock = this.provisionSocket;
        if (sock == null) {
          break TASK;
        }

        try {
          await sock.send({
            data: uint8ArrayToArrayBuffer(data),
            address: {
              address: this.broadcastAddress,
              port: DEVICE_PORT,
              family: 1
            }
          });
        } catch (_e) {
          break TASK;
        }

        await delay(interval);
      }

      let cost: number = Date.now() - startTime;
      if (cost > DATA_PKG_TIMEOUT_SEND) {
        break;
      } else if (cost > DATA_PKG_TIMEOUT_SEND / 2) {
        interval = DATA_PKG_INTERVAL2;
      }

      await delay(interval);
    }
  }

  stopProvisioning(): void {
    this.provisioning = false;
    if (this.provisionSocket != null) {
      try {
        this.provisionSocket.close();
      } catch (_e) { /* ignore */ }
      this.provisionSocket = null;
    }
    if (this.provisionListener != null) {
      this.provisionListener.onStop();
      this.provisionListener = null;
    }
    this.responseMacs.clear();
  }
}
