/**
 * APProvisioner - AP-mode provisioning for ESP32 devices
 *
 * Flow (user-guided WiFi switching, no system-level permissions needed):
 *   1. User manually connects to ESP32 AP ("esp32-s3-wifi") via Settings
 *   2. App monitors WiFi connection and detects AP connectivity
 *   3. TCP connect to 192.168.4.1:8080
 *   4. Send JSON: {"cmd":"provision","ssid":"...","password":"...","auth":"..."}
 *   5. Wait for ESP32 confirmation
 *   6. User manually reconnects to target WiFi
 *   7. Return result
 */

import { util } from '@kit.ArkTS';
import { socket } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'APProvisioner';

/** AP provisioning phase for UI feedback */
export enum APProvisionPhase {
  /** Not started */
  IDLE = 0,
  /** Waiting for user to connect to ESP32 AP */
  WAITING_AP = 1,
  /** Connected to ESP32 AP, opening TCP */
  CONNECTING_TCP = 2,
  /** Sending WiFi credentials */
  SENDING_CREDS = 3,
  /** Waiting for ESP32 confirmation */
  WAITING_CONFIRM = 4,
  /** Provisioning successful, waiting user to reconnect to target WiFi */
  RECONNECTING = 5,
  /** Done */
  DONE = 6,
  /** Failed */
  ERROR = 7
}

/** Result returned by APProvisioner */
export class APProvisionResult {
  success: boolean = false;
  message: string = '';
  deviceIp: string = '';
  deviceBssid: string = '';
}

/** Callback interface for AP provisioning events */
export interface APProvisioningCallback {
  onPhaseChange(phase: APProvisionPhase, detail: string): void;
  onResult(result: APProvisionResult): void;
  onError(error: Error): void;
}

// Internal types for JSON protocol
class ProvisionCommand {
  cmd: string = 'provision';
  ssid: string = '';
  password: string = '';
  auth: string = '';
}

class TcpResponse {
  status: string = '';
  ip?: string;
  msg?: string;
}

class PingCommand {
  cmd: string = 'ping';
}

const ESP32_AP_SSID: string = 'esp32-s3-wifi';
const ESP32_AP_IP: string = '192.168.4.1';
const ESP32_TCP_PORT: number = 8080;
const AP_WAIT_TIMEOUT: number = 120000;      // 120s for user to manually connect to AP
const TCP_CONNECT_TIMEOUT: number = 5000;     // 5s TCP connect timeout
const CONFIRM_TIMEOUT: number = 8000;         // 8s wait for ESP32 confirmation
const RECONNECT_TIMEOUT: number = 120000;     // 120s for user to reconnect to target WiFi
const KEEPALIVE_INTERVAL: number = 10000;     // 10s keepalive ping

export class APProvisioner {
  private phase: APProvisionPhase = APProvisionPhase.IDLE;
  private callback: APProvisioningCallback | null = null;
  private tcpSocket: socket.TCPSocket | null = null;
  private keepaliveTimer: number | null = null;
  private cancelled: boolean = false;

  setCallback(cb: APProvisioningCallback): void {
    this.callback = cb;
  }

