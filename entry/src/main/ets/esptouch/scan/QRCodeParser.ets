/**
 * QRCodeParser - Parse standard WiFi QR code format
 *
 * Standard format:
 *   WIFI:T:WPA;S:MYSSID;P:MYPASSWORD;;
 *   WIFI:T:nopass;S:MYSSID;;
 *
 * Fields:
 *   T = auth type (WPA/WEP/nopass)
 *   S = SSID (network name)
 *   P = password
 *   H = hidden (true/false), optional
 *
 * Escape rules: \; = literal semicolon, \\ = literal backslash
 */

const TAG: string = 'QRCodeParser';

export class WiFiCredentials {
  ssid: string = '';
  password: string = '';
  authType: string = 'WPA';
  isHidden: boolean = false;
}

function unescapeValue(value: string): string {
  let result: string = '';
  let i: number = 0;
  while (i < value.length) {
    let ch: string = value[i];
    if (ch === '\\' && i + 1 < value.length) {
      let next: string = value[i + 1];
      if (next === ';' || next === '\\') {
        result += next;
        i += 2;
        continue;
      }
    }
    result += ch;
    i++;
  }
  return result;
}

export function parseWiFiQRCode(content: string): WiFiCredentials | null {
  if (content == null) {
    console.info(TAG, 'parseWiFiQRCode: null content');
    return null;
  }

  let trimmed: string = content.trim();
  console.info(TAG, `parseWiFiQRCode: content="${trimmed.substring(0, 80)}..."`);

  // Must start with WIFI:
  if (!trimmed.toUpperCase().startsWith('WIFI:')) {
    console.warn(TAG, 'Not a WiFi QR code: missing WIFI: prefix');
    return null;
  }

  let body: string = trimmed.substring(5); // Remove "WIFI:" prefix
  let creds: WiFiCredentials = new WiFiCredentials();
  let hasS: boolean = false;
  let hasT: boolean = false;

  // Split by semicolons to get key:value pairs
  let parts: string[] = body.split(';');

  for (let part of parts) {
    let trimmedPart: string = part.trim();
    if (trimmedPart.length === 0) {
      continue;
    }

    // Expect format: X:value
    if (trimmedPart.length < 2 || trimmedPart[1] !== ':') {
      continue;
    }

    let key: string = trimmedPart[0].toUpperCase();
    let rawValue: string = trimmedPart.substring(2);
    let value: string = unescapeValue(rawValue);

    switch (key) {
      case 'S':
        creds.ssid = value;
        hasS = true;
        break;
      case 'P':
        creds.password = value;
        break;
      case 'T':
        creds.authType = value.toUpperCase();
        hasT = true;
        break;
      case 'H':
        creds.isHidden = (value.toUpperCase() === 'TRUE');
        break;
      default:
        // Unknown field, skip
        break;
    }
  }

  if (!hasS) {
    console.warn(TAG, 'Invalid WiFi QR code: missing SSID');
    return null;
  }

  if (!hasT) {
    creds.authType = 'nopass';
  }

  if (creds.authType === 'NOPASS' || creds.authType === 'NO PASS') {
    creds.authType = 'nopass';
    creds.password = '';
  }

  console.info(TAG, `parseWiFiQRCode: OK SSID="${creds.ssid}" auth=${creds.authType} pwdLen=${creds.password.length}`);
  return creds;
}
