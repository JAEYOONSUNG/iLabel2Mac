import type { LabelDocument, LabelElement } from "../types";

const MAX_IMAGE_PIXELS = 100_000_000;

type SupportedImageMIME =
  | "image/png"
  | "image/jpeg"
  | "image/gif"
  | "image/webp"
  | "image/bmp"
  | "image/svg+xml"
  | "image/tiff"
  | "image/heic";

function base64Bytes(value: string): Uint8Array {
  const compact = value.replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(compact)) {
    throw new Error("Image data is not valid base64.");
  }
  const decoded = atob(compact);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function bytesBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function ascii(bytes: Uint8Array, start: number, length: number): string {
  return String.fromCharCode(...bytes.subarray(start, start + length));
}

function sniffImageMIME(bytes: Uint8Array): SupportedImageMIME | undefined {
  if (
    bytes.length >= 8 &&
    [137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte)
  ) return "image/png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (bytes.length >= 6 && /^(?:GIF87a|GIF89a)$/.test(ascii(bytes, 0, 6))) {
    return "image/gif";
  }
  if (
    bytes.length >= 12 &&
    ascii(bytes, 0, 4) === "RIFF" &&
    ascii(bytes, 8, 4) === "WEBP"
  ) return "image/webp";
  if (bytes.length >= 2 && ascii(bytes, 0, 2) === "BM") return "image/bmp";
  if (
    bytes.length >= 4 &&
    ((ascii(bytes, 0, 4) === "II*\0") || (ascii(bytes, 0, 4) === "MM\0*"))
  ) return "image/tiff";
  if (bytes.length >= 12 && ascii(bytes, 4, 4) === "ftyp") {
    const brand = ascii(bytes, 8, 4).toLocaleLowerCase();
    if (["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].includes(brand)) {
      return "image/heic";
    }
  }

  const prefix = new TextDecoder().decode(bytes.subarray(0, Math.min(bytes.length, 4_096)))
    .replace(/^\uFEFF/, "")
    .trimStart();
  if (/^(?:<\?xml[\s\S]*?\?>\s*)?<svg(?:\s|>)/i.test(prefix)) return "image/svg+xml";
  return undefined;
}

function normalizedMIME(mime: string | undefined, bytes: Uint8Array): SupportedImageMIME {
  const supplied = mime?.toLocaleLowerCase().split(";", 1)[0]?.trim();
  const aliases: Record<string, SupportedImageMIME> = {
    "image/jpg": "image/jpeg",
    "image/x-ms-bmp": "image/bmp",
    "image/x-tiff": "image/tiff",
    "image/heif": "image/heic",
  };
  const normalized = aliases[supplied ?? ""] ?? supplied;
  if (
    normalized === "image/png" ||
    normalized === "image/jpeg" ||
    normalized === "image/gif" ||
    normalized === "image/webp" ||
    normalized === "image/bmp" ||
    normalized === "image/svg+xml" ||
    normalized === "image/tiff" ||
    normalized === "image/heic"
  ) return normalized;
  const detected = sniffImageMIME(bytes);
  if (detected) return detected;
  throw new Error("The image format could not be identified.");
}

function imageSource(value: string, suppliedMIME?: string): {
  bytes: Uint8Array;
  mime: SupportedImageMIME;
} {
  const dataURL = /^data:([^;,]+);base64,([A-Za-z0-9+/=\s]+)$/i.exec(value.trim());
  const bytes = base64Bytes(dataURL?.[2] ?? value);
  return {
    bytes,
    mime: normalizedMIME(suppliedMIME ?? dataURL?.[1], bytes),
  };
}

export function sanitizeSVGText(source: string): string {
  const parsed = new DOMParser().parseFromString(source, "image/svg+xml");
  if (
    parsed.querySelector("parsererror") ||
    parsed.documentElement.localName.toLocaleLowerCase() !== "svg"
  ) {
    throw new Error("The SVG file is malformed.");
  }
  const forbidden = "script,foreignObject,iframe,object,embed,audio,video,link";
  if (parsed.querySelector(forbidden)) {
    throw new Error("The SVG contains unsupported active content.");
  }
  for (const element of parsed.querySelectorAll("*")) {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLocaleLowerCase();
      const value = attribute.value.trim();
      if (name.startsWith("on")) {
        throw new Error("The SVG contains event-handler code.");
      }
      if (
        (name === "href" || name === "xlink:href" || name === "src") &&
        value &&
        !value.startsWith("#") &&
        !value.startsWith("data:")
      ) {
        throw new Error("The SVG references an external resource.");
      }
      if (/url\(\s*['"]?(?!#|data:)/i.test(value)) {
        throw new Error("The SVG style references an external resource.");
      }
    }
  }
  return new XMLSerializer().serializeToString(parsed.documentElement);
}

export async function normalizeImportedImage(
  base64: string,
  mime?: string,
): Promise<string> {
  const source = imageSource(base64, mime);
  if (source.mime === "image/svg+xml") {
    const sanitized = sanitizeSVGText(new TextDecoder().decode(source.bytes));
    return bytesBase64(new TextEncoder().encode(sanitized));
  }
  const buffer = source.bytes.buffer.slice(
    source.bytes.byteOffset,
    source.bytes.byteOffset + source.bytes.byteLength,
  ) as ArrayBuffer;
  const blob = new Blob([buffer], { type: source.mime });
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(blob);
  } catch {
    throw new Error(`${source.mime} is not supported on this system. Convert it to PNG, JPEG, WebP, BMP, GIF, or SVG.`);
  }
  try {
    if (
      bitmap.width <= 0 ||
      bitmap.height <= 0 ||
      bitmap.width * bitmap.height > MAX_IMAGE_PIXELS
    ) {
      throw new Error("The image dimensions are too large.");
    }
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Canvas rendering is unavailable.");
    context.drawImage(bitmap, 0, 0);
    return canvas.toDataURL("image/png").split(",", 2)[1]!;
  } finally {
    bitmap.close();
  }
}

function clonedDocument(source: LabelDocument): LabelDocument {
  if (typeof structuredClone === "function") return structuredClone(source);
  return JSON.parse(JSON.stringify(source)) as LabelDocument;
}

/**
 * Normalizes every persisted image in an opened project, including immutable
 * capture snapshots. The source document is never mutated. Unsupported legacy
 * formats fail loudly with the owning element's name instead of rendering an
 * empty label later.
 */
export async function normalizeDocumentImages(
  source: LabelDocument,
): Promise<LabelDocument> {
  const document = clonedDocument(source);
  const normalizedBySource = new Map<string, Promise<string>>();

  const normalizeElement = async (element: LabelElement, location: string): Promise<void> => {
    if (element.type !== "image" || !element.imageData) return;
    try {
      let normalized = normalizedBySource.get(element.imageData);
      if (!normalized) {
        normalized = normalizeImportedImage(element.imageData);
        normalizedBySource.set(element.imageData, normalized);
      }
      element.imageData = await normalized;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      throw new Error(`Image “${element.name}”${location} could not be loaded: ${reason}`);
    }
  };

  for (const element of document.elements) {
    await normalizeElement(element, "");
  }
  for (const batch of document.printQueue ?? []) {
    for (const element of batch.elements) {
      await normalizeElement(element, ` in capture “${batch.name}”`);
    }
  }
  return document;
}
