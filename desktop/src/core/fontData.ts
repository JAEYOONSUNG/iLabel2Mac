const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const MAX_SOURCE_FONT_BYTES = 32 * 1024 * 1024;
const MAX_OUTPUT_FONT_BYTES = 32 * 1024 * 1024;
const MAX_BASE64_WHITESPACE = 4_096;
const MAX_COLLECTION_FACES = 256;
const MAX_FONT_TABLES = 4_096;
const MAX_NAME_RECORDS = 8_192;
const SFNT_HEADER_BYTES = 12;
const SFNT_RECORD_BYTES = 16;
const TTC_V1 = 0x00010000;
const TTC_V2 = 0x00020000;
const CHECKSUM_MAGIC = 0xb1b0afba;
const EXTRACTED_FACE_CACHE_LIMIT = 16;
const EXTRACTED_FACE_CACHE_BYTES = 64 * 1024 * 1024;

interface CompactBase64 {
  value: string;
  byteLength: number;
}

interface TableRecord {
  tag: string;
  offset: number;
  length: number;
}

interface ParsedFace {
  signature: string;
  directoryStart: number;
  directoryEnd: number;
  tables: TableRecord[];
}

interface CachedFace {
  base64: string;
  byteLength: number;
}

const extractedFaceCache = new Map<string, CachedFace>();
let extractedFaceCacheBytes = 0;

function compactBase64(value: unknown): CompactBase64 | null {
  if (typeof value !== "string" || value.length === 0) return null;
  const maximumEncodedLength = Math.ceil(MAX_SOURCE_FONT_BYTES / 3) * 4;
  if (value.length > maximumEncodedLength + MAX_BASE64_WHITESPACE) return null;
  const compact = value.replace(/[\t\n\f\r ]+/g, "");
  if (
    compact.length === 0 ||
    compact.length > maximumEncodedLength ||
    compact.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(compact)
  ) {
    return null;
  }
  const padding = compact.endsWith("==") ? 2 : compact.endsWith("=") ? 1 : 0;
  const byteLength = (compact.length / 4) * 3 - padding;
  if (byteLength < 4 || byteLength > MAX_SOURCE_FONT_BYTES) return null;

  const finalQuartet = compact.slice(-4);
  if (padding === 2) {
    const second = BASE64_ALPHABET.indexOf(finalQuartet[1] ?? "");
    if (second < 0 || (second & 0x0f) !== 0) return null;
  } else if (padding === 1) {
    const third = BASE64_ALPHABET.indexOf(finalQuartet[2] ?? "");
    if (third < 0 || (third & 0x03) !== 0) return null;
  }
  return { value: compact, byteLength };
}

function decodeBase64(source: CompactBase64): Uint8Array | null {
  const output = new Uint8Array(source.byteLength);
  let outputIndex = 0;
  for (let index = 0; index < source.value.length; index += 4) {
    const first = BASE64_ALPHABET.indexOf(source.value[index] ?? "");
    const second = BASE64_ALPHABET.indexOf(source.value[index + 1] ?? "");
    const third = BASE64_ALPHABET.indexOf(source.value[index + 2] ?? "");
    const fourth = BASE64_ALPHABET.indexOf(source.value[index + 3] ?? "");
    if (first < 0 || second < 0) return null;
    output[outputIndex] = (first << 2) | (second >> 4);
    outputIndex += 1;
    if (outputIndex < output.length) {
      if (third < 0) return null;
      output[outputIndex] = ((second & 0x0f) << 4) | (third >> 2);
      outputIndex += 1;
    }
    if (outputIndex < output.length) {
      if (third < 0 || fourth < 0) return null;
      output[outputIndex] = ((third & 0x03) << 6) | fourth;
      outputIndex += 1;
    }
  }
  return outputIndex === output.length ? output : null;
}

function encodeBase64(bytes: Uint8Array): string {
  // The chunk is divisible by three, so concatenated chunks introduce no
  // interior padding and avoid manufacturing one very large binary string.
  const chunkSize = 0x6000;
  const chunks: string[] = [];
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + chunkSize));
    let binary = "";
    for (let index = 0; index < chunk.length; index += 1) {
      binary += String.fromCharCode(chunk[index]!);
    }
    chunks.push(btoa(binary));
  }
  return chunks.join("");
}

