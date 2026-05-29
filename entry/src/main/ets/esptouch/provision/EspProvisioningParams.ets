import { TouchCRC } from './TouchCRC';
import { TouchAES } from './TouchAES';
import { EspProvisioningRequest } from './EspProvisioningRequest';
import { getSyncPacket, getSequenceSizePacket, getSequencePacket, getDataPacket } from './TouchPacketUtils';
import { SEQUENCE_FIRST } from './IEspProvisioner';

const TAG: string = 'ProvisionParams';
const VERSION: number = 0;
const EMPTY_DATA: Uint8Array = new Uint8Array(0);

function randomBytes(length: number): Uint8Array {
  let result: Uint8Array = new Uint8Array(length);
  for (let i = 0; i < length; ++i) {
    result[i] = Math.floor(Math.random() * 127);
  }
  return result;
}

function concatUint8Arrays(arrays: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let arr of arrays) {
    totalLength += arr.length;
  }
  let result: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

export class EspProvisioningParams {
  private readonly packetList: Uint8Array[] = [];
  private readonly appPortMark: number;
  private password: Uint8Array = EMPTY_DATA;
  private ssid: Uint8Array = EMPTY_DATA;
  private reservedData: Uint8Array = EMPTY_DATA;
  private willEncrypt: boolean = false;
  private securityVer: number = 0;
  private aesKey: Uint8Array = EMPTY_DATA;
  private passwordEncode: boolean = false;
  private reservedEncode: boolean = false;
  private ssidEncode: boolean = false;
  private head: Uint8Array = EMPTY_DATA;

  private constructor(request: EspProvisioningRequest, portMark: number) {
    this.appPortMark = portMark;
    this.parse(request);
  }

  static async create(request: EspProvisioningRequest, portMark: number): Promise<EspProvisioningParams> {
    let params: EspProvisioningParams = new EspProvisioningParams(request, portMark);
    await params.generate();
    return params;
  }

  getPacketList(): Uint8Array[] {
    return [...this.packetList];
  }

  private checkCharEncode(data: Uint8Array): boolean {
    for (let i = 0; i < data.length; i++) {
      if (data[i] > 127) {
        return true;
      }
    }
    return false;
  }

  private parse(request: EspProvisioningRequest): void {
    let crcCalc: TouchCRC = new TouchCRC();

    let isIPv4: boolean = request.address != null && request.address.includes('.');

    this.password = request.password.length > 0 ? request.password : EMPTY_DATA;
    this.ssid = request.ssid.length > 0 ? request.ssid : EMPTY_DATA;
    this.reservedData = request.reservedData.length > 0 ? request.reservedData : EMPTY_DATA;

    this.willEncrypt = request.aesKey.length > 0 && (this.password.length > 0 || this.reservedData.length > 0);
    this.aesKey = this.willEncrypt ? request.aesKey : EMPTY_DATA;
    this.securityVer = request.securityVer & 0b11;

    this.passwordEncode = this.checkCharEncode(this.password);
    this.reservedEncode = this.checkCharEncode(this.reservedData);
    this.ssidEncode = this.checkCharEncode(this.ssid);

    let ssidInfo: number = this.ssid.length | (this.ssidEncode ? 0b10000000 : 0);
    let pwdInfo: number = this.password.length | (this.passwordEncode ? 0b10000000 : 0);
    let reservedInfo: number = this.reservedData.length | (this.reservedEncode ? 0b10000000 : 0);

    crcCalc.reset();
    crcCalc.update(request.bssid);
    let bssidCrc: number = crcCalc.getValue() & 0xff;

    let flag: number = (isIPv4 ? 1 : 0)
      | (this.willEncrypt ? (this.securityVer << 1) : 0)
      | ((this.appPortMark & 0b11) << 3)
      | ((VERSION & 0b11) << 6);

    this.head = new Uint8Array([ssidInfo, pwdInfo, reservedInfo, bssidCrc, flag, 0]);

    crcCalc.reset();
    crcCalc.update(this.head, 0, 5);
    let headerCrc: number = crcCalc.getValue() & 0xff;
    this.head[5] = headerCrc;
  }

