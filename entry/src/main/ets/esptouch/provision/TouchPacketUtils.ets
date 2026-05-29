export function getSyncPacket(): Uint8Array {
  return new Uint8Array(1048);
}

export function getSequenceSizePacket(size: number): Uint8Array {
  return new Uint8Array(1072 + size - 1);
}

export function getSequencePacket(sequence: number): Uint8Array {
  return new Uint8Array(128 + sequence);
}

export function getDataPacket(data: number, index: number): Uint8Array {
  return new Uint8Array((index << 7) | (1 << 6) | data);
}
