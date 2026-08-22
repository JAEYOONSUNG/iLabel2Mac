const PNG_SIGNATURE = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);

export function rasterPixelSize(
  widthMM: number,
  heightMM: number,
  dpi: number,
): { width: number; height: number } {
  if (![widthMM, heightMM, dpi].every((value) => Number.isFinite(value) && value > 0)) {
    throw new Error("Raster dimensions and DPI must be positive finite numbers.");
  }
  return {
    width: Math.max(1, Math.round((widthMM / 25.4) * dpi)),
    height: Math.max(1, Math.round((heightMM / 25.4) * dpi)),
  };
}

function readUint32(bytes: Uint8Array, offset: number): number {
  return (
    bytes[offset]! * 0x1000000 +
    (bytes[offset + 1]! << 16) +
    (bytes[offset + 2]! << 8) +
    bytes[offset + 3]!
  ) >>> 0;
}

function writeUint32(value: number): Uint8Array {
  return new Uint8Array([
    (value >>> 24) & 0xff,
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  ]);
}

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function joinBytes(parts: readonly Uint8Array[]): Uint8Array {
  const length = parts.reduce((total, part) => total + part.length, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const typeBytes = new TextEncoder().encode(type);
  const checksumInput = joinBytes([typeBytes, data]);
  return joinBytes([
    writeUint32(data.length),
    typeBytes,
    data,
    writeUint32(crc32(checksumInput)),
  ]);
}

function isPNG(bytes: Uint8Array): boolean {
  return bytes.length >= PNG_SIGNATURE.length &&
    PNG_SIGNATURE.every((byte, index) => bytes[index] === byte);
}

export function setPNGDPI(bytes: Uint8Array, dpi: number): Uint8Array {
  if (!isPNG(bytes)) throw new Error("The image is not a PNG file.");
  if (!Number.isFinite(dpi) || dpi <= 0 || dpi > 100_000) {
    throw new Error("PNG DPI must be a positive finite number.");
  }
  const pixelsPerMeter = Math.round(dpi / 0.0254);
  const density = joinBytes([
    writeUint32(pixelsPerMeter),
    writeUint32(pixelsPerMeter),
    new Uint8Array([1]),
  ]);
  const densityChunk = chunk("pHYs", density);
  const parts: Uint8Array[] = [bytes.slice(0, PNG_SIGNATURE.length)];
  let offset = PNG_SIGNATURE.length;
  let inserted = false;
  while (offset + 12 <= bytes.length) {
    const length = readUint32(bytes, offset);
    const end = offset + 12 + length;
    if (end > bytes.length) throw new Error("The PNG chunk table is damaged.");
    const type = String.fromCharCode(
      bytes[offset + 4]!,
      bytes[offset + 5]!,
      bytes[offset + 6]!,
      bytes[offset + 7]!,
    );
    if (type !== "pHYs") parts.push(bytes.slice(offset, end));
    if (type === "IHDR" && !inserted) {
      parts.push(densityChunk);
      inserted = true;
    }
    offset = end;
    if (type === "IEND") break;
  }
  if (!inserted) throw new Error("The PNG has no IHDR chunk.");
  return joinBytes(parts);
}

export function readPNGDPI(bytes: Uint8Array): number | null {
  if (!isPNG(bytes)) return null;
  let offset = PNG_SIGNATURE.length;
  while (offset + 12 <= bytes.length) {
    const length = readUint32(bytes, offset);
    const end = offset + 12 + length;
    if (end > bytes.length) return null;
    const type = String.fromCharCode(
      bytes[offset + 4]!,
      bytes[offset + 5]!,
      bytes[offset + 6]!,
      bytes[offset + 7]!,
    );
    if (type === "pHYs" && length === 9 && bytes[offset + 16] === 1) {
      return readUint32(bytes, offset + 8) * 0.0254;
    }
    offset = end;
  }
  return null;
}

function base64ToBytes(value: string): Uint8Array {
  const decoded = atob(value);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  const chunkSize = 0x8000;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

export function setPNGDataURLDPI(dataURL: string, dpi: number): string {
  const match = /^data:image\/png;base64,([A-Za-z0-9+/=\s]+)$/i.exec(dataURL);
  if (!match) throw new Error("The value is not a PNG data URL.");
  const bytes = base64ToBytes(match[1]!.replace(/\s+/g, ""));
  return `data:image/png;base64,${bytesToBase64(setPNGDPI(bytes, dpi))}`;
}