  private setTotalSequenceSize(totalSequenceSize: number): void {
    let packet: Uint8Array = getSequenceSizePacket(totalSequenceSize);
    this.packetList[1] = packet;
    this.packetList[3] = packet;
  }

  private addDataFor6Bytes(buf: Uint8Array, sequence: number, seqCrc: number, tailIsCrc: boolean): void {
    if (sequence === SEQUENCE_FIRST) {
      let syncPacket: Uint8Array = getSyncPacket();
      let emptyPacket: Uint8Array = new Uint8Array(0);
      this.packetList.push(syncPacket);
      this.packetList.push(emptyPacket);
      this.packetList.push(syncPacket);
      this.packetList.push(emptyPacket);
    } else {
      let sequencePacket: Uint8Array = getSequencePacket(sequence);
      this.packetList.push(sequencePacket);
      this.packetList.push(sequencePacket);
      this.packetList.push(sequencePacket);
    }

    let bitCount: number = tailIsCrc ? 7 : 8;
    for (let i = 0; i < bitCount; ++i) {
      let data: number = (buf[5] >> i & 1)
        | ((buf[4] >> i & 1) << 1)
        | ((buf[3] >> i & 1) << 2)
        | ((buf[2] >> i & 1) << 3)
        | ((buf[1] >> i & 1) << 4)
        | ((buf[0] >> i & 1) << 5);

      let dataPacket: Uint8Array = getDataPacket(data, i);
      this.packetList.push(dataPacket);
    }

    if (tailIsCrc) {
      let seqCrcPacket: Uint8Array = getDataPacket(seqCrc, 7);
      this.packetList.push(seqCrcPacket);
    }
  }