function fullDataFingerprint(compact: string): string {
  // cyrb128-style four-lane mixing is fast enough to scan multi-megabyte font
  // data on every lookup while giving cache keys 128 bits of collision space.
  let first = 1_779_033_703;
  let second = 3_144_134_277;
  let third = 1_013_904_242;
  let fourth = 2_773_480_762;
  for (let index = 0; index < compact.length; index += 1) {
    const value = compact.charCodeAt(index);
    first = second ^ Math.imul(first ^ value, 597_399_067);
    second = third ^ Math.imul(second ^ value, 2_869_860_233);
    third = fourth ^ Math.imul(third ^ value, 951_274_213);
    fourth = first ^ Math.imul(fourth ^ value, 2_716_044_179);
  }
  first = Math.imul(third ^ (first >>> 18), 597_399_067);
  second = Math.imul(fourth ^ (second >>> 22), 2_869_860_233);
  third = Math.imul(first ^ (third >>> 17), 951_274_213);
  fourth = Math.imul(second ^ (fourth >>> 19), 2_716_044_179);
  first ^= second ^ third ^ fourth;
  second ^= first;
  third ^= first;
  fourth ^= first;
  const hexadecimal = (value: number): string =>
    (value >>> 0).toString(16).padStart(8, "0");
  return `fd1-${compact.length.toString(36)}-${hexadecimal(first)}${hexadecimal(second)}${hexadecimal(third)}${hexadecimal(fourth)}`;
}

/** A deterministic full-payload fingerprint suitable for bounded cache keys. */
export function fontDataFingerprint(data: string): string | null {
  const compact = compactBase64(data);
  return compact ? fullDataFingerprint(compact.value) : null;
}

function rangeIsInside(
  byteLength: number,
  offset: number,
  length: number,
): boolean {
  return (
    Number.isSafeInteger(offset) &&
    Number.isSafeInteger(length) &&
    offset >= 0 &&
    length >= 0 &&
    offset <= byteLength &&
    length <= byteLength - offset
  );
}

function rangesOverlap(
  leftStart: number,
  leftEnd: number,
  rightStart: number,
  rightEnd: number,
): boolean {
  return leftStart < rightEnd && rightStart < leftEnd;
}

function tagAt(bytes: Uint8Array, offset: number): string | null {
  if (!rangeIsInside(bytes.length, offset, 4)) return null;
  let output = "";
  for (let index = 0; index < 4; index += 1) {
    const value = bytes[offset + index]!;
    if (value < 0x20 || value > 0x7e) return null;
    output += String.fromCharCode(value);
  }
  return output;
}

function rawSignatureAt(bytes: Uint8Array, offset: number): string | null {
  if (!rangeIsInside(bytes.length, offset, 4)) return null;
  return String.fromCharCode(
    bytes[offset]!,
    bytes[offset + 1]!,
    bytes[offset + 2]!,
    bytes[offset + 3]!,
  );
}

function isScalarSfntSignature(signature: string | null): boolean {
  return (
    signature === "\u0000\u0001\u0000\u0000" ||
    signature === "OTTO" ||
    signature === "true"
  );
}

function uint16(view: DataView, offset: number): number {
  return view.getUint16(offset, false);
}

function uint32(view: DataView, offset: number): number {
  return view.getUint32(offset, false);
}

