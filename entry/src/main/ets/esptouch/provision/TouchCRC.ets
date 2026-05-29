const CRC_POLYNOM: number = 0x8c;
const CRC_INITIAL: number = 0x00;

const crcTable: number[] = new Array<number>(256);

// Initialize CRC lookup table
for (let dividend = 0; dividend < 256; ++dividend) {
  let remainder = dividend;
  for (let bit = 0; bit < 8; ++bit) {
    if ((remainder & 0x01) !== 0) {
      remainder = (remainder >>> 1) ^ CRC_POLYNOM;
    } else {
      remainder >>>= 1;
    }
  }
  crcTable[dividend] = remainder & 0xff;
}

export class TouchCRC {
  private value: number = CRC_INITIAL;

  reset(): void {
    this.value = CRC_INITIAL;
  }

  updateByte(data: number): void {
    let idx: number = (data ^ this.value) & 0xff;
    this.value = (crcTable[idx] ^ (this.value << 8)) & 0xffff;
  }

  update(buffer: Uint8Array, offset: number = 0, len: number = buffer.length): void {
    for (let i = 0; i < len; ++i) {
      let idx: number = (buffer[offset + i] ^ this.value) & 0xff;
      this.value = (crcTable[idx] ^ (this.value << 8)) & 0xffff;
    }
  }

  getValue(): number {
    return this.value & 0xff;
  }
}
