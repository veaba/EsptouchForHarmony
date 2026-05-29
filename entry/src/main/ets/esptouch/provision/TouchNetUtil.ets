import { util } from '@kit.ArkTS';
import { wifiManager } from '@kit.ConnectivityKit';
import { connection } from '@kit.NetworkKit';

function formatIpInt(ip: number): string {
  return `${(ip >> 24) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 8) & 0xff}.${ip & 0xff}`;
}

export function getBroadcastAddress(): string {
  try {
    let ipInfo = wifiManager.getIpInfo();
    if (ipInfo != null) {
      let broadcast: number = (ipInfo.ipAddress & ipInfo.netmask) | ((~ipInfo.netmask) >>> 0);
      return formatIpInt(broadcast);
    }
  } catch (_e) { /* ignore */ }
  return '255.255.255.255';
}

export async function getSsidString(): Promise<string> {
  try {
    let linkedInfo = await wifiManager.getLinkedInfo();
    if (linkedInfo != null && linkedInfo.ssid != null) {
      let ssid: string = linkedInfo.ssid;
      if (ssid.startsWith('"') && ssid.endsWith('"')) {
        ssid = ssid.substring(1, ssid.length - 1);
      }
      return ssid;
    }
  } catch (_e) { /* ignore */ }
  return '';
}

export async function getSsidBytes(): Promise<Uint8Array> {
  let ssid: string = await getSsidString();
  if (ssid.length > 0) {
    let encoder = new util.TextEncoder();
    return encoder.encodeInto(ssid);
  }
  return new Uint8Array(0);
}

export async function getBssidString(): Promise<string> {
  try {
    let linkedInfo = await wifiManager.getLinkedInfo();
    if (linkedInfo != null && linkedInfo.bssid != null) {
      return linkedInfo.bssid.toLowerCase();
    }
  } catch (_e) { /* ignore */ }
  return '';
}

export function getLocalIpAddress(): string | null {
  try {
    let ipInfo = wifiManager.getIpInfo();
    if (ipInfo != null && ipInfo.ipAddress !== 0) {
      return formatIpInt(ipInfo.ipAddress);
    }
  } catch (_e) { /* ignore */ }
  return null;
}

export function getAddress(ipAddress: number): string | null {
  if (ipAddress === 0) {
    return null;
  }
  return formatIpInt(ipAddress);
}

export function convertBssid2Bytes(bssid: string): Uint8Array {
  let parts: string[] = bssid.split(':');
  if (parts.length !== 6) {
    throw new Error(`Invalid BSSID format: ${bssid}`);
  }
  let result: Uint8Array = new Uint8Array(6);
  for (let i = 0; i < 6; i++) {
    result[i] = parseInt(parts[i], 16);
  }
  return result;
}

export function getIPv4Address(): Promise<string | null> {
  return new Promise<string | null>((resolve) => {
    try {
      let netHandle = connection.getDefaultNetSync();
      if (netHandle != null) {
        connection.getAddressesByName('localhost').then((addrs: connection.NetAddress[]) => {
          for (let addr of addrs) {
            let addrStr: string = addr.address;
            if (addrStr.includes('.') && !addrStr.startsWith('127.')) {
              resolve(addrStr);
              return;
            }
          }
          resolve(null);
        }).catch(() => {
          resolve(null);
        });
      } else {
        resolve(null);
      }
    } catch (_e) {
      resolve(null);
    }
  });
}

export function getIPv6Address(): Promise<string | null> {
  return new Promise<string | null>((resolve) => {
    try {
      let netHandle = connection.getDefaultNetSync();
      if (netHandle != null) {
        connection.getAddressesByName('localhost').then((addrs: connection.NetAddress[]) => {
          for (let addr of addrs) {
            let addrStr: string = addr.address;
            if (addrStr.includes(':') && !addrStr.startsWith('::')) {
              resolve(addrStr);
              return;
            }
          }
          resolve(null);
        }).catch(() => {
          resolve(null);
        });
      } else {
        resolve(null);
      }
    } catch (_e) {
      resolve(null);
    }
  });
}

export function is5G(frequency: number): boolean {
  return frequency > 4900 && frequency < 5900;
}
