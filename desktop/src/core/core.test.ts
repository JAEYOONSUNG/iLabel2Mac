import { describe, expect, it } from "vitest";

import {
  DEFAULT_680_SHEET,
  DEFAULT_OFFICIAL_FORMAT_CODE,
  MAX_PRINT_BATCH_QUANTITY,
  createStarterDocument,
  makeElement,
} from "../defaults";
import type {
  LabelDocument,
  OfficialFormatPayload,
  PrintBatch,
  SheetTemplate,
} from "../types";
import officialFormatPayload from "../../../Resources/official_formats.json";
import { CSVParseError, parseCSV } from "./csv";
import {
  DocumentCoreError,
  captureBatch,
  clampDocumentElements,
  clearBatches,
  currentSetupLabelCount,
  draftPlacementPlan,
  firstPlacementConflict,
  freezeLegacyPrintQueuePlacement,
  mergeContext,
  moveBatch,
  normalizeDocument,
  orderedSlotIndices,
  pageCount,
  removeBatch,
  renderPayload,
  selectPlacementStart,
  visiblePreviewSlotIndices,
} from "./document";
import { resolveTokens } from "./merge";

const TWO_BY_TWO_SHEET: SheetTemplate = {
  id: "test-2x2",
  name: "Test 2x2",
  pageWidthMM: 100,
  pageHeightMM: 60,
  columns: 2,
  rows: 2,
  labelWidthMM: 45,
  labelHeightMM: 25,
  horizontalGapMM: 2,
  verticalGapMM: 2,
  marginLeftMM: 3,
  marginTopMM: 3,
  shape: "roundedRectangle",
  cornerRadiusMM: 2,
};

function testDocument(): LabelDocument {
  const document = createStarterDocument();
  document.sheet = { ...TWO_BY_TWO_SHEET };
  document.elements = [makeElement("text", 1)];
  document.elements[0]!.content = "{{serial}}";
  document.serial = {
    mode: "rangedSets",
    start: 1,
    step: 1,
    end: 4,
    repeatSets: 1,
    digits: 2,
    prefix: "(",
    suffix: ")",
  };
  document.placement = { selectedSlotIndices: [], fillDirection: "horizontal" };
  delete document.dataTable;
  delete document.printQueue;
  return document;
}

describe("Swift-compatible defaults and normalization", () => {
  it("creates independent starter documents with the Swift defaults", () => {
    const first = createStarterDocument();
    const second = createStarterDocument();

    expect(first.title).toBe(DEFAULT_OFFICIAL_FORMAT_CODE);
    expect(first.sheet).toEqual(DEFAULT_680_SHEET);
    expect(first.elements).toEqual([]);
    expect(first).toMatchObject({
      formatCode: "680",
      formatFamily: "a4Label",
      formatSourceURL: "https://www.label.kr/Goods/Detail/680",
      formatPDFTemplateURL: "https://images.label.kr/pds/template/680_line.pdf",
    });
    expect(first.serial).toMatchObject({ mode: "rangedSets", start: 1, end: 12 });
    first.sheet.columns = 99;
    expect(second.sheet.columns).toBe(14);
  });

  it("uses the canonical blank 680 document for malformed input", () => {
    for (const input of [null, [], {}, { formatCode: "680" }]) {
      expect(normalizeDocument(input)).toEqual(createStarterDocument());
    }
  });

  it("matches the single official 680 catalog definition", () => {
    const formats = (officialFormatPayload as unknown as OfficialFormatPayload).formats;
    const matches = formats.filter((format) => format.code === DEFAULT_OFFICIAL_FORMAT_CODE);
    expect(matches).toHaveLength(1);
    expect(matches[0]).toMatchObject({
      code: DEFAULT_680_SHEET.id,
      name: DEFAULT_680_SHEET.name,
      pageWidthMM: DEFAULT_680_SHEET.pageWidthMM,
      pageHeightMM: DEFAULT_680_SHEET.pageHeightMM,
      columns: DEFAULT_680_SHEET.columns,
      rows: DEFAULT_680_SHEET.rows,
      labelWidthMM: DEFAULT_680_SHEET.labelWidthMM,
      labelHeightMM: DEFAULT_680_SHEET.labelHeightMM,
      horizontalGapMM: DEFAULT_680_SHEET.horizontalGapMM,
      verticalGapMM: DEFAULT_680_SHEET.verticalGapMM,
      marginLeftMM: DEFAULT_680_SHEET.marginLeftMM,
      marginTopMM: DEFAULT_680_SHEET.marginTopMM,
      shape: DEFAULT_680_SHEET.shape,
      cornerRadiusMM: DEFAULT_680_SHEET.cornerRadiusMM,
    });
  });

  it("accepts old JSON with omitted optional fields and clamps batch quantities", () => {
    const source = testDocument();
    const legacyBatch = {
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      name: "Legacy",
      quantity: 0,
      elements: source.elements,
    };
    const raw = JSON.parse(JSON.stringify({ ...source, printQueue: [legacyBatch] })) as unknown;
    const normalized = normalizeDocument(raw);

    expect(normalized.printQueue?.[0]).toMatchObject({
      id: legacyBatch.id,
      quantity: 1,
    });
    expect(normalized.printQueue?.[0]?.capturedPlacement).toBeUndefined();
    expect(normalized.embeddedFonts).toBeUndefined();
  });

  it("preserves Swift Data fields as base64 strings", () => {
    const source = createStarterDocument();
    const image = makeElement("image", 1);
    const text = makeElement("text", 1);
    image.imageData = "iVBORw0KGgo=";
    text.richTextRTF = "e1xydGYxIHRlc3R9";
    source.elements = [image, text];
    source.embeddedFonts = [
      { postScriptName: "Example-Regular", familyName: "Example", data: "AAEAAA==" },
    ];

    const normalized = normalizeDocument(JSON.parse(JSON.stringify(source)));
    expect(normalized.elements[0]!.imageData).toBe("iVBORw0KGgo=");
    expect(normalized.elements[1]!.richTextRTF).toBe("e1xydGYxIHRlc3R9");
    expect(normalized.embeddedFonts?.[0]?.data).toBe("AAEAAA==");
  });

  it("migrates legacy circular text to the full ellipse and clamps queue snapshots", () => {
    const source = testDocument();
    source.formatCode = "680";
    source.sheet = {
      ...source.sheet,
      shape: "circle",
      labelWidthMM: 12,
      labelHeightMM: 12,
    };
    const text = source.elements[0]!;
    delete text.usesCircularTextFlow;
    text.frame = {
      x: (12 - 12 / Math.sqrt(2)) / 2,
      y: (12 - 12 / Math.sqrt(2)) / 2,
      width: 12 / Math.sqrt(2),
      height: 12 / Math.sqrt(2),
    };
    source.printQueue = [
      {
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        name: "Old circle",
        quantity: 1,
        elements: [{ ...text, frame: { ...text.frame } }],
      },
    ];

    const normalized = normalizeDocument(JSON.parse(JSON.stringify(source)));
    expect(normalized.elements[0]!.frame).toEqual({ x: 0, y: 0, width: 12, height: 12 });
    expect(normalized.elements[0]!.usesCircularTextFlow).toBe(true);
    expect(normalized.printQueue?.[0]?.elements[0]?.frame).toEqual({
      x: 0,
      y: 0,
      width: 12,
      height: 12,
    });
  });
});

describe("CSV and token merge", () => {
  it("detects delimiters, quoted fields, escaped quotes, and blank headers", () => {
    const table = parseCSV('Name;Note;\nAlice;"one; two";x\nBob;"said ""hi""";y');
    expect(table.headers).toEqual(["Name", "Note", "Column3"]);
    expect(table.rows).toEqual([
      { Name: "Alice", Note: "one; two", Column3: "x" },
      { Name: "Bob", Note: 'said "hi"', Column3: "y" },
    ]);
  });

  it("supports multiline fields and ignores wholly empty rows", () => {
    const table = parseCSV('Name,Address\nAlice,"Line 1\nLine 2"\n,\nBob,Seoul');
    expect(table.rows).toEqual([
      { Name: "Alice", Address: "Line 1\nLine 2" },
      { Name: "Bob", Address: "Seoul" },
    ]);
  });

  it("rejects empty input with a typed error", () => {
    expect(() => parseCSV(" \n ")).toThrow(CSVParseError);
  });

  it("resolves built-in and case-insensitive CSV tokens deterministically", () => {
    const settings = testDocument().serial;
    const value = resolveTokens(
      "{{ Name }} {{serial}} {{serial_raw}} p{{page}}/s{{slot}} r{{row}} {{date}} {{time}} {{missing}}",
      {
        row: { NAME: "Sample" },
        serialValue: 7,
        rowNumber: 3,
        pageNumber: 2,
        slotNumber: 4,
        isActive: true,
      },
      settings,
      new Date(2026, 7, 22, 9, 5),
    );
    expect(value).toBe("Sample (07) 7 p2/s4 r3 2026.08.22 09:05 ");
  });
});

describe("slot ordering and merge mapping", () => {
  it("orders a vertical selection by column then row", () => {
    const document = testDocument();
    document.placement = {
      selectedSlotIndices: [3, 0, 2, 1, 1, 999],
      fillDirection: "vertical",
    };
    expect(orderedSlotIndices(document)).toEqual([0, 2, 1, 3]);
  });

  it("uses CSV count before serial count and computes pages", () => {
    const document = testDocument();
    document.dataTable = {
      headers: ["Name"],
      rows: Array.from({ length: 5 }, (_, index) => ({ Name: `Row ${index + 1}` })),
    };
    expect(currentSetupLabelCount(document)).toBe(5);
    expect(pageCount(document)).toBe(2);
    expect(visiblePreviewSlotIndices(document, 1)).toEqual([0]);
    expect(mergeContext(document, 0, 1)).toMatchObject({
      row: { Name: "Row 5" },
      rowNumber: 5,
      pageNumber: 2,
      slotNumber: 1,
      isActive: true,
    });
  });

  it("maps ranged sets and stops after their finite count", () => {
    const document = testDocument();
    document.serial = {
      ...document.serial,
      start: 4,
      step: 2,
      end: 8,
      repeatSets: 2,
    };
    expect(currentSetupLabelCount(document)).toBe(6);
    expect([0, 1, 2, 3, 4, 5].map((index) => mergeContext(document, index % 4, Math.floor(index / 4)).serialValue)).toEqual([
      4,
      6,
      8,
      4,
      6,
      8,
    ]);
    expect(mergeContext(document, 2, 1).isActive).toBe(false);
  });
});

describe("capture queue and fixed placement", () => {
  it("captures immutable artwork and independent numbering snapshots", () => {
    let document = testDocument();
    document.serial.end = 2;
    document.elements[0]!.content = "FIRST {{serial}}";
    document = captureBatch(document, 0, {
      id: "11111111-1111-4111-8111-111111111111",
    });

    document.elements[0]!.content = "SECOND {{serial}}";
    document.serial = { ...document.serial, start: 10, end: 12 };
    document = selectPlacementStart(document, 2, 0);
    document = captureBatch(document, 0, {
      id: "22222222-2222-4222-8222-222222222222",
    });

    expect(document.printQueue?.map((batch) => batch.quantity)).toEqual([2, 3]);
    expect(renderPayload(document, 0, 0)).toMatchObject({
      batchID: "11111111-1111-4111-8111-111111111111",
      context: { serialValue: 1 },
    });
    expect(renderPayload(document, 2, 0)).toMatchObject({
      batchID: "22222222-2222-4222-8222-222222222222",
      context: { serialValue: 10 },
    });
    expect(renderPayload(document, 2, 1).context.serialValue).toBe(12);
    expect(document.printQueue?.[0]?.elements[0]?.content).toBe("FIRST {{serial}}");
    expect(pageCount(document)).toBe(2);
  });

  it("reports overlap and allows the same physical slots on a later page", () => {
    let document = testDocument();
    document = captureBatch(document, 0, {
      id: "33333333-3333-4333-8333-333333333333",
    });
    const overlapping = draftPlacementPlan(document, 0);
    expect(firstPlacementConflict(document, overlapping)).toMatchObject({
      pageIndex: 0,
      slotIndex: 0,
    });
    expect(firstPlacementConflict(document, draftPlacementPlan(document, 1))).toBeNull();
    expect(() => selectPlacementStart(document, 0, 0)).toThrowError(
      expect.objectContaining({ code: "capturedSlot" }),
    );
    expect(selectPlacementStart(document, 0, 1).placement.selectedSlotIndices).toEqual([
      0,
      1,
      2,
      3,
    ]);
    expect(() =>
      captureBatch(document, 0, {
        id: "44444444-4444-4444-8444-444444444444",
      }),
    ).toThrow(DocumentCoreError);
  });

  it("freezes legacy batches at their original continuous offsets", () => {
    const document = testDocument();
    document.printQueue = [
      {
        id: "55555555-5555-4555-8555-555555555555",
        name: "First",
        quantity: 3,
        elements: [{ ...document.elements[0]!, content: "FIRST" }],
      },
      {
        id: "66666666-6666-4666-8666-666666666666",
        name: "Second",
        quantity: 3,
        elements: [{ ...document.elements[0]!, content: "SECOND" }],
      },
    ];

    const frozen = freezeLegacyPrintQueuePlacement(document);
    expect(frozen.printQueue?.[0]).toMatchObject({
      startPageIndex: 0,
      startSlotOffset: 0,
      legacySequenceOffset: 0,
    });
    expect(frozen.printQueue?.[1]).toMatchObject({
      startPageIndex: 0,
      startSlotOffset: 3,
      legacySequenceOffset: 3,
    });
    expect(renderPayload(frozen, 3, 0).batchID).toBe(
      "66666666-6666-4666-8666-666666666666",
    );
    expect(renderPayload(frozen, 0, 1).context.rowNumber).toBe(5);
  });

  it("supports immutable remove, reorder, and clear operations", () => {
    const document = testDocument();
    const batches: PrintBatch[] = [
      {
        id: "77777777-7777-4777-8777-777777777777",
        name: "One",
        quantity: 1,
        elements: document.elements,
      },
      {
        id: "88888888-8888-4888-8888-888888888888",
        name: "Two",
        quantity: 1,
        elements: document.elements,
      },
    ];
    document.printQueue = batches;

    const moved = moveBatch(document, batches[0]!.id, 1);
    expect(moved.printQueue?.map((batch) => batch.name)).toEqual(["Two", "One"]);
    expect(document.printQueue?.map((batch) => batch.name)).toEqual(["One", "Two"]);
    const removed = removeBatch(moved, batches[1]!.id);
    expect(removed.printQueue?.map((batch) => batch.name)).toEqual(["One"]);
    expect(clearBatches(removed).printQueue).toBeUndefined();
  });

  it("enforces the total 100,000-label queue limit", () => {
    const document = testDocument();
    document.printQueue = [
      {
        id: "99999999-9999-4999-8999-999999999999",
        name: "Huge",
        quantity: MAX_PRINT_BATCH_QUANTITY,
        elements: document.elements,
      },
    ];
    expect(() => captureBatch(document, 1)).toThrowError(
      expect.objectContaining({ code: "queueLimit" }),
    );
  });
});

describe("element bounds", () => {
  it("clamps ordinary elements and preserves full circular-flow text", () => {
    const document = testDocument();
    document.sheet = { ...document.sheet, shape: "circle", labelWidthMM: 20, labelHeightMM: 20 };
    document.elements = [
      { ...makeElement("rectangle", 1), frame: { x: -4, y: 40, width: 100, height: 1 } },
      {
        ...makeElement("text", 1),
        frame: { x: 3, y: 3, width: 8, height: 8 },
        usesCircularTextFlow: true,
      },
    ];
    const clamped = clampDocumentElements(document);
    expect(clamped.elements[0]!.frame).toEqual({ x: 0, y: 15, width: 20, height: 5 });
    expect(clamped.elements[1]!.frame).toEqual({ x: 0, y: 0, width: 20, height: 20 });
  });
});
