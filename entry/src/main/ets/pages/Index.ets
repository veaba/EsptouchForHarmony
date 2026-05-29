import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { customScan, scanBarcode, scanCore } from '@kit.ScanKit';
import { AsyncCallback, BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult } from '@kit.AbilityKit';
import { socket } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { APProvisioner, APProvisionPhase, APProvisionResult } from '../esptouch/provision/APProvisioner';
import type { APProvisioningCallback } from '../esptouch/provision/APProvisioner';
import { EspProvisioner } from '../esptouch/provision/EspProvisioner';
import { EspProvisioningRequestBuilder, EspProvisioningRequest } from '../esptouch/provision/EspProvisioningRequest';
import { EspProvisioningResult } from '../esptouch/provision/EspProvisioningResult';
import type { EspProvisioningListener } from '../esptouch/provision/EspProvisioningListener';
import { getLocalIpAddress, getBssidString, getSsidString, convertBssid2Bytes } from '../esptouch/provision/TouchNetUtil';
import { parseWiFiQRCode, WiFiCredentials } from '../esptouch/scan/QRCodeParser';

const TAG: string = 'EspTouch';

// --- Concrete listener classes ---

class APProvisioningCallbackImpl implements APProvisioningCallback {
  private onPhaseChangeCb: (phase: APProvisionPhase, detail: string) => void;
  private onResultCb: (result: APProvisionResult) => void;
  private onErrorCb: (error: Error) => void;

  constructor(
    onPhaseChange: (phase: APProvisionPhase, detail: string) => void,
    onResult: (result: APProvisionResult) => void,
    onError: (error: Error) => void
  ) {
    this.onPhaseChangeCb = onPhaseChange;
    this.onResultCb = onResult;
    this.onErrorCb = onError;
  }

  onPhaseChange(phase: APProvisionPhase, detail: string): void {
    this.onPhaseChangeCb(phase, detail);
  }

  onResult(result: APProvisionResult): void {
    this.onResultCb(result);
  }

  onError(error: Error): void {
    this.onErrorCb(error);
  }
}

class ProvisioningListenerImpl implements EspProvisioningListener {
  private onStartCb: () => void;
  private onResponseCb: (result: EspProvisioningResult) => void;
  private onStopCb: () => void;
  private onErrorCb: (error: Error) => void;

  constructor(
    onStart: () => void,
    onResponse: (result: EspProvisioningResult) => void,
    onStop: () => void,
    onError: (error: Error) => void
  ) {
    this.onStartCb = onStart;
    this.onResponseCb = onResponse;
    this.onStopCb = onStop;
    this.onErrorCb = onError;
  }

  onStart(): void {
    this.onStartCb();
  }

  onResponse(result: EspProvisioningResult): void {
    this.onResponseCb(result);
  }

  onStop(): void {
    this.onStopCb();
  }

  onError(error: Error): void {
    this.onErrorCb(error);
  }
}

function deviceKey(device: EspProvisioningResult): string {
  return device.bssid;
}

@Entry
@Component
struct Index {
  // WiFi info
  @State wifiSsid: string = 'Loading...';
  @State wifiBssid: string = 'Loading...';
  @State wifiIp: string = 'Loading...';

  // Tab: 0 = QR Scan (default), 1 = Manual
  @State activeTab: number = 0;

  // QR scan state
  @State isQrScanning: boolean = false;
  @State scannedSsid: string = '';
  @State scannedPassword: string = '';
  @State qrPhase: number = 0; // 0=scanning, 1=confirmed, 2=provisioning
  @State apPhase: APProvisionPhase = APProvisionPhase.IDLE;
  @State apPhaseLabel: string = '';
  @State apProvisionDone: boolean = false;
  @State apProvisionSuccess: boolean = false;
  @State qrPreviewWidth: number = 360;
  @State qrPreviewHeight: number = 400;

  // Provision state
  @State isProvisioning: boolean = false;
  @State manualPassword: string = '';
  @State aesKey: string = '';
  @State useSecurityV2: boolean = false;

  // Discovered devices
  @State devices: EspProvisioningResult[] = [];
  @State selectedDeviceIndex: number = -1;

  // Log
  @State logText: string = '';
  @State testingDeviceBssid: string = '';

  // Non-state references
  private provisioner: EspProvisioner | null = null;
  private scanInitialized: boolean = false;
  private scannedCredentials: WiFiCredentials | null = null;
  private cameraSurfaceId: string = '';
  private xComponentCtrl: XComponentController = new XComponentController();
  aboutToAppear(): void {
    this.loadWifiInfo();
    this.provisioner = new EspProvisioner();
    this.appendLog('EspTouch V2 provisioner ready');

    // Estimate preview size from display
    try {
      let defaultDisplay = display.getDefaultDisplaySync();
      this.qrPreviewWidth = defaultDisplay.width;
      this.qrPreviewHeight = 380;
    } catch (e) {
      // Keep defaults
    }
  }

