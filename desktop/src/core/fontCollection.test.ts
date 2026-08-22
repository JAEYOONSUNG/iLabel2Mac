import { describe, expect, it } from "vitest";

import { createStarterDocument, makeElement } from "../defaults";
import { documentWithCollectedFonts, requiredFontFaces, type LocalFontDataLike } from "./fontCollection";
import { serializeBase64RTF } from "./rtf";

function font(
  postscriptName: string,
  family: string,
  style: string,
  bytes: readonly number[] | Uint8Array,
): LocalFontDataLike {
  const data = Uint8Array.from(bytes);
  return {
    postscriptName,
    family,
    fullName: `${family} ${style}`,
    style,
    blob: async () => new Blob([data.buffer as ArrayBuffer]),
  };
}

function writeTag(view: DataView, offset: number, tag: string): void {
  for (let index = 0; index < 4; index += 1) {
    view.setUint8(offset + index, tag.charCodeAt(index));
  }
}

function sfntFont(
  fsType: number,
  marker = 0,
  tableTag = "OS/2",
): Uint8Array {
  const tableOffset = 28;
  const tableLength = 12;
  const bytes = new Uint8Array(tableOffset + tableLength);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x00010000, false);
  view.setUint16(4, 1, false);
  writeTag(view, 12, tableTag);
  view.setUint32(20, tableOffset, false);
  view.setUint32(24, tableLength, false);
  view.setUint16(tableOffset + 2, marker, false);
  view.setUint16(tableOffset + 8, fsType, false);
  return bytes;
}

function woffFont(fsType: number): Uint8Array {
  const tableOffset = 64;
  const tableLength = 12;
  const bytes = new Uint8Array(tableOffset + tableLength);
  const view = new DataView(bytes.buffer);
  writeTag(view, 0, "wOFF");
  view.setUint32(4, 0x00010000, false);
  view.setUint32(8, bytes.byteLength, false);
  view.setUint16(12, 1, false);
  view.setUint32(16, 40, false);
  writeTag(view, 44, "OS/2");
  view.setUint32(48, tableOffset, false);
  view.setUint32(52, tableLength, false);
  view.setUint32(56, tableLength, false);
  view.setUint16(tableOffset + 8, fsType, false);
  return bytes;
}

async function compressedWoffFont(fsType: number): Promise<Uint8Array> {
  const table = new Uint8Array(100);
  new DataView(table.buffer).setUint16(8, fsType, false);
  const compressedBuffer = await new Response(
    new Blob([table.buffer as ArrayBuffer])
      .stream()
      .pipeThrough(new CompressionStream("deflate")),
  ).arrayBuffer();
  const compressed = new Uint8Array(compressedBuffer);
  const tableOffset = 64;
  const paddedLength = (compressed.byteLength + 3) & ~3;
  const bytes = new Uint8Array(tableOffset + paddedLength);
  const view = new DataView(bytes.buffer);
  writeTag(view, 0, "wOFF");
  view.setUint32(4, 0x00010000, false);
  view.setUint32(8, bytes.byteLength, false);
  view.setUint16(12, 1, false);
  view.setUint32(16, 128, false);
  writeTag(view, 44, "OS/2");
  view.setUint32(48, tableOffset, false);
  view.setUint32(52, compressed.byteLength, false);
  view.setUint32(56, table.byteLength, false);
  bytes.set(compressed, tableOffset);
  return bytes;
}

function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

describe("cross-platform font collection", () => {
  it("collects the exact regular and rich-text faces used by the document", async () => {
    const document = createStarterDocument();
    const text = makeElement("text");
    text.content = "Regular Bold";
    text.fontName = "Example Family";
    text.richTextRTF = serializeBase64RTF(text.content, [
      { start: 0, length: 8, fontName: "Example Family", fontSize: 12 },
      { start: 8, length: 4, fontName: "Example-Bold", fontSize: 12, bold: true },
    ]);
    document.elements = [text];
    const regularBytes = sfntFont(0, 1);
    const boldBytes = sfntFont(0x0108, 2);
    const localFonts = [
      font("Example-Regular", "Example Family", "Regular", regularBytes),
      font("Example-Bold", "Example Family", "Bold", boldBytes),
    ];

    expect(requiredFontFaces(document)).toEqual(expect.arrayContaining([
      { name: "Example Family", bold: false, italic: false },
      { name: "Example-Bold", bold: true, italic: false },
    ]));
    const result = await documentWithCollectedFonts(document, localFonts);
    expect(result.embeddedFonts).toEqual(expect.arrayContaining([
      { postScriptName: "Example-Regular", familyName: "Example Family", data: base64(regularBytes) },
      { postScriptName: "Example-Bold", familyName: "Example Family", data: base64(boldBytes) },
    ]));
    expect(document.embeddedFonts).toBeUndefined();
  });

  it("preserves existing embedded data and skips protected faces", async () => {
    const document = createStarterDocument();
    document.elements[1]!.fontName = "Protected";
    document.embeddedFonts = [
      {
        postScriptName: "Existing-Restricted",
        familyName: "Existing Restricted",
        data: base64(sfntFont(0x0002)),
      },
      { postScriptName: "Existing-Invalid", familyName: "Existing Invalid", data: "AAECAw==" },
    ];
    const protectedFont: LocalFontDataLike = {
      postscriptName: "Protected",
      family: "Protected",
      fullName: "Protected",
      style: "Regular",
      blob: async () => { throw new Error("denied"); },
    };
    const result = await documentWithCollectedFonts(document, [protectedFont]);
    expect(result.embeddedFonts).toEqual(document.embeddedFonts);
  });

  it("blocks Restricted and Preview & Print faces from editable project data", async () => {
    const document = createStarterDocument();
    const restricted = makeElement("text");
    restricted.fontName = "Restricted Family";
    const preview = makeElement("text");
    preview.fontName = "Preview Family";
    document.elements = [restricted, preview];

    const result = await documentWithCollectedFonts(document, [
      font("Restricted-Regular", "Restricted Family", "Regular", sfntFont(0x0002)),
      font("Preview-Regular", "Preview Family", "Regular", sfntFont(0x0004)),
    ]);

    expect(result.embeddedFonts).toBeUndefined();
  });

  it("accepts compressed WOFF only when its OS/2 license allows editing", async () => {
    const document = createStarterDocument();
    const allowed = makeElement("text");
    allowed.fontName = "WOFF Editable";
    const blocked = makeElement("text");
    blocked.fontName = "WOFF Preview";
    document.elements = [allowed, blocked];
    const allowedBytes = await compressedWoffFont(0x0008);

    const result = await documentWithCollectedFonts(document, [
      font("WOFF-Editable", "WOFF Editable", "Regular", allowedBytes),
      font("WOFF-Preview", "WOFF Preview", "Regular", woffFont(0x0004)),
    ]);

    expect(result.embeddedFonts).toEqual([
      {
        postScriptName: "WOFF-Editable",
        familyName: "WOFF Editable",
        data: base64(allowedBytes),
      },
    ]);
  });

  it("rejects missing OS/2 tables, font collections, WOFF2, and invalid flags", async () => {
    const names = ["Missing Table", "Collection", "Web2", "Bitmap Only", "Reserved"];
    const document = createStarterDocument();
    document.elements = names.map((name) => {
      const text = makeElement("text");
      text.fontName = name;
      return text;
    });

    const result = await documentWithCollectedFonts(document, [
      font("Missing-Table", names[0]!, "Regular", sfntFont(0, 0, "name")),
      font("Collection-Face", names[1]!, "Regular", [0x74, 0x74, 0x63, 0x66]),
      font("Web2-Face", names[2]!, "Regular", [0x77, 0x4f, 0x46, 0x32]),
      font("Bitmap-Only", names[3]!, "Regular", sfntFont(0x0200)),
      font("Reserved-Mode", names[4]!, "Regular", sfntFont(0x0001)),
    ]);

    expect(result.embeddedFonts).toBeUndefined();
  });
});