function parseSfntFace(bytes: Uint8Array, offset: number): ParsedFace | null {
  if (!rangeIsInside(bytes.length, offset, SFNT_HEADER_BYTES)) return null;
  const signature = rawSignatureAt(bytes, offset);
  if (!isScalarSfntSignature(signature)) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tableCount = uint16(view, offset + 4);
  if (tableCount === 0 || tableCount > MAX_FONT_TABLES) return null;
  const directoryStart = offset;
  const directoryEnd = offset + SFNT_HEADER_BYTES + tableCount * SFNT_RECORD_BYTES;
  if (!rangeIsInside(bytes.length, offset, directoryEnd - offset)) return null;

  const seenTags = new Set<string>();
  const tables: TableRecord[] = [];
  for (let index = 0; index < tableCount; index += 1) {
    const recordOffset = offset + SFNT_HEADER_BYTES + index * SFNT_RECORD_BYTES;
    const tag = tagAt(bytes, recordOffset);
    if (!tag || seenTags.has(tag)) return null;
    seenTags.add(tag);
    const tableOffset = uint32(view, recordOffset + 8);
    const tableLength = uint32(view, recordOffset + 12);
    if (
      tableLength === 0 ||
      tableOffset % 4 !== 0 ||
      !rangeIsInside(bytes.length, tableOffset, tableLength)
    ) {
      return null;
    }
    tables.push({ tag, offset: tableOffset, length: tableLength });
  }

  const ranges = [...tables].sort((left, right) => left.offset - right.offset);
  for (let index = 1; index < ranges.length; index += 1) {
    const previous = ranges[index - 1]!;
    const current = ranges[index]!;
    if (current.offset < previous.offset + previous.length) return null;
  }
  return {
    signature: signature!,
    directoryStart,
    directoryEnd,
    tables,
  };
}

function validPostScriptName(value: string): boolean {
  return (
    value.length > 0 &&
    value.length < 64 &&
    /^[\x21-\x7e]+$/.test(value) &&
    !/[][(){}<>/%]/.test(value)
  );
}

function decodeNameRecord(
  bytes: Uint8Array,
  platformID: number,
): string | null {
  let output = "";
  if (platformID === 0 || platformID === 3) {
    if (bytes.length % 2 !== 0) return null;
    for (let index = 0; index < bytes.length; index += 2) {
      const codeUnit = (bytes[index]! << 8) | bytes[index + 1]!;
      output += String.fromCharCode(codeUnit);
    }
  } else {
    for (const value of bytes) output += String.fromCharCode(value);
  }
  return validPostScriptName(output) ? output : null;
}

function facePostScriptName(bytes: Uint8Array, face: ParsedFace): string | null {
  const name = face.tables.find((table) => table.tag === "name");
  if (!name || name.length < 6) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const format = uint16(view, name.offset);
  const recordCount = uint16(view, name.offset + 2);
  const stringOffset = uint16(view, name.offset + 4);
  if ((format !== 0 && format !== 1) || recordCount > MAX_NAME_RECORDS) {
    return null;
  }
  const recordsStart = name.offset + 6;
  const recordsEnd = recordsStart + recordCount * 12;
  if (!rangeIsInside(name.offset + name.length, recordsStart, recordsEnd - recordsStart)) {
    return null;
  }
  let minimumStringOffset = 6 + recordCount * 12;
  if (format === 1) {
    if (!rangeIsInside(name.offset + name.length, recordsEnd, 2)) return null;
    const languageTagCount = uint16(view, recordsEnd);
    const languageRecordsLength = languageTagCount * 4;
    if (!rangeIsInside(name.offset + name.length, recordsEnd + 2, languageRecordsLength)) {
      return null;
    }
    minimumStringOffset += 2 + languageRecordsLength;
  }
  if (stringOffset < minimumStringOffset || stringOffset > name.length) return null;
  const stringsStart = name.offset + stringOffset;
  const names = new Set<string>();

  for (let index = 0; index < recordCount; index += 1) {
    const record = recordsStart + index * 12;
    const platformID = uint16(view, record);
    const nameID = uint16(view, record + 6);
    const length = uint16(view, record + 8);
    const relativeOffset = uint16(view, record + 10);
    const valueOffset = stringsStart + relativeOffset;
    if (!rangeIsInside(name.offset + name.length, valueOffset, length)) return null;
    if (nameID !== 6) continue;
    const decoded = decodeNameRecord(
      bytes.subarray(valueOffset, valueOffset + length),
      platformID,
    );
    if (decoded) names.add(decoded);
  }
  return names.size === 1 ? [...names][0]! : null;
}