  onPageHide(): void {
    this.stopQrScanInternal();
    if (this.provisioner != null) {
      this.provisioner.close();
      this.provisioner = null;
    }
  }

  // ---------- WiFi Info ----------

  private async loadWifiInfo(): Promise<void> {
    try {
      let ssid: string = await getSsidString();
      this.wifiSsid = ssid.length > 0 ? ssid : 'Not connected';
    } catch (e) {
      this.wifiSsid = 'Unknown';
    }
    try {
      let bssid: string = await getBssidString();
      this.wifiBssid = bssid.length > 0 ? bssid : 'N/A';
    } catch (e) {
      this.wifiBssid = 'N/A';
    }
    let ip: string | null = getLocalIpAddress();
    this.wifiIp = ip != null ? ip : 'Unknown';
  }

  // ---------- Log ----------

  private appendLog(msg: string): void {
    let now: Date = new Date();
    let time: string =
      `${now.getHours().toString().padStart(2, '0')}:` +
      `${now.getMinutes().toString().padStart(2, '0')}:` +
      `${now.getSeconds().toString().padStart(2, '0')}`;
    this.logText = `[${time}] ${msg}\n${this.logText}`;
  }

  // ========== QR SCAN MODE ==========

  private onQrTabSelected(): void {
    // Camera is no longer auto-started. User taps "Start Camera" to begin.
  }

  private onLeaveQrTab(): void {
    this.stopQrScanInternal();
    this.scanInitialized = false; // Force re-init on return (surface may have changed)
  }

  private async requestCameraPermission(): Promise<boolean> {
    let atManager = abilityAccessCtrl.createAtManager();
    let tokenId: number = 0;

    // Get tokenId from bundleManager
    try {
      let bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      tokenId = bundleInfo.appInfo.accessTokenId;
      this.appendLog(`PermCheck: tokenId=${tokenId}`);
    } catch (e) {
      this.appendLog(`PermCheck: get tokenId failed: ${e.message}`);
      return false;
    }

    // Check if permission already granted
    try {
      let grantStatus: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(tokenId, 'ohos.permission.CAMERA');
      this.appendLog(`PermCheck: checkAccessTokenSync status=${grantStatus}`);
      if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.appendLog('PermCheck: already granted');
        return true;
      }
    } catch (e) {
      this.appendLog(`PermCheck: check failed: ${e.message}`);
      return false;
    }