  private async generate(): Promise<void> {
    let crcCalc: TouchCRC = new TouchCRC();

    let password: Uint8Array;
    let passwordPadding: Uint8Array;
    let passwordPaddingFactor: number;
    let passwordEncode: boolean;

    let reservedData: Uint8Array;
    let reservedPadding: Uint8Array;
    let reservedPaddingFactor: number;
    let reservedEncode: boolean;

    let ssid: Uint8Array;
    let ssidPadding: Uint8Array;
    let ssidPaddingFactor: number;
    let ssidEncode: boolean;

    let aesIV: Uint8Array = EMPTY_DATA;

    if (this.willEncrypt) {
      if (this.securityVer === 2) {
        aesIV = new Uint8Array(20);
        for (let i = 0; i < 20; i++) {
          aesIV[i] = Math.floor(Math.random() * 256);
        }
      }

      let aes: TouchAES = new TouchAES(this.aesKey, aesIV);

      let willEncryptData: Uint8Array = new Uint8Array(this.password.length + this.reservedData.length);
      willEncryptData.set(this.password, 0);
      willEncryptData.set(this.reservedData, this.password.length);

      let encryptedData: Uint8Array | null = await aes.encrypt(willEncryptData);
      password = encryptedData ?? EMPTY_DATA;
      passwordEncode = true;
      passwordPaddingFactor = 5;
      passwordPadding = EMPTY_DATA;
      let pad: number = passwordPaddingFactor - password.length % passwordPaddingFactor;
      if (pad < passwordPaddingFactor) {
        passwordPadding = randomBytes(pad);
      }

      reservedData = EMPTY_DATA;
      reservedPadding = EMPTY_DATA;
      reservedPaddingFactor = -1;
      reservedEncode = false;
    } else if (!this.passwordEncode && !this.reservedEncode) {
      let nonEncodeData: Uint8Array = new Uint8Array(this.password.length + this.reservedData.length);
      nonEncodeData.set(this.password, 0);
      nonEncodeData.set(this.reservedData, this.password.length);
      password = nonEncodeData;
      passwordEncode = false;
      passwordPaddingFactor = 6;
      passwordPadding = EMPTY_DATA;
      let pad: number = passwordPaddingFactor - nonEncodeData.length % passwordPaddingFactor;
      if (pad < passwordPaddingFactor) {
        passwordPadding = randomBytes(pad);
      }

      reservedData = EMPTY_DATA;
      reservedPadding = EMPTY_DATA;
      reservedPaddingFactor = -1;
      reservedEncode = false;
    } else {
      password = this.password;
      passwordEncode = this.passwordEncode;
      passwordPadding = EMPTY_DATA;
      passwordPaddingFactor = passwordEncode ? 5 : 6;
      let pad: number = passwordPaddingFactor - password.length % passwordPaddingFactor;
      if (pad < passwordPaddingFactor) {
        passwordPadding = randomBytes(pad);
      }

      reservedData = this.reservedData;
      reservedEncode = this.reservedEncode;
      reservedPadding = EMPTY_DATA;
      reservedPaddingFactor = reservedEncode ? 5 : 6;
      let pad2: number = reservedPaddingFactor - reservedData.length % reservedPaddingFactor;
      if (pad2 < reservedPaddingFactor) {
        reservedPadding = randomBytes(pad2);
      }
    }

    ssid = this.ssid;
    ssidEncode = this.ssidEncode;
    ssidPaddingFactor = ssidEncode ? 5 : 6;
    ssidPadding = EMPTY_DATA;
    let ssidPad: number = ssidPaddingFactor - ssid.length % ssidPaddingFactor;
    if (ssidPad < ssidPaddingFactor) {
      ssidPadding = randomBytes(ssidPad);
    }

    // Build complete data buffer (equivalent to ByteArrayOutputStream)
    let allData: Uint8Array = concatUint8Arrays([
      this.head,
      password,
      passwordPadding,
      reservedData,
      reservedPadding,
      aesIV,
      ssid,
      ssidPadding
    ]);

    let reservedBeginPosition: number = this.head.length + password.length + passwordPadding.length;
    let ivBeginPosition: number = reservedBeginPosition + reservedData.length + reservedPadding.length;
    let ssidBeginPosition: number = ivBeginPosition + aesIV.length;

    let readOffset: number = 0;
    let sequence: number = SEQUENCE_FIRST;
    let count: number = 0;

    while (readOffset < allData.length) {
      let expectLength: number;
      let crcInPacket: boolean;

      if (sequence < SEQUENCE_FIRST + 1) {
        // First data unit: read 6 bytes
        crcInPacket = true;
        expectLength = 6;
      } else {
        if (readOffset < reservedBeginPosition) {
          // Password data region
          crcInPacket = passwordEncode;
          expectLength = passwordPaddingFactor;
        } else if (readOffset < ivBeginPosition) {
          // Reserved data region
          crcInPacket = reservedEncode;
          expectLength = reservedPaddingFactor;
        } else if (readOffset < ssidBeginPosition) {
          // AES IV data region
          crcInPacket = true;
          expectLength = 5;
        } else {
          // SSID data region
          crcInPacket = ssidEncode;
          expectLength = ssidPaddingFactor;
        }
      }

      let buf: Uint8Array = new Uint8Array(6);
      let bytesToRead: number = Math.min(expectLength, allData.length - readOffset);
      for (let i = 0; i < bytesToRead; i++) {
        buf[i] = allData[readOffset + i];
      }
      readOffset += bytesToRead;

      crcCalc.reset();
      crcCalc.update(buf, 0, bytesToRead);
      let seqCrc: number = crcCalc.getValue() & 0xff;

      if (expectLength < buf.length) {
        buf[5] = seqCrc;
      }

      this.addDataFor6Bytes(buf, sequence, seqCrc, !crcInPacket);
      ++sequence;
      ++count;
    }

    this.setTotalSequenceSize(count);
  }
}