function parseCollection(bytes: Uint8Array): ParsedFace[] | null {
  if (rawSignatureAt(bytes, 0) !== "ttcf" || bytes.length < 12) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = uint32(view, 4);
  if (version !== TTC_V1 && version !== TTC_V2) return null;
  const faceCount = uint32(view, 8);
  if (faceCount === 0 || faceCount > MAX_COLLECTION_FACES) return null;
  let headerEnd = 12 + faceCount * 4;
  let dsigRange: { start: number; end: number } | undefined;
  if (!rangeIsInside(bytes.length, 0, headerEnd)) return null;
  if (version === TTC_V2) {
    if (!rangeIsInside(bytes.length, headerEnd, 12)) return null;
    const dsigTag = uint32(view, headerEnd);
    const dsigLength = uint32(view, headerEnd + 4);
    const dsigOffset = uint32(view, headerEnd + 8);
    if (
      (dsigLength === 0 && (dsigTag !== 0 || dsigOffset !== 0)) ||
      (dsigLength > 0 &&
        (dsigTag !== 0x44534947 || !rangeIsInside(bytes.length, dsigOffset, dsigLength)))
    ) {
      return null;
    }
    if (dsigLength > 0) {
      dsigRange = { start: dsigOffset, end: dsigOffset + dsigLength };
    }
    headerEnd += 12;
  }

  const seenOffsets = new Set<number>();
  const faces: ParsedFace[] = [];
  for (let index = 0; index < faceCount; index += 1) {
    const offset = uint32(view, 12 + index * 4);
    if (offset < headerEnd || offset % 4 !== 0 || seenOffsets.has(offset)) return null;
    seenOffsets.add(offset);
    const face = parseSfntFace(bytes, offset);
    if (!face) return null;
    faces.push(face);
  }

  const structures = [
    { start: 0, end: headerEnd },
    ...faces.map((face) => ({ start: face.directoryStart, end: face.directoryEnd })),
    ...(dsigRange ? [dsigRange] : []),
  ].sort((left, right) => left.start - right.start);
  for (let index = 1; index < structures.length; index += 1) {
    if (structures[index]!.start < structures[index - 1]!.end) return null;
  }
  for (const face of faces) {
    for (const table of face.tables) {
      if (
        structures.some((structure) =>
          rangesOverlap(
            table.offset,
            table.offset + table.length,
            structure.start,
            structure.end,
          ))
      ) {
        return null;
      }
    }
  }
  return faces;
}

function align4(value: number): number {
  return Math.ceil(value / 4) * 4;
}

function writeTag(view: DataView, offset: number, tag: string): void {
  for (let index = 0; index < 4; index += 1) {
    view.setUint8(offset + index, tag.charCodeAt(index));
  }
}

function checksum(bytes: Uint8Array, offset = 0, length = bytes.length): number {
  let sum = 0;
  const end = offset + align4(length);
  for (let cursor = offset; cursor < end; cursor += 4) {
    const word =
      ((bytes[cursor] ?? 0) << 24) |
      ((bytes[cursor + 1] ?? 0) << 16) |
      ((bytes[cursor + 2] ?? 0) << 8) |
      (bytes[cursor + 3] ?? 0);
    sum = (sum + (word >>> 0)) >>> 0;
  }
  return sum;
}

