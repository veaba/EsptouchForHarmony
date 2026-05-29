import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { DeviceStatus, WIFI_NOTIFY_STATUS_SUCCESS, WIFI_NOTIFY_STATUS_FAIL, WIFI_NOTIFY_STATUS_DISCONNECT } from './DeviceStatus';

export interface DeviceMonitorListener {
  onDeviceStatus(status: DeviceStatus): void;
  onMonitorError(error: Error): void;
}

const TAG: string = 'DeviceMonitor';
const DEVICE_MONITOR_PORT: number = 7001;

export class DeviceMonitor {
  private monitorSocket: socket.UDPSocket | null = null;
  private running: boolean = false;
  private paused: boolean = false;
  private listeners: DeviceMonitorListener[] = [];
  private retryTimer: number = -1;
  private retryCount: number = 0;
  private maxRetries: number = 30;

  start(): void {
    if (this.running) {
      console.info(TAG, 'start: already running, skip');
      return;
    }
    this.paused = false;
    console.info(TAG, `start: binding to 0.0.0.0:${DEVICE_MONITOR_PORT}, listeners=${this.listeners.length}, retryCount=${this.retryCount}`);
    this.doBind();
  }

  private doBind(): void {
    let sock: socket.UDPSocket = socket.constructUDPSocketInstance();
    console.info(TAG, `doBind: attempting bind on port ${DEVICE_MONITOR_PORT}...`);
    sock.bind({ address: '0.0.0.0', port: DEVICE_MONITOR_PORT, family: 1 }).then((): void => {
      console.info(TAG, `doBind: bind OK, setting broadcast=true...`);
      sock.setExtraOptions({ broadcast: true }).then((): void => {
        this.monitorSocket = sock;
        this.running = true;
        this.retryCount = 0;
        console.info(TAG, `doBind: SUCCESS, port ${DEVICE_MONITOR_PORT} broadcast=true, running=${this.running}`);

        sock.on('message', (data: socket.SocketMessageInfo): void => {
          if (!this.running || this.paused) {
            console.warn(TAG, `onMessage: dropped, running=${this.running}, paused=${this.paused}`);
            return;
          }
          let message: ArrayBuffer = data.message;
          let senderIp: string = data.remoteInfo.address;
          let senderPort: number = data.remoteInfo.port;
          let decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
          let text: string = decoder.decodeToString(new Uint8Array(message));
          console.info(TAG, `onMessage: from ${senderIp}:${senderPort}, raw="${text}", len=${message.byteLength}`);
          let status: DeviceStatus | null = DeviceStatus.parse(text, senderIp);
          if (status == null) {
            console.warn(TAG, `onMessage: parse failed, raw text="${text}"`);
            return;
          }
          console.info(TAG, `onMessage: parsed OK, success=${status.success}, ip=${status.ip}, mac=${status.mac}, ssid=${status.ssid}`);

          for (let listener of this.listeners) {
            listener.onDeviceStatus(status);
          }
        });

        sock.on('error', (err: Error): void => {
          console.error(TAG, `onError: ${err.message}`);
          if (this.running) {
            for (let listener of this.listeners) {
              listener.onMonitorError(err);
            }
            this.scheduleRebind();
          }
        });

        sock.on('close', (): void => {
          console.warn(TAG, 'onClose: socket closed unexpectedly');
          if (this.running && !this.paused) {
            this.scheduleRebind();
          }
        });
      }).catch((e: Error): void => {
        console.error(TAG, `doBind: setExtraOptions broadcast failed: ${e.message}`);
        this.scheduleRebind();
      });
    }).catch((e: Error): void => {
      console.error(TAG, `doBind: FAILED on port ${DEVICE_MONITOR_PORT}: ${e.message}`);
      try { sock.close(); } catch (_e) { /* ignore */ }
      this.scheduleRebind();
    });
  }

  private scheduleRebind(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
    }
    if (this.retryCount >= this.maxRetries) {
      console.error(TAG, `scheduleRebind: max retries (${this.maxRetries}) reached, giving up`);
      return;
    }
    this.retryCount++;
    console.info(TAG, `scheduleRebind: attempt ${this.retryCount}/${this.maxRetries} in 3s`);
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      this.doBind();
    }, 3000);
  }

  private closeSocket(): void {
    if (this.monitorSocket != null) {
      try {
        this.monitorSocket.off('message');
        this.monitorSocket.off('error');
        this.monitorSocket.off('close');
        this.monitorSocket.close();
      } catch (_e) { /* ignore */ }
      this.monitorSocket = null;
    }
  }

  pause(): void {
    if (!this.running) {
      return;
    }
    this.paused = true;
    this.running = false;
    this.closeSocket();
  }

  resume(): void {
    if (this.running) {
      return;
    }
    this.paused = false;
    this.retryCount = 0;
    this.doBind();
  }

  stop(): void {
    console.info(TAG, `stop: running=${this.running}`);
    this.running = false;
    this.paused = false;
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.closeSocket();
  }

  addListener(listener: DeviceMonitorListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: DeviceMonitorListener): void {
    let idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  isRunning(): boolean {
    return this.running;
  }
}