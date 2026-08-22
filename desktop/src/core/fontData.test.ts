import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import process from "node:process";

import {
  fontDataFingerprint,
  standaloneFontFaceBase64,
} from "./fontData";
import { createStarterDocument, makeElement } from "../defaults";
import type { MergeContext } from "../types";
import { renderLabelSVG } from "./svg";

interface SyntheticFace {
  postScriptName: string;
  marker: number;
}

function writeTag(view: DataView, offset: number, tag: string): void {
  for (let index = 0; index < 4; index += 1) {
    view.setUint8(offset + index, tag.charCodeAt(index));
  }
}

function align4(value: number): number {
  return Math.ceil(value / 4) * 4;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary);
}

function decoded(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function nameTable(postScriptName: string): Uint8Array {
  const encoded = new Uint8Array(postScriptName.length * 2);
  for (let index = 0; index < postScriptName.length; index += 1) {
    encoded[index * 2 + 1] = postScriptName.charCodeAt(index);
  }
  const bytes = new Uint8Array(18 + encoded.length);
  const view = new DataView(bytes.buffer);
  view.setUint16(0, 0, false);
  view.setUint16(2, 1, false);
  view.setUint16(4, 18, false);
  view.setUint16(6, 3, false);
  view.setUint16(8, 1, false);
  view.setUint16(10, 0x0409, false);
  view.setUint16(12, 6, false);
  view.setUint16(14, encoded.length, false);
  view.setUint16(16, 0, false);
  bytes.set(encoded, 18);
  return bytes;
}

function headTable(seed: number): Uint8Array {
  const bytes = new Uint8Array(54);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x00010000, false);
  view.setUint32(4, seed, false);
  view.setUint32(8, 0x12345678, false);
  view.setUint32(12, 0x5f0f3cf5, false);
  return bytes;
}

function syntheticCollection(faces: readonly SyntheticFace[]): Uint8Array {
  const faceDirectorySize = 12 + 3 * 16;
  const headerSize = 12 + faces.length * 4;
  const faceOffsets = faces.map((_, index) => headerSize + index * faceDirectorySize);
  let cursor = align4(headerSize + faces.length * faceDirectorySize);
  const faceTables = faces.map((face, index) => {
    const tables = [
      { tag: "TEST", bytes: Uint8Array.of(face.marker, index, 0xaa, 0x55) },
      { tag: "head", bytes: headTable(index + 1) },
      { tag: "name", bytes: nameTable(face.postScriptName) },
    ];
    return tables.map((table) => {
      const offset = cursor;
      cursor += align4(table.bytes.length);
      return { ...table, offset };
    });
  });

  const output = new Uint8Array(cursor);
  const view = new DataView(output.buffer);
  writeTag(view, 0, "ttcf");
  view.setUint32(4, 0x00010000, false);
  view.setUint32(8, faces.length, false);
  faceOffsets.forEach((offset, index) => view.setUint32(12 + index * 4, offset, false));

  faceOffsets.forEach((faceOffset, faceIndex) => {
    view.setUint32(faceOffset, 0x00010000, false);
    view.setUint16(faceOffset + 4, 3, false);
    view.setUint16(faceOffset + 6, 32, false);
    view.setUint16(faceOffset + 8, 1, false);
    view.setUint16(faceOffset + 10, 16, false);
    faceTables[faceIndex]!.forEach((table, tableIndex) => {
      const record = faceOffset + 12 + tableIndex * 16;
      writeTag(view, record, table.tag);
      view.setUint32(record + 4, 0, false);
      view.setUint32(record + 8, table.offset, false);
      view.setUint32(record + 12, table.bytes.length, false);
      output.set(table.bytes, table.offset);
    });
  });
  return output;
}

function uint32(bytes: Uint8Array, offset: number): number {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint32(offset, false);
}

function checksum(bytes: Uint8Array): number {
  let sum = 0;
  for (let index = 0; index < align4(bytes.length); index += 4) {
    const word =
      ((bytes[index] ?? 0) << 24) |
      ((bytes[index + 1] ?? 0) << 16) |
      ((bytes[index + 2] ?? 0) << 8) |
      (bytes[index + 3] ?? 0);
    sum = (sum + (word >>> 0)) >>> 0;
  }
  return sum;
}

function standaloneTables(bytes: Uint8Array): Map<string, {
  checksum: number;
  offset: number;
  length: number;
}> {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint16(4, false);
  const tables = new Map<string, { checksum: number; offset: number; length: number }>();
  for (let index = 0; index < count; index += 1) {
    const record = 12 + index * 16;
    const tag = String.fromCharCode(...bytes.subarray(record, record + 4));
    tables.set(tag, {
      checksum: view.getUint32(record + 4, false),
      offset: view.getUint32(record + 8, false),
      length: view.getUint32(record + 12, false),
    });
  }
  return tables;
}

function tableChecksum(
  bytes: Uint8Array,
  table: { offset: number; length: number },
  zeroAdjustment: boolean,
): number {
  const copy = new Uint8Array(align4(table.length));
  copy.set(bytes.subarray(table.offset, table.offset + table.length));
  if (zeroAdjustment) new DataView(copy.buffer).setUint32(8, 0, false);
  return checksum(copy);
}

describe("standalone TTC face extraction", () => {
  it("extracts exact Regular and Bold faces with valid standalone checksums", () => {
    const source = syntheticCollection([
      { postScriptName: "Synthetic-Regular", marker: 0x11 },
      { postScriptName: "Synthetic-Bold", marker: 0x22 },
    ]);
    const encoded = base64(source);

    const regular = standaloneFontFaceBase64(encoded, "Synthetic-Regular");
    const bold = standaloneFontFaceBase64(encoded, "Synthetic-Bold");

    expect(regular).toBeTruthy();
    expect(bold).toBeTruthy();
    expect(regular).not.toBe(bold);
    expect(standaloneFontFaceBase64(encoded, "Synthetic-Regular")).toBe(regular);

    for (const [result, marker] of [[regular!, 0x11], [bold!, 0x22]] as const) {
      const bytes = decoded(result);
      expect(String.fromCharCode(...bytes.subarray(0, 4))).not.toBe("ttcf");
      expect(checksum(bytes)).toBe(0xb1b0afba);
      const tables = standaloneTables(bytes);
      expect([...tables.keys()]).toHaveLength(3);
      expect(new Set(tables.keys()).size).toBe(3);
      for (const table of tables.values()) expect(table.offset % 4).toBe(0);
      expect(bytes[tables.get("TEST")!.offset]).toBe(marker);
      for (const [tag, table] of tables) {
        expect(table.checksum).toBe(tableChecksum(bytes, table, tag === "head"));
      }
    }
  });

  it("requires an exact nameID 6 match", () => {
    const encoded = base64(syntheticCollection([
      { postScriptName: "Synthetic-Regular", marker: 1 },
      { postScriptName: "Synthetic-Bold", marker: 2 },
    ]));

    expect(standaloneFontFaceBase64(encoded, "synthetic-regular")).toBeNull();
    expect(standaloneFontFaceBase64(encoded, "Synthetic-Missing")).toBeNull();
  });

  it("rejects out-of-bounds tables and duplicate tags", () => {
    const source = syntheticCollection([
      { postScriptName: "Synthetic-Regular", marker: 1 },
      { postScriptName: "Synthetic-Bold", marker: 2 },
    ]);
    const invalidBounds = source.slice();
    new DataView(invalidBounds.buffer).setUint32(40, source.length + 4, false);
    expect(
      standaloneFontFaceBase64(base64(invalidBounds), "Synthetic-Regular"),
    ).toBeNull();

    const duplicateTag = source.slice();
    duplicateTag.set(duplicateTag.subarray(32, 36), 48);
    expect(
      standaloneFontFaceBase64(base64(duplicateTag), "Synthetic-Regular"),
    ).toBeNull();
  });

  it("returns validated scalar SFNT data compactly and fingerprints all data", () => {
    const collection = base64(syntheticCollection([
      { postScriptName: "Synthetic-Regular", marker: 1 },
      { postScriptName: "Synthetic-Bold", marker: 2 },
    ]));
    const scalar = standaloneFontFaceBase64(collection, "Synthetic-Regular")!;
    expect(standaloneFontFaceBase64(` \n${scalar}\r\n`, "ignored")).toBe(scalar);

    const first = fontDataFingerprint(collection);
    const same = fontDataFingerprint(`\n${collection}\n`);
    const changedBytes = decoded(collection);
    changedBytes[changedBytes.length - 1] ^= 1;
    const changed = fontDataFingerprint(base64(changedBytes));
    expect(first).toMatch(/^fd1-[a-z0-9]+-[a-f0-9]{32}$/);
    expect(same).toBe(first);
    expect(changed).not.toBe(first);
    expect(fontDataFingerprint("not base64")).toBeNull();
  });

  it("renders separate SVG font faces from one collection", () => {
    const collection = base64(syntheticCollection([
      { postScriptName: "Synthetic-Regular", marker: 0x11 },
      { postScriptName: "Synthetic-Bold", marker: 0x22 },
    ]));
    const regular = makeElement("text");
    regular.fontName = "Synthetic-Regular";
    const bold = makeElement("text");
    bold.fontName = "Synthetic-Bold";
    bold.isBold = true;
    const document = createStarterDocument();
    document.elements = [regular, bold];
    document.embeddedFonts = [
      { postScriptName: "Synthetic-Regular", familyName: "Synthetic", data: collection },
      { postScriptName: "Synthetic-Bold", familyName: "Synthetic", data: collection },
    ];
    const context: MergeContext = {
      row: {},
      rowNumber: 1,
      serialValue: 1,
      pageNumber: 1,
      slotNumber: 1,
      isActive: true,
    };

    const svg = renderLabelSVG(document, context);

    expect(svg.match(/@font-face/g)).toHaveLength(2);
    expect(svg).not.toContain("font/collection");
    expect(svg).not.toContain("format(\"collection\")");
    expect(svg).toContain(standaloneFontFaceBase64(collection, "Synthetic-Regular")!);
    expect(svg).toContain(standaloneFontFaceBase64(collection, "Synthetic-Bold")!);
  });
});

const fixturePath = process.env.ILABEL_TTC_FIXTURE;
const fixturePostScriptName = process.env.ILABEL_TTC_POSTSCRIPT_NAME;

it.skipIf(!fixturePath || !fixturePostScriptName)(
  "extracts an optional real TTC fixture",
  () => {
    const source = readFileSync(fixturePath!);
    const result = standaloneFontFaceBase64(
      source.toString("base64"),
      fixturePostScriptName!,
    );
    expect(result).toBeTruthy();
    expect(String.fromCharCode(...decoded(result!).subarray(0, 4))).not.toBe("ttcf");
  },
);