function extractStandaloneFace(bytes: Uint8Array, face: ParsedFace): Uint8Array | null {
  const tables = [...face.tables].sort((left, right) =>
    left.tag < right.tag ? -1 : left.tag > right.tag ? 1 : 0);
  const headIndex = tables.findIndex((table) => table.tag === "head");
  if (headIndex < 0 || tables[headIndex]!.length < 54) return null;
  const sourceView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (uint32(sourceView, tables[headIndex]!.offset + 12) !== 0x5f0f3cf5) {
    return null;
  }
  if (!facePostScriptName(bytes, face)) return null;

  let outputLength = align4(SFNT_HEADER_BYTES + tables.length * SFNT_RECORD_BYTES);
  const outputOffsets: number[] = [];
  for (const table of tables) {
    outputOffsets.push(outputLength);
    outputLength += align4(table.length);
    if (outputLength > MAX_OUTPUT_FONT_BYTES) return null;
  }
  const output = new Uint8Array(outputLength);
  const view = new DataView(output.buffer);
  for (let index = 0; index < 4; index += 1) {
    output[index] = face.signature.charCodeAt(index);
  }
  view.setUint16(4, tables.length, false);
  const maximumPower = 2 ** Math.floor(Math.log2(tables.length));
  const searchRange = maximumPower * SFNT_RECORD_BYTES;
  view.setUint16(6, searchRange, false);
  view.setUint16(8, Math.log2(maximumPower), false);
  view.setUint16(10, tables.length * SFNT_RECORD_BYTES - searchRange, false);

  tables.forEach((table, index) => {
    const outputOffset = outputOffsets[index]!;
    output.set(bytes.subarray(table.offset, table.offset + table.length), outputOffset);
  });
  const headOffset = outputOffsets[headIndex]!;
  view.setUint32(headOffset + 8, 0, false);

  tables.forEach((table, index) => {
    const record = SFNT_HEADER_BYTES + index * SFNT_RECORD_BYTES;
    const outputOffset = outputOffsets[index]!;
    writeTag(view, record, table.tag);
    view.setUint32(record + 4, checksum(output, outputOffset, table.length), false);
    view.setUint32(record + 8, outputOffset, false);
    view.setUint32(record + 12, table.length, false);
  });
  const adjustment = (CHECKSUM_MAGIC - checksum(output)) >>> 0;
  view.setUint32(headOffset + 8, adjustment, false);
  return checksum(output) === CHECKSUM_MAGIC ? output : null;
}

function standaloneSfntIsValid(bytes: Uint8Array): boolean {
  const face = parseSfntFace(bytes, 0);
  if (!face || face.directoryEnd > bytes.length) return false;
  if (
    face.tables.some((table) =>
      rangesOverlap(table.offset, table.offset + table.length, 0, face.directoryEnd))
  ) {
    return false;
  }
  const head = face.tables.find((table) => table.tag === "head");
  if (!head || head.length < 54) return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return (
    uint32(view, head.offset + 12) === 0x5f0f3cf5 &&
    Boolean(facePostScriptName(bytes, face))
  );
}

function woffIsValid(bytes: Uint8Array): boolean {
  if (bytes.length < 44 || rawSignatureAt(bytes, 0) !== "wOFF") return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (
    !isScalarSfntSignature(rawSignatureAt(bytes, 4)) ||
    uint32(view, 8) !== bytes.length ||
    uint16(view, 14) !== 0
  ) {
    return false;
  }
  const tableCount = uint16(view, 12);
  if (tableCount === 0 || tableCount > MAX_FONT_TABLES) return false;
  const directoryEnd = 44 + tableCount * 20;
  if (!rangeIsInside(bytes.length, 0, directoryEnd)) return false;
  const tags = new Set<string>();
  const ranges: Array<{ start: number; end: number }> = [];
  let reconstructedSize = SFNT_HEADER_BYTES + tableCount * SFNT_RECORD_BYTES;
  let hasHead = false;
  let hasName = false;
  for (let index = 0; index < tableCount; index += 1) {
    const record = 44 + index * 20;
    const tag = tagAt(bytes, record);
    if (!tag || tags.has(tag)) return false;
    tags.add(tag);
    hasHead ||= tag === "head";
    hasName ||= tag === "name";
    const offset = uint32(view, record + 4);
    const compressedLength = uint32(view, record + 8);
    const originalLength = uint32(view, record + 12);
    if (
      compressedLength === 0 ||
      compressedLength > originalLength ||
      offset < directoryEnd ||
      offset % 4 !== 0 ||
      !rangeIsInside(bytes.length, offset, compressedLength)
    ) {
      return false;
    }
    reconstructedSize += align4(originalLength);
    ranges.push({ start: offset, end: offset + compressedLength });
  }
  ranges.sort((left, right) => left.start - right.start);
  for (let index = 1; index < ranges.length; index += 1) {
    if (ranges[index]!.start < ranges[index - 1]!.end) return false;
  }
  return hasHead && hasName && uint32(view, 16) === reconstructedSize;
}

