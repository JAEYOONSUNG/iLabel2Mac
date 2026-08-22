import type { LabelDocument } from "../types";
import { elementRichText } from "./richText";

export interface LocalFontDataLike {
  readonly family: string;
  readonly fullName: string;
  readonly postscriptName: string;
  readonly style: string;
  blob(): Promise<Blob>;
}

function fontTraits(value: string): { bold: boolean; italic: boolean } {
  return {
    bold: /(?:bold|semibold|demibold|black|heavy)/i.test(value),
    italic: /(?:italic|oblique)/i.test(value),
  };
}

function bytesBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

const SFNT_HEADER_BYTES = 12;
const SFNT_TABLE_RECORD_BYTES = 16;
const WOFF_HEADER_BYTES = 44;
const WOFF_TABLE_RECORD_BYTES = 20;
const MAX_FONT_TABLES = 4_096;
const MAX_OS2_TABLE_BYTES = 16 * 1024;

function tagAt(view: DataView, offset: number): string {
  return String.fromCharCode(
    view.getUint8(offset),
    view.getUint8(offset + 1),
    view.getUint8(offset + 2),
    view.getUint8(offset + 3),
  );
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

function embeddingPermissionAllowsRawProjectData(fsType: number): boolean {
  const embeddingLevel = fsType & 0x000f;
  const knownFlags = 0x000f | 0x0100 | 0x0200;
  if ((fsType & ~knownFlags) !== 0) return false;
  // Bitmap-only embedding cannot authorize bundling the outline font program.
  if ((fsType & 0x0200) !== 0) return false;
  // A project is editable and carries the complete, extractable font bytes.
  // Preview & Print and Restricted licenses therefore cannot be used here.
  return embeddingLevel === 0 || embeddingLevel === 0x0008;
}

function sfntFSType(bytes: ArrayBuffer): number | undefined {
  if (bytes.byteLength < SFNT_HEADER_BYTES) return undefined;
  const view = new DataView(bytes);
  const signature = tagAt(view, 0);
  if (
    signature !== "\u0000\u0001\u0000\u0000" &&
    signature !== "OTTO" &&
    signature !== "true"
  ) {
    return undefined;
  }
  const tableCount = view.getUint16(4, false);
  if (tableCount === 0 || tableCount > MAX_FONT_TABLES) return undefined;
  const directoryLength = tableCount * SFNT_TABLE_RECORD_BYTES;
  if (!rangeIsInside(bytes.byteLength, SFNT_HEADER_BYTES, directoryLength)) {
    return undefined;
  }
  const dataStart = SFNT_HEADER_BYTES + directoryLength;
  const seenTags = new Set<string>();
  let fsType: number | undefined;
  for (let index = 0; index < tableCount; index += 1) {
    const record = SFNT_HEADER_BYTES + index * SFNT_TABLE_RECORD_BYTES;
    const tag = tagAt(view, record);
    if (seenTags.has(tag)) return undefined;
    seenTags.add(tag);
    const offset = view.getUint32(record + 8, false);
    const length = view.getUint32(record + 12, false);
    if (
      offset < dataStart ||
      offset % 4 !== 0 ||
      !rangeIsInside(bytes.byteLength, offset, length)
    ) {
      return undefined;
    }
    if (tag === "OS/2") {
      if (length < 10 || length > MAX_OS2_TABLE_BYTES) return undefined;
      fsType = view.getUint16(offset + 8, false);
    }
  }
  return fsType;
}

async function inflateWoffTable(
  bytes: ArrayBuffer,
  offset: number,
  compressedLength: number,
  originalLength: number,
): Promise<ArrayBuffer | undefined> {
  if (compressedLength === originalLength) {
    return bytes.slice(offset, offset + originalLength);
  }
  if (typeof DecompressionStream !== "function") return undefined;
  try {
    const compressed = bytes.slice(offset, offset + compressedLength);
    const stream = new Blob([compressed])
      .stream()
      .pipeThrough(new DecompressionStream("deflate"));
    const inflated = await new Response(stream).arrayBuffer();
    return inflated.byteLength === originalLength ? inflated : undefined;
  } catch {
    return undefined;
  }
}

async function woffFSType(bytes: ArrayBuffer): Promise<number | undefined> {
  if (bytes.byteLength < WOFF_HEADER_BYTES) return undefined;
  const view = new DataView(bytes);
  if (tagAt(view, 0) !== "wOFF") return undefined;
  const flavor = tagAt(view, 4);
  if (
    flavor !== "\u0000\u0001\u0000\u0000" &&
    flavor !== "OTTO" &&
    flavor !== "true"
  ) {
    return undefined;
  }
  if (view.getUint32(8, false) !== bytes.byteLength) return undefined;
  const tableCount = view.getUint16(12, false);
  if (
    tableCount === 0 ||
    tableCount > MAX_FONT_TABLES ||
    view.getUint16(14, false) !== 0
  ) {
    return undefined;
  }
  const directoryLength = tableCount * WOFF_TABLE_RECORD_BYTES;
  if (!rangeIsInside(bytes.byteLength, WOFF_HEADER_BYTES, directoryLength)) {
    return undefined;
  }
  const dataStart = WOFF_HEADER_BYTES + directoryLength;
  const seenTags = new Set<string>();
  let reconstructedSize = SFNT_HEADER_BYTES + tableCount * SFNT_TABLE_RECORD_BYTES;
  let os2Record:
    | { offset: number; compressedLength: number; originalLength: number }
    | undefined;
  for (let index = 0; index < tableCount; index += 1) {
    const record = WOFF_HEADER_BYTES + index * WOFF_TABLE_RECORD_BYTES;
    const tag = tagAt(view, record);
    if (seenTags.has(tag)) return undefined;
    seenTags.add(tag);
    const offset = view.getUint32(record + 4, false);
    const compressedLength = view.getUint32(record + 8, false);
    const originalLength = view.getUint32(record + 12, false);
    if (
      compressedLength === 0 ||
      originalLength === 0 ||
      compressedLength > originalLength ||
      offset < dataStart ||
      offset % 4 !== 0 ||
      !rangeIsInside(bytes.byteLength, offset, compressedLength)
    ) {
      return undefined;
    }
    reconstructedSize += Math.ceil(originalLength / 4) * 4;
    if (tag === "OS/2") {
      if (originalLength < 10 || originalLength > MAX_OS2_TABLE_BYTES) {
        return undefined;
      }
      os2Record = { offset, compressedLength, originalLength };
    }
  }
  if (view.getUint32(16, false) !== reconstructedSize) return undefined;
  if (!os2Record) return undefined;
  const os2 = await inflateWoffTable(
    bytes,
    os2Record.offset,
    os2Record.compressedLength,
    os2Record.originalLength,
  );
  return os2 ? new DataView(os2).getUint16(8, false) : undefined;
}

async function fontAllowsRawProjectEmbedding(bytes: ArrayBuffer): Promise<boolean> {
  if (bytes.byteLength < 4) return false;
  const signature = tagAt(new DataView(bytes), 0);
  const fsType = signature === "wOFF"
    ? await woffFSType(bytes)
    : sfntFSType(bytes);
  return fsType !== undefined && embeddingPermissionAllowsRawProjectData(fsType);
}

interface RequiredFontFace {
  name: string;
  bold: boolean;
  italic: boolean;
}

export function requiredFontFaces(document: LabelDocument): RequiredFontFace[] {
  const faces = new Map<string, RequiredFontFace>();
  const elements = [
    ...document.elements,
    ...(document.printQueue ?? []).flatMap((batch) => batch.elements),
  ];
  const add = (name: string | undefined, bold: boolean, italic: boolean) => {
    const trimmed = name?.trim();
    if (!trimmed) return;
    faces.set(`${trimmed.toLocaleLowerCase()}|${bold}|${italic}`, {
      name: trimmed,
      bold,
      italic,
    });
  };
  for (const element of elements) {
    if (element.type !== "text") continue;
    add(element.fontName, element.isBold, element.isItalic);
    for (const run of elementRichText(element).runs) {
      add(
        run.fontName,
        run.bold ?? element.isBold,
        run.italic ?? element.isItalic,
      );
    }
  }
  return [...faces.values()];
}

export async function documentWithCollectedFonts(
  source: LabelDocument,
  localFonts: readonly LocalFontDataLike[],
): Promise<LabelDocument> {
  const document = structuredClone(source);
  const embedded = [...(document.embeddedFonts ?? [])];
  const embeddedNames = new Set<string>();
  for (const font of embedded) {
    const traits = fontTraits(font.postScriptName);
    embeddedNames.add(font.postScriptName.toLocaleLowerCase());
    embeddedNames.add(`${font.familyName.toLocaleLowerCase()}|${traits.bold}|${traits.italic}`);
  }
  let totalBytes = embedded.reduce(
    (total, font) => total + Math.floor((font.data.length * 3) / 4),
    0,
  );
  requiredFaces: for (const required of requiredFontFaces(document)) {
    if (embedded.length >= 64) break;
    if (
      embeddedNames.has(required.name.toLocaleLowerCase()) ||
      embeddedNames.has(`${required.name.toLocaleLowerCase()}|${required.bold}|${required.italic}`)
    ) continue;
    const candidates = localFonts
      .filter((font) =>
        [font.family, font.fullName, font.postscriptName]
          .some((name) => name.toLocaleLowerCase() === required.name.toLocaleLowerCase()))
      .sort((left, right) => {
        const leftTraits = fontTraits(`${left.style} ${left.postscriptName}`);
        const rightTraits = fontTraits(`${right.style} ${right.postscriptName}`);
        const leftScore = Number(leftTraits.bold === required.bold) + Number(leftTraits.italic === required.italic);
        const rightScore = Number(rightTraits.bold === required.bold) + Number(rightTraits.italic === required.italic);
        return rightScore - leftScore;
      });
    for (const match of candidates) {
      try {
        const blob = await match.blob();
        if (blob.size <= 0 || blob.size > 32 * 1024 * 1024) continue;
        if (totalBytes + blob.size > 64 * 1024 * 1024) continue;
        const bytes = await blob.arrayBuffer();
        if (bytes.byteLength !== blob.size || bytes.byteLength > 32 * 1024 * 1024) {
          continue;
        }
        if (!(await fontAllowsRawProjectEmbedding(bytes))) continue;
        const data = bytesBase64(new Uint8Array(bytes));
        embedded.push({
          postScriptName: match.postscriptName,
          familyName: match.family,
          data,
        });
        totalBytes += blob.size;
        embeddedNames.add(match.postscriptName.toLocaleLowerCase());
        embeddedNames.add(`${match.family.toLocaleLowerCase()}|${required.bold}|${required.italic}`);
        continue requiredFaces;
      } catch {
        // Protected fonts may refuse blob access. Missing-font UI handles them.
      }
    }
  }
  document.embeddedFonts = embedded.length > 0 ? embedded : undefined;
  return document;
}