  getPhase(): APProvisionPhase {
    return this.phase;
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  private setPhase(phase: APProvisionPhase, detail: string): void {
    this.phase = phase;
    console.info(TAG, `Phase: ${APProvisionPhase[phase]} - ${detail}`);
    if (this.callback != null) {
      this.callback.onPhaseChange(phase, detail);
    }
  }

  /**
   * Main entry: provision ESP32 via AP mode.
   *
   * @param targetSsid  - the WiFi SSID to send to ESP32
   * @param targetPassword - the WiFi password to send to ESP32
   * @param targetAuth  - auth type (WPA, WPA2, WEP, nopass)
   */
  async provisionViaAP(
    targetSsid: string,
    targetPassword: string,
    targetAuth: string
  ): Promise<APProvisionResult> {
    let result: APProvisionResult = new APProvisionResult();
    this.cancelled = false;

    try {
      // --- Step 1: Wait for user to connect to ESP32 AP ---
      this.setPhase(APProvisionPhase.WAITING_AP,
        `Go to Settings > Wi-Fi and connect to "${ESP32_AP_SSID}"`);
      let apConnected: boolean = await this.waitForESP32AP();
      if (this.cancelled) {
        throw new Error('Cancelled by user');
      }
      if (!apConnected) {
        throw new Error(`Timed out waiting for ESP32 AP "${ESP32_AP_SSID}"`);
      }
      // Small delay for network stack to settle on AP
      await this.delay(1000);

      // --- Step 2: TCP connect to ESP32 ---
      this.setPhase(APProvisionPhase.CONNECTING_TCP, 'Connecting TCP to ESP32...');
      await this.connectTCP();
      if (this.cancelled) {
        throw new Error('Cancelled by user');
      }

      // --- Step 3: Send credentials ---
      this.setPhase(APProvisionPhase.SENDING_CREDS, 'Sending WiFi credentials...');
      let authType: string = this.normalizeAuth(targetAuth);
      await this.sendProvisionCommand(targetSsid, targetPassword, authType);
      if (this.cancelled) {
        throw new Error('Cancelled by user');
      }

      // --- Step 4: Wait for confirmation ---
      this.setPhase(APProvisionPhase.WAITING_CONFIRM, 'Waiting for ESP32 confirmation...');
      let confirmMsg: string = await this.waitForConfirmation();
      if (this.cancelled) {
        throw new Error('Cancelled by user');
      }

      // Parse device IP from response if available
      let deviceIp: string = '';
      try {
        let parsed: TcpResponse = JSON.parse(confirmMsg) as TcpResponse;
        if (parsed.status === 'connected' && parsed.ip != null) {
          deviceIp = parsed.ip;
        }
      } catch (_e) {
        // ignore parse error
      }

      // Stop keepalive
      this.stopKeepalive();
      this.closeTCPSocket();

      // --- Step 5: Wait for user to reconnect to target WiFi ---
      this.setPhase(APProvisionPhase.RECONNECTING,
        `Go to Settings > Wi-Fi and reconnect to "${targetSsid}"`);
      // Non-blocking: wait for reconnection or timeout
      await this.waitForTargetWiFi(targetSsid);

      // --- Done ---
      result.success = true;
      result.message = 'Provisioning successful';
      result.deviceIp = deviceIp;
      this.setPhase(APProvisionPhase.DONE, 'Provisioning complete');
    } catch (e) {
      this.stopKeepalive();
      this.closeTCPSocket();
      if (this.cancelled) {
        result.success = false;
        result.message = 'Cancelled';
        this.setPhase(APProvisionPhase.IDLE, 'Cancelled');
      } else {
        result.success = false;
        result.message = e instanceof Error ? e.message : String(e);
        this.setPhase(APProvisionPhase.ERROR, result.message);
        if (this.callback != null) {
          this.callback.onError(e instanceof Error ? e : new Error(String(e)));
        }
      }
    }

    if (this.callback != null) {
      this.callback.onResult(result);
    }
    return result;
  }

  /** Cancel provisioning in progress */
  cancel(): void {
    console.info(TAG, 'Cancel requested');
    this.cancelled = true;
    this.stopKeepalive();
    this.closeTCPSocket();
  }

  /** Clean up resources */
  close(): void {
    this.cancel();
    this.callback = null;
  }

  // ========== Internal Methods ==========

  /**
   * Poll wifiManager.getLinkedInfo() until connected to ESP32 AP or timeout.
   * User must manually connect to ESP32 AP via Settings.
   */
  private async waitForESP32AP(): Promise<boolean> {
    let deadline: number = Date.now() + AP_WAIT_TIMEOUT;
    while (Date.now() < deadline) {
      if (this.cancelled) {
        return false;
      }
      try {
        let linkedInfo = await wifiManager.getLinkedInfo();
        if (linkedInfo != null && linkedInfo.ssid != null) {
          let ssid: string = linkedInfo.ssid;
          if (ssid.startsWith('"') && ssid.endsWith('"')) {
            ssid = ssid.substring(1, ssid.length - 1);
          }
          if (ssid === ESP32_AP_SSID) {
            console.info(TAG, 'Connected to ESP32 AP');
            return true;
          }
        }
      } catch (e) {
        // getLinkedInfo may throw when switching networks, retry
      }
      await this.delay(1000);
    }
    console.warn(TAG, 'waitForESP32AP: timeout');
    return false;
  }

  /** Create TCP connection to ESP32 */
  private async connectTCP(): Promise<void> {
    this.tcpSocket = socket.constructTCPSocketInstance();

    return new Promise<void>((resolve: () => void, reject: (reason: Error) => void): void => {
      let timer: number = setTimeout((): void => {
        this.closeTCPSocket();
        reject(new Error('TCP connect timeout'));
      }, TCP_CONNECT_TIMEOUT);

      let sock: socket.TCPSocket = this.tcpSocket!;

      // Handle connect event
      sock.on('connect', (): void => {
        clearTimeout(timer);
        console.info(TAG, `TCP connected to ${ESP32_AP_IP}:${ESP32_TCP_PORT}`);
        this.startKeepalive();
        resolve();
      });

      // Handle error
      sock.on('error', (err: BusinessError): void => {
        clearTimeout(timer);
        console.warn(TAG, `TCP error: ${err.message}`);
        reject(new Error(`TCP error: ${err.message}`));
      });

      // Initiate connection
      sock.connect({
        address: {
          address: ESP32_AP_IP,
          port: ESP32_TCP_PORT,
          family: 1
        },
        timeout: TCP_CONNECT_TIMEOUT
      }).catch((e: Error): void => {
        clearTimeout(timer);
        reject(new Error(`TCP connect failed: ${e.message}`));
      });
    });
  }

  /** Send JSON provisioning command over TCP */
  private async sendProvisionCommand(ssid: string, password: string, auth: string): Promise<void> {
    let command: ProvisionCommand = new ProvisionCommand();
    command.cmd = 'provision';
    command.ssid = ssid;
    command.password = password;
    command.auth = auth;

    let jsonStr: string = JSON.stringify(command);
    console.info(TAG, `Sending: ${jsonStr}`);

    let encoder = new util.TextEncoder();
    let data: Uint8Array = encoder.encodeInto(jsonStr);

    if (this.tcpSocket == null) {
      throw new Error('TCP socket not connected');
    }

    try {
      await this.tcpSocket.send({
        data: data.buffer as ArrayBuffer
      });
      console.info(TAG, 'Provision command sent');
    } catch (e) {
      throw new Error(`Send failed: ${e.message}`);
    }
  }

  /**
   * Wait for ESP32 to confirm receipt.
   * Listens for TCP data and parses JSON responses.
   */
  private async waitForConfirmation(): Promise<string> {
    if (this.tcpSocket == null) {
      throw new Error('TCP socket not connected');
    }

    let sock: socket.TCPSocket = this.tcpSocket;
    let received: string = '';
    let decoder: util.TextDecoder = new util.TextDecoder();

    return new Promise<string>((resolve: (msg: string) => void, reject: (reason: Error) => void): void => {
      let timer: number = setTimeout((): void => {
        sock.off('message');
        reject(new Error(`Confirmation timeout (${CONFIRM_TIMEOUT}ms)`));
      }, CONFIRM_TIMEOUT);

      sock.on('message', (data: socket.SocketMessageInfo): void => {
        let raw: string = '';
        let msgBuf: ArrayBuffer = data.message;
        if (msgBuf != null && msgBuf.byteLength > 0) {
          let uint8Msg: Uint8Array = new Uint8Array(msgBuf);
          raw = decoder.decodeToString(uint8Msg);
        }

        if (raw.length === 0) {
          return;
        }

        received += raw;
        console.info(TAG, `TCP received: ${raw}`);

        if (received.includes('"status"')) {
          // Check for success conditions
          if (received.includes('"ok"') || received.includes('"connected"')) {
            clearTimeout(timer);
            sock.off('message');
            resolve(received);
            return;
          }
          // Check for error
          if (received.includes('"error"')) {
            clearTimeout(timer);
            sock.off('message');
            let errMsg: string = 'ESP32 returned error';
            try {
              let parsed: TcpResponse = JSON.parse(received) as TcpResponse;
              if (parsed.msg != null && parsed.msg.length > 0) {
                errMsg = parsed.msg;
              }
            } catch (_e) { /* ignore */ }
            reject(new Error(errMsg));
            return;
          }
          // Got "ok" but not final yet, extend wait
          if (received.includes('"ok"')) {
            clearTimeout(timer);
            timer = setTimeout((): void => {
              sock.off('message');
              resolve(received);
            }, 3000);
          }
        }
      });
    });
  }

  /**
   * Wait for user to reconnect to the target WiFi network.
   * Non-fatal: returns after timeout even if not reconnected.
   */
  private async waitForTargetWiFi(ssid: string): Promise<void> {
    let deadline: number = Date.now() + RECONNECT_TIMEOUT;
    while (Date.now() < deadline) {
      if (this.cancelled) {
        return;
      }
      try {
        let linkedInfo = await wifiManager.getLinkedInfo();
        if (linkedInfo != null && linkedInfo.ssid != null) {
          let currentSsid: string = linkedInfo.ssid;
          if (currentSsid.startsWith('"') && currentSsid.endsWith('"')) {
            currentSsid = currentSsid.substring(1, currentSsid.length - 1);
          }
          if (currentSsid === ssid) {
            console.info(TAG, `Reconnected to "${ssid}"`);
            return;
          }
        }
      } catch (e) {
        // Still switching, keep waiting
      }
      await this.delay(1000);
    }
    console.warn(TAG, 'Reconnect: timeout, continuing anyway');
  }

  /** Normalize auth type string */
  private normalizeAuth(auth: string): string {
    let upper: string = auth.toUpperCase();
    if (upper === 'NOPASS' || upper === 'NO PASS' || upper === 'OPEN' || upper === 'NONE') {
      return 'open';
    }
    if (upper === 'WEP') {
      return 'WEP';
    }
    if (upper === 'WPA' || upper === 'WPA2' || upper === 'WPA3') {
      return upper;
    }
    return 'WPA2'; // default
  }

  /** Send keepalive ping every 10s */
  private startKeepalive(): void {
    this.stopKeepalive();
    this.keepaliveTimer = setInterval((): void => {
      if (this.tcpSocket != null) {
        let ping: PingCommand = new PingCommand();
        let pingStr: string = JSON.stringify(ping);
        let encoder = new util.TextEncoder();
        let data: Uint8Array = encoder.encodeInto(pingStr);
        this.tcpSocket.send({ data: data.buffer as ArrayBuffer }).catch(() => {
          // Ignore keepalive errors
        });
      }
    }, KEEPALIVE_INTERVAL);
  }

  private stopKeepalive(): void {
    if (this.keepaliveTimer != null) {
      clearInterval(this.keepaliveTimer);
      this.keepaliveTimer = null;
    }
  }

  /** Close TCP socket if open */
  private closeTCPSocket(): void {
    if (this.tcpSocket != null) {
      try {
        this.tcpSocket.off('connect');
        this.tcpSocket.off('message');
        this.tcpSocket.off('error');
        this.tcpSocket.close();
      } catch (e) {
        console.warn(TAG, `closeTCPSocket error: ${e.message}`);
      }
      this.tcpSocket = null;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