function optionalWoffBlockIsValid(
  bytes: Uint8Array,
  offset: number,
  length: number,
): boolean {
  return offset === 0 ? length === 0 : length > 0 && rangeIsInside(bytes.length, offset, length);
}

function woff2IsValid(bytes: Uint8Array): boolean {
  if (bytes.length < 48 || rawSignatureAt(bytes, 0) !== "wOF2") return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (
    !isScalarSfntSignature(rawSignatureAt(bytes, 4)) ||
    uint32(view, 8) !== bytes.length ||
    uint16(view, 14) !== 0
  ) {
    return false;
  }
  const tableCount = uint16(view, 12);
  const totalSfntSize = uint32(view, 16);
  const compressedSize = uint32(view, 20);
  if (
    tableCount === 0 ||
    tableCount > MAX_FONT_TABLES ||
    totalSfntSize === 0 ||
    compressedSize === 0 ||
    compressedSize > bytes.length - 48
  ) {
    return false;
  }
  return (
    optionalWoffBlockIsValid(bytes, uint32(view, 28), uint32(view, 32)) &&
    optionalWoffBlockIsValid(bytes, uint32(view, 40), uint32(view, 44))
  );
}

function cachedFace(key: string): string | null {
  const cached = extractedFaceCache.get(key);
  if (!cached) return null;
  extractedFaceCache.delete(key);
  extractedFaceCache.set(key, cached);
  return cached.base64;
}

function cacheFace(key: string, base64: string, byteLength: number): void {
  if (byteLength > EXTRACTED_FACE_CACHE_BYTES) return;
  const existing = extractedFaceCache.get(key);
  if (existing) {
    extractedFaceCacheBytes -= existing.byteLength;
    extractedFaceCache.delete(key);
  }
  while (
    extractedFaceCache.size >= EXTRACTED_FACE_CACHE_LIMIT ||
    extractedFaceCacheBytes + byteLength > EXTRACTED_FACE_CACHE_BYTES
  ) {
    const oldestKey = extractedFaceCache.keys().next().value as string | undefined;
    if (!oldestKey) break;
    const oldest = extractedFaceCache.get(oldestKey)!;
    extractedFaceCache.delete(oldestKey);
    extractedFaceCacheBytes -= oldest.byteLength;
  }
  extractedFaceCache.set(key, { base64, byteLength });
  extractedFaceCacheBytes += byteLength;
}

/**
 * Return a validated scalar font payload. TTC/OTC inputs are converted to a
 * standalone SFNT for the face whose nameID 6 exactly matches postScriptName.
 */
export function standaloneFontFaceBase64(
  data: string,
  postScriptName: string,
): string | null {
  const compact = compactBase64(data);
  if (!compact) return null;
  const signatureBytes = decodeBase64({
    value: compact.value.slice(0, 8),
    byteLength: Math.min(4, compact.byteLength),
  });
  const signature = signatureBytes && rawSignatureAt(signatureBytes, 0);
  if (signature === "ttcf") {
    if (!validPostScriptName(postScriptName)) return null;
    const fingerprint = fullDataFingerprint(compact.value);
    const key = `${fingerprint}\0${postScriptName}`;
    const cached = cachedFace(key);
    if (cached) return cached;
    const bytes = decodeBase64(compact);
    if (!bytes) return null;
    const faces = parseCollection(bytes);
    if (!faces) return null;
    const matching = faces.filter(
      (face) => facePostScriptName(bytes, face) === postScriptName,
    );
    if (matching.length !== 1) return null;
    const output = extractStandaloneFace(bytes, matching[0]!);
    if (!output) return null;
    const base64 = encodeBase64(output);
    cacheFace(key, base64, output.byteLength);
    return base64;
  }

  const bytes = decodeBase64(compact);
  if (!bytes) return null;
  if (isScalarSfntSignature(signature)) {
    return standaloneSfntIsValid(bytes) ? compact.value : null;
  }
  if (signature === "wOFF") return woffIsValid(bytes) ? compact.value : null;
  if (signature === "wOF2") return woff2IsValid(bytes) ? compact.value : null;
  return null;
}