    // Permission not granted, request from user via AtManager
    this.appendLog('PermCheck: requesting from user...');
    let permissionContext = getContext(this);
    return new Promise<boolean>((resolve: (granted: boolean) => void): void => {
      atManager.requestPermissionsFromUser(permissionContext, ['ohos.permission.CAMERA']).then(
        (result: PermissionRequestResult) => {
          let granted: boolean = result.authResults[0] === 0;
          this.appendLog(`PermCheck: user response authResult=${result.authResults[0]} granted=${granted}`);
          resolve(granted);
        }
      ).catch((e: Error) => {
        this.appendLog(`PermCheck: request failed: ${e.message}`);
        resolve(false);
      });
    });
  }

  private async startCameraScan(): Promise<void> {
    this.appendLog('=== Camera: startCameraScan begin ===');

    // Request camera permission first
    let granted: boolean = await this.requestCameraPermission();
    this.appendLog(`Camera: permission granted=${granted}`);
    if (!granted) {
      this.appendLog('Camera: start aborted — permission denied');
      return;
    }

    if (this.isQrScanning) {
      this.appendLog('Camera: already scanning, skip');
      return;
    }

    let surfaceId: string = this.cameraSurfaceId;
    this.appendLog(`Camera: surfaceId="${surfaceId}" len=${surfaceId.length}`);
    if (surfaceId.length === 0) {
      this.appendLog('Camera: surface not ready');
      return;
    }

    // Only initialize ScanKit once
    if (!this.scanInitialized) {
      this.appendLog('Camera: calling customScan.init()...');
      try {
        customScan.init({
          scanTypes: [scanCore.ScanType.QR_CODE],
          enableMultiMode: false,
          enableAlbum: false
        });
        this.scanInitialized = true;
        this.appendLog('Camera: customScan.init() OK');
      } catch (e) {
        this.appendLog(`Camera: init failed: ${e.message}`);
        return;
      }
    } else {
      this.appendLog('Camera: already initialized, skip init');
    }

    // Start (or restart after stop)
    this.appendLog('Camera: calling customScan.start()...');
    // Use display-aligned dimensions for proper camera aspect ratio
    let scanWidth: number = this.qrPreviewWidth;
    let scanHeight: number = Math.round(this.qrPreviewWidth * 0.56); // ~16:9 ratio
    this.appendLog(`Camera: viewControl ${scanWidth}x${scanHeight}`);
    let viewControl: customScan.ViewControl = {
      width: scanWidth,
      height: scanHeight,
      surfaceId: surfaceId
    };

    try {
      customScan.start(viewControl, this.scanCallback);
      this.isQrScanning = true;
      this.appendLog('Camera: customScan.start() OK — scanning');
    } catch (e) {
      this.appendLog(`Camera: start failed: ${e.message}`);
      this.isQrScanning = false;
    }
  }

  private stopQrScanInternal(): void {
    this.isQrScanning = false;
    try {
      customScan.stop();
    } catch (e) {
      // Ignore errors if scan wasn't running
    }
  }

  private onXComponentLoad(surfaceId: string): void {
    this.cameraSurfaceId = surfaceId;
    this.appendLog(`XComponent: onLoad fired, surfaceId="${surfaceId}" len=${surfaceId.length}`);
    if (surfaceId.length === 0) {
      this.appendLog('XComponent: ERROR surfaceId is empty');
      return;
    }
    this.appendLog('XComponent: surface ready, user can tap Start Camera');

    // If camera was scanning but XComponent surface changed, restart camera with new surface
    if (this.isQrScanning) {
      this.appendLog('XComponent: surface changed while scanning, restarting camera...');
      this.restartCameraScan(surfaceId);
    }
  }

  private async restartCameraScan(newSurfaceId: string): Promise<void> {
    // Stop old scan session
    try {
      customScan.stop();
      this.appendLog('Camera: stopped for restart');
    } catch (e) {
      // Ignore
    }
    this.isQrScanning = false;

    // Small delay to let surface settle
    await this.delay(200);

    // Start with new surface ID
    let scanWidth: number = this.qrPreviewWidth;
    let scanHeight: number = Math.round(this.qrPreviewWidth * 0.56);
    let viewControl: customScan.ViewControl = {
      width: scanWidth,
      height: scanHeight,
      surfaceId: newSurfaceId
    };
    try {
      customScan.start(viewControl, this.scanCallback);
      this.isQrScanning = true;
      this.appendLog(`Camera: restart OK with surface=${newSurfaceId}`);
    } catch (e) {
      this.appendLog(`Camera: restart failed: ${e.message}`);
    }
  }

  private scanCallback: AsyncCallback<Array<scanBarcode.ScanResult>> =
    (error: BusinessError, result: Array<scanBarcode.ScanResult>): void => {
      if (error != null) {
        return;
      }
      if (result == null || result.length === 0) {
        try { customScan.rescan(); } catch (_e) { /* ignore */ }
        return;
      }

      let rawValue: string = result[0].originalValue;

      // Parse WiFi QR
      let creds: WiFiCredentials | null = parseWiFiQRCode(rawValue);
      if (creds == null) {
        // Not a WiFi QR, continue scanning
        try { customScan.rescan(); } catch (_e) { /* ignore */ }
        return;
      }

      // Valid WiFi QR — stop scanning, show dialog
      this.stopQrScanInternal();
      this.scannedCredentials = creds;
      this.scannedSsid = creds.ssid;
      this.scannedPassword = creds.password;

      this.appendLog(`QR scanned: SSID="${creds.ssid}"`);

      // Show confirmation dialog
      AlertDialog.show({
        title: 'WiFi Network Found',
        message: `SSID: ${creds.ssid}\nPassword: ${creds.password.length > 0 ? creds.password : '(none)'}\nAuth: ${creds.authType}`,
        autoCancel: false,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: 'Cancel',
          action: (): void => {
            this.scannedCredentials = null;
            this.scannedSsid = '';
            this.scannedPassword = '';
            // Camera was stopped. User can tap "Start Camera" to begin again.
          }
        },
        secondaryButton: {
          value: 'Provision',
          action: (): void => {
            this.qrPhase = 1;
            this.startQRProvisionFlow();
          }
        }
      });
    };

  private async startQRProvisionFlow(): Promise<void> {
    let creds: WiFiCredentials | null = this.scannedCredentials;
    if (creds == null) {
      this.appendLog('No QR credentials');
      return;
    }

    this.qrPhase = 2;
    this.isProvisioning = true;
    this.devices = [];
    this.selectedDeviceIndex = -1;
    this.apProvisionDone = false;
    this.apProvisionSuccess = false;
    this.apPhase = APProvisionPhase.IDLE;
    this.appendLog(`Starting AP provisioning for "${creds.ssid}"`);

    // Use APProvisioner: connect to ESP32 AP -> TCP send credentials -> reconnect
    let apProvisioner: APProvisioner = new APProvisioner();

    // Listen for phase changes to update UI
    apProvisioner.setCallback(new APProvisioningCallbackImpl(
      (phase: APProvisionPhase, detail: string): void => {
        this.apPhase = phase;
        this.apPhaseLabel = detail;
        this.appendLog(`AP Phase: ${APProvisionPhase[phase]} - ${detail}`);
      },
      (result: APProvisionResult): void => {
        this.isProvisioning = false;
        this.apProvisionDone = true;
        this.apProvisionSuccess = result.success;
        if (result.success) {
          this.appendLog(`Provisioning success! Device IP: ${result.deviceIp}`);
          // Add a virtual device entry for the result
          let addr: string = result.deviceIp.length > 0 ? result.deviceIp : '192.168.4.1';
          this.devices.push(new EspProvisioningResult(addr, 'ESP32'));
        } else {
          this.appendLog(`Provisioning failed: ${result.message}`);
        }
        apProvisioner.close();
      },
      (error: Error): void => {
        this.appendLog(`APProvisioner error: ${error.message}`);
      }
    ));

    // Start provisioning (non-blocking fire-and-forget; callbacks handle UI)
    apProvisioner.provisionViaAP(creds.ssid, creds.password, creds.authType).then(() => {
      this.appendLog('AP provision flow completed');
    }).catch((e: Error) => {
      this.appendLog(`AP provision flow error: ${e.message}`);
    });
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private resetQRScan(): void {
    this.qrPhase = 0;
    this.scannedSsid = '';
    this.scannedPassword = '';
    this.scannedCredentials = null;
    this.devices = [];
    this.selectedDeviceIndex = -1;
    this.apProvisionDone = false;
    this.apProvisionSuccess = false;
    this.apPhase = APProvisionPhase.IDLE;
    this.apPhaseLabel = '';
  }

  // ========== MANUAL MODE: PROVISION ==========

  private startProvision(): void {
    if (this.provisioner == null) {
      this.provisioner = new EspProvisioner();
      this.appendLog('Provisioner re-created');
    }

    if (this.provisioner.isProvisioning()) {
      this.appendLog('Already provisioning');
      return;
    }

    let encoder: util.TextEncoder = new util.TextEncoder();
    let builder: EspProvisioningRequestBuilder = new EspProvisioningRequestBuilder();

    if (this.manualPassword.length > 0) {
      builder.setPassword(encoder.encodeInto(this.manualPassword));
    }

    if (this.aesKey.length > 0) {
      let keyBytes: Uint8Array = encoder.encodeInto(this.aesKey);
      if (keyBytes.length === 16) {
        builder.setAESKey(keyBytes);
      } else {
        this.appendLog('Warning: AES key must be exactly 16 bytes, ignoring');
      }
    }

    if (this.useSecurityV2) {
      builder.setSecurityVer(2);
    }

    // Target selected device if one is selected
    if (this.selectedDeviceIndex >= 0 && this.selectedDeviceIndex < this.devices.length) {
      let selectedDevice: EspProvisioningResult = this.devices[this.selectedDeviceIndex];
      try {
        let bssidBytes: Uint8Array = convertBssid2Bytes(selectedDevice.bssid);
        builder.setBSSID(bssidBytes);
        this.appendLog(`Targeting selected device: ${selectedDevice.bssid}`);
      } catch (e) {
        this.appendLog(`Warning: invalid selected device BSSID, falling back to broadcast`);
      }
    }

    let listener: ProvisioningListenerImpl = new ProvisioningListenerImpl(
      (): void => {
        this.isProvisioning = true;
        this.appendLog('Provisioning started...');
      },
      (result: EspProvisioningResult): void => {
        this.appendLog(`Device responded: ${result.bssid} @ ${result.address}`);
        let exists: boolean = this.devices.some((d: EspProvisioningResult): boolean => d.bssid === result.bssid);
        if (!exists) {
          this.devices.push(result);
        }
      },
      (): void => {
        this.isProvisioning = false;
        this.appendLog('Provisioning stopped');
      },
      (error: Error): void => {
        this.isProvisioning = false;
        this.appendLog(`Provisioning error: ${error.message}`);
      }
    );

    builder.build().then((request: EspProvisioningRequest): void => {
      if (this.provisioner != null) {
        this.provisioner.startProvisioning(request, listener);
        this.appendLog('Sending provision request...');
      }
    }).catch((e: Error): void => {
      this.appendLog(`Failed to build request: ${e.message}`);
    });
  }

  private stopProvision(): void {
    if (this.provisioner != null) {
      this.provisioner.stopProvisioning();
    }
  }

  private clearLog(): void {
    this.logText = '';
  }

  private copyLog(): void {
    try {
      let pb = pasteboard.getSystemPasteboard();
      pb.setData(pasteboard.createData({ 'text/plain': this.logText }));
      this.appendLog('Log copied to clipboard');
    } catch (e) {
      this.appendLog(`Copy failed: ${e.message}`);
    }
  }

  private copyTextToClipboard(text: string): void {
    try {
      let pb = pasteboard.getSystemPasteboard();
      pb.setData(pasteboard.createData({ 'text/plain': text }));
    } catch (e) {
      this.appendLog(`Copy failed: ${e.message}`);
    }
  }

  // ---------- Device Actions (post-provisioning) ----------

  private showDeviceActionsDialog(device: EspProvisioningResult): void {
    AlertDialog.show({
      title: 'Device Connected',
      message: `BSSID: ${device.bssid}\nIP: ${device.address}\n\nThe device has been configured. What would you like to do?`,
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: 'Test Connection',
        action: (): void => {
          this.testDeviceConnection(device);
        }
      },
      secondaryButton: {
        value: 'Copy IP',
        action: (): void => {
          this.copyTextToClipboard(device.address);
          this.appendLog(`Copied device IP: ${device.address}`);
        }
      }
    });
  }

  private async testDeviceConnection(device: EspProvisioningResult): Promise<void> {
    if (this.testingDeviceBssid === device.bssid) {
      return;
    }
    this.testingDeviceBssid = device.bssid;
    this.appendLog(`Testing connection to ${device.bssid} (${device.address})...`);

    let ports: number[] = [80, 8080, 443];
    let connected: boolean = false;
    let connectedPort: number = 0;

    for (let port of ports) {
      let tcpSocket: socket.TCPSocket = socket.constructTCPSocketInstance();
      try {
        connected = await new Promise<boolean>((resolve: (result: boolean) => void): void => {
          let timer: number = setTimeout((): void => {
            try { tcpSocket.close(); } catch (_e) { /* ignore */ }
            resolve(false);
          }, 2000);

          tcpSocket.connect({
            address: {
              address: device.address,
              port: port,
              family: 1
            },
            timeout: 3000
          }).then((): void => {
            clearTimeout(timer);
            connectedPort = port;
            resolve(true);
          }).catch((): void => {
            clearTimeout(timer);
            resolve(false);
          });
        });
      } catch (e) {
        // socket error, try next port
      }

      try { tcpSocket.close(); } catch (_e) { /* ignore */ }

      if (connected) {
        break;
      }
    }

    if (connected) {
      this.appendLog(`Device ${device.bssid} is reachable on port ${connectedPort}`);
    } else {
      this.appendLog(`Device ${device.bssid} did not respond on ports 80, 8080, or 443`);
    }

    this.testingDeviceBssid = '';
  }

  // ========== UI ==========

  build() {
    Column() {
      // Header
      Text('EsptouchForHarmony')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 10 })
        .backgroundColor('#0D47A1')
        .fontColor(Color.White)

      // Tab bar
      Row() {
        this.tabButton('QR Scan', 0)
        this.tabButton('Manual', 1)
      }
      .width('100%')
      .height(44)
      .backgroundColor('#E3F2FD')
      .padding(0)

      // Camera section: only rendered on QR Scan tab, completely absent on Manual tab
      if (this.activeTab === 0) {
        Stack() {
          XComponent({
            id: 'camera-preview',
            type: XComponentType.SURFACE,
            controller: this.xComponentCtrl
          })
            .width('100%')
            .height('100%')
            .onLoad((): void => {
              let surfaceId: string = this.xComponentCtrl.getXComponentSurfaceId();
              this.onXComponentLoad(surfaceId);
            })

          // Overlay: scan frame or start button (only when in scan phase)
          if (this.qrPhase === 0) {
            Column() {
              if (this.isQrScanning) {
                // Scan frame
                Column() {
                  Text('Align QR code within the frame')
                    .fontSize(14)
                    .fontColor(Color.White)
                    .margin({ top: 24 })
                  Blank()
                  Column() {
                    Text(' ')
                      .width(220)
                      .height(220)
                      .border({
                        width: { left: 2, top: 2, right: 0, bottom: 0 },
                        color: { left: '#00E676', top: '#00E676' }
                      })
                  }
                  .width(240)
                  .height(240)
                  .border({
                    width: { right: 2, bottom: 2 },
                    color: { right: '#00E676', bottom: '#00E676' }
                  })
                  .alignItems(HorizontalAlign.End)
                  .justifyContent(FlexAlign.End)
                  Blank()
                  Text(' ')
                    .height(16)
                }
              } else {
                // Start button overlay
                Column() {
                  Blank()
                  Button('Start Camera')
                    .width(160)
                    .height(48)
                    .backgroundColor('#1976D2')
                    .fontColor(Color.White)
                    .fontSize(16)
                    .borderRadius(24)
                    .onClick((): void => {
                      this.startCameraScan();
                    })
                  Blank()
                  Text('Tap to begin QR scanning')
                    .fontSize(13)
                    .fontColor('#B0BEC5')
                    .margin({ bottom: 16 })
                }
              }
            }
            .width('100%')
            .height('100%')
            .backgroundColor(this.isQrScanning ? '#00000000' : '#80000000')
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('45%')
      }

      // Content area (scrollable)
      if (this.activeTab === 0) {
        this.qrScanTab()
      } else {
        this.manualTab()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f0f4f8')
  }

  @Builder tabButton(label: string, tabIndex: number) {
    Text(label)
      .fontSize(15)
      .fontWeight(this.activeTab === tabIndex ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.activeTab === tabIndex ? '#0D47A1' : '#666')
      .width('50%')
      .height('100%')
      .textAlign(TextAlign.Center)
      .border({
        width: { bottom: this.activeTab === tabIndex ? 3 : 0 },
        color: { bottom: '#0D47A1' }
      })
      .onClick((): void => {
        if (this.activeTab !== tabIndex) {
          if (this.activeTab === 0) {
            this.onLeaveQrTab();
          }
          this.activeTab = tabIndex;
          if (tabIndex === 0) {
            this.onQrTabSelected();
          }
        }
      })
  }

  // ---------- QR Scan Tab ----------

  @Builder qrScanTab() {
    Scroll() {
      Column() {
        if (this.qrPhase === 0) {
          // === Scanning mode ===
          // Camera preview is rendered directly in build() for surface lifecycle stability

          // WiFi info hint
          Row() {
            Text('Current WiFi: ')
              .fontSize(13)
              .fontColor('#666')
            Text(this.wifiSsid)
              .fontSize(13)
              .fontColor('#333')
              .fontWeight(FontWeight.Bold)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 4 })

          Text('Scan a WiFi QR code to automatically configure your ESP32 device.')
            .fontSize(13)
            .fontColor('#888')
            .padding({ left: 16, right: 16 })
        } else {
          // === Confirmed / Provisioning mode ===
          this.sectionTitle('QR Credentials')
          Row() {
            Text('SSID: ')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
            Text(this.scannedSsid)
              .fontSize(14)
          }.width('100%').padding({ left: 16, right: 16, top: 4 })

          Row() {
            Text('Password: ')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
            Text(this.scannedPassword.length > 0 ? this.scannedPassword : '(none)')
              .fontSize(14)
          }.width('100%').padding({ left: 16, right: 16, top: 4 })

          Row() {
            if (this.isProvisioning) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color('#1976D2')
                .margin({ right: 8 })
              Column() {
                Text('Provisioning...')
                  .fontSize(14)
                  .fontColor('#1976D2')
                Text(this.apPhaseLabel.length > 0 ? this.apPhaseLabel : 'Starting AP provisioning...')
                  .fontSize(12)
                  .fontColor('#666')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
            } else if (this.apProvisionDone && this.apProvisionSuccess) {
              Column() {
                Text('Device configured successfully')
                  .fontSize(14)
                  .fontColor('#388E3C')
                Text('ESP32 received WiFi credentials via AP')
                  .fontSize(12)
                  .fontColor('#666')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
            } else if (this.apProvisionDone && !this.apProvisionSuccess) {
              Column() {
                Text('Provisioning failed')
                  .fontSize(14)
                  .fontColor('#D32F2F')
                Text('Check ESP32 AP status and try again')
                  .fontSize(12)
                  .fontColor('#666')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
            } else {
              Text('Provisioning completed')
                .fontSize(14)
                .fontColor('#888')
            }
          }.width('100%').padding({ left: 16, right: 16, top: 12 })

          // User guidance for manual WiFi switching
          if (this.isProvisioning && this.apPhase === APProvisionPhase.WAITING_AP) {
            Column() {
              Text('Connect to ESP32 AP')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#E65100')
              Text('1. Open Settings > Wi-Fi')
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 8 })
              Text('2. Connect to "esp32-s3-wifi" (no password)')
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 4 })
              Text('3. Return to this app')
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 4 })
              Text('Waiting for connection... (120s timeout)')
                .fontSize(12)
                .fontColor('#888')
                .width('100%')
                .margin({ top: 8 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFF3E0')
            .borderRadius(8)
            .margin({ left: 16, right: 16, top: 8 })
          }

          if (this.isProvisioning && this.apPhase === APProvisionPhase.RECONNECTING) {
            Column() {
              Text('Reconnect to Your WiFi')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#E65100')
              Text(`1. Open Settings > Wi-Fi`)
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 8 })
              Text(`2. Reconnect to "${this.scannedSsid}"`)
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 4 })
              Text('3. Return to this app')
                .fontSize(14)
                .fontColor('#333')
                .width('100%')
                .margin({ top: 4 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#E8F5E9')
            .borderRadius(8)
            .margin({ left: 16, right: 16, top: 8 })
          }

          // Device results
          this.sectionTitle(`Devices (${this.devices.length})`)
          if (this.devices.length > 0) {
            List({ space: 6 }) {
              ForEach(this.devices, (device: EspProvisioningResult, index?: number) => {
                ListItem() {
                  Row() {
                    Column() {
                      Text(device.bssid)
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                      Text(device.address)
                        .fontSize(12)
                        .fontColor('#666')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Column() {
                      if (this.testingDeviceBssid === device.bssid) {
                        LoadingProgress()
                          .width(16)
                          .height(16)
                          .color('#1976D2')
                      }
                      Text('Actions')
                        .fontSize(13)
                        .fontColor('#1976D2')
                        .fontWeight(FontWeight.Bold)
                    }
                    .alignItems(HorizontalAlign.Center)
                    .onClick((): void => {
                      this.showDeviceActionsDialog(device);
                    })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceBetween)
                  .padding(12)
                  .backgroundColor('#E8F5E9')
                  .borderRadius(8)
                }
              }, deviceKey)
            }
            .width('100%')
            .height(this.devices.length * 56 > 140 ? 140 : this.devices.length * 56)
            .padding({ left: 16, right: 16, top: 4 })
          }

          // Action buttons
          Row() {
            if (this.isProvisioning) {
              Button('Stop')
                .width(120)
                .height(40)
                .backgroundColor('#D32F2F')
                .onClick((): void => { this.stopProvision(); })

              LoadingProgress()
                .width(24)
                .height(24)
                .margin({ left: 12 })
                .color('#1976D2')
            } else {
              Button('Scan Again')
                .width(120)
                .height(40)
                .backgroundColor('#1976D2')
                .onClick((): void => {
                  this.stopQrScanInternal();
                  this.resetQRScan();
                })
            }
          }.width('100%').padding({ left: 16, right: 16, top: 12 })
        }

        // Log (shared)
        Row() {
          Text('Event Log')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333')
            .layoutWeight(1)
          Button('Copy')
            .height(28)
            .fontSize(12)
            .backgroundColor('#555')
            .margin({ right: 6 })
            .onClick((): void => { this.copyLog(); })
          Button('Clear')
            .height(28)
            .fontSize(12)
            .backgroundColor('#888')
            .onClick((): void => { this.clearLog(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8 })

        Scroll() {
          Text(this.logText)
            .width('100%')
            .fontColor('#00ff00')
            .fontSize(12)
        }
        .width('100%')
        .height(150)
        .backgroundColor('#1a1a2e')
        .padding(8)
        .borderRadius(6)
        .scrollBar(BarState.On)
        .align(Alignment.Top)
        .margin({ bottom: 16 })
      }
    }
    .padding({ left: 8, right: 8 })
    .width('100%')
  }

  // ---------- Manual Tab ----------

  @Builder manualTab() {
    Scroll() {
      Column() {
        // WiFi Info
        this.sectionTitle('WiFi Info')
        Row() {
          Text('SSID:').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          Text(this.wifiSsid).fontSize(14).fontColor('#555').margin({ left: 8 })
        }.width('100%').padding({ left: 16, right: 16, top: 4 })

        Row() {
          Text('BSSID:').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          Text(this.wifiBssid).fontSize(14).fontColor('#555').margin({ left: 8 })
        }.width('100%').padding({ left: 16, right: 16, top: 4 })

        Row() {
          Text('IP:').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          Text(this.wifiIp).fontSize(14).fontColor('#555').margin({ left: 8 })
        }.width('100%').padding({ left: 16, right: 16, top: 4 })

        // Device List (devices are discovered during Provisioning)
        if (this.devices.length > 0) {
          this.sectionTitle(`Discovered Devices (${this.devices.length})`)
          List({ space: 6 }) {
            ForEach(this.devices, (device: EspProvisioningResult, index?: number) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(device.bssid).fontSize(14).fontWeight(FontWeight.Bold)
                    Text(device.address).fontSize(12).fontColor('#666')
                  }.alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (index !== undefined && this.selectedDeviceIndex === index) {
                    Text('Selected').fontSize(12).fontColor('#1976D2').margin({ left: 8 })
                  }

                  if (!this.isProvisioning) {
                    Blank().width(6)
                    Column() {
                      if (this.testingDeviceBssid === device.bssid) {
                        LoadingProgress().width(14).height(14).color('#1976D2')
                      }
                      Text('Actions')
                        .fontSize(12)
                        .fontColor('#1976D2')
                        .fontWeight(FontWeight.Bold)
                    }
                    .onClick((): void => {
                      this.showDeviceActionsDialog(device);
                    })
                  }
                }
                .width('100%')
                .justifyContent(FlexAlign.SpaceBetween)
                .padding(12)
                .backgroundColor(index !== undefined && this.selectedDeviceIndex === index ? '#E3F2FD' : '#F5F5F5')
                .borderRadius(8)
              }
              .onClick((): void => {
                if (index !== undefined) {
                  this.selectedDeviceIndex = index;
                  this.appendLog(`Selected device: ${device.bssid}`);
                }
              })
            }, deviceKey)
          }
          .width('100%')
          .height(this.devices.length * 60 > 240 ? 240 : this.devices.length * 60)
          .padding({ left: 16, right: 16, top: 4 })
        }

        // Provisioning (devices are discovered here)
        this.sectionTitle('Provisioning')
        Column() {
          Text('Password:').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          TextInput({ placeholder: 'Enter WiFi password', text: this.manualPassword })
            .width('100%').height(40).type(InputType.Password)
            .fontColor('#333333')
            .placeholderColor('#999999')
            .backgroundColor('#ffffff')
            .borderRadius(8)
            .onChange((val: string): void => { this.manualPassword = val; })
        }.width('100%').padding({ left: 16, right: 16, top: 4 })

        Column() {
          Text('AES Key (16 bytes, optional):').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          TextInput({ placeholder: 'AES key for Security V2', text: this.aesKey })
            .width('100%').height(40)
            .fontColor('#333333')
            .placeholderColor('#999999')
            .backgroundColor('#ffffff')
            .borderRadius(8)
            .onChange((val: string): void => { this.aesKey = val; })
        }.width('100%').padding({ left: 16, right: 16, top: 8 })

        Row() {
          Text('Security V2:').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333')
          Toggle({ type: ToggleType.Switch, isOn: this.useSecurityV2 })
            .margin({ left: 8 })
            .onChange((val: boolean): void => { this.useSecurityV2 = val; })
        }.width('100%').padding({ left: 16, right: 16, top: 8 })

        Row() {
          if (this.isProvisioning) {
            Button('Stop Provision').width(140).height(40).backgroundColor('#D32F2F')
              .onClick((): void => { this.stopProvision(); })
            LoadingProgress().width(24).height(24).margin({ left: 12 }).color('#1976D2')
          } else {
            Button('Start Provision').width(140).height(40).backgroundColor('#388E3C')
              .onClick((): void => { this.startProvision(); })
          }
        }.width('100%').padding({ left: 16, right: 16, top: 12 })

        // Log
        Row() {
          Text('Event Log')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333')
            .layoutWeight(1)
          Button('Copy')
            .height(28)
            .fontSize(12)
            .backgroundColor('#555')
            .margin({ right: 6 })
            .onClick((): void => { this.copyLog(); })
          Button('Clear').height(28).fontSize(12).backgroundColor('#888')
            .onClick((): void => { this.clearLog(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8 })

        Scroll() {
          Text(this.logText)
            .width('100%')
            .fontColor('#00ff00')
            .fontSize(12)
        }
        .width('100%').height(200)
        .backgroundColor('#1a1a2e')
        .padding(8).borderRadius(6)
        .scrollBar(BarState.On)
        .align(Alignment.Top)
        .margin({ bottom: 16 })
      }
    }
    .padding({ left: 8, right: 8 })
    .width('100%')
  }

  @Builder sectionTitle(title: string) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor('#1a1a2e')
      .padding({ left: 16, right: 16, top: 16, bottom: 4 })
      .width('100%')
  }
}
