import {
  COLORS,
  DEFAULT_PLACEMENT,
  DEFAULT_PRINT_AUTOMATION,
  DEFAULT_SERIAL_SETTINGS,
  MAX_PRINT_BATCH_QUANTITY,
  createStarterDocument,
  createUUID,
  makeElement,
} from "../defaults";
import type {
  DataTable,
  DraftPlacementPlan,
  ElementType,
  EmbeddedFont,
  InteractiveSlotRenderPayload,
  LabelDocument,
  LabelElement,
  LabelShape,
  MergeContext,
  OfficialFormatDefinition,
  PlacementFillDirection,
  PlacementSettings,
  PrintAutomationSettings,
  PrintBatch,
  PrintPlacementConflict,
  ProductFamily,
  RectMM,
  RGBAColor,
  SerialMode,
  SerialSettings,
  SheetTemplate,
  SlotRenderPayload,
  TextAlignModel,
} from "../types";
import {
  generatedSerialValue,
  serialCountPerSet,
  serialTotalGeneratedCount,
} from "./merge";

const MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ELEMENT_TYPES = ["text", "rectangle", "image", "qrCode", "code128"] as const;
const LABEL_SHAPES = ["roundedRectangle", "rectangle", "capsule", "circle"] as const;
const TEXT_ALIGNMENTS = ["leading", "center", "trailing"] as const;
const SERIAL_MODES = ["continuous", "rangedSets"] as const;
const FILL_DIRECTIONS = ["horizontal", "vertical"] as const;
const PRODUCT_FAMILIES = [
  "a4Label",
  "a3Label",
  "zLabel",
  "rollLabel",
  "a4Tag",
  "zTag",
  "rollTag",
] as const;

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function integer(value: unknown, fallback: number): number {
  return Math.trunc(finiteNumber(value, fallback));
}

function safeNonnegativeInteger(value: unknown, fallback = 0): number {
  return Math.min(MAX_SAFE_INTEGER, Math.max(0, integer(value, fallback)));
}

function stringValue(value: unknown, fallback: string): string {
  return typeof value === "string" ? value : fallback;
}

function booleanValue(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function enumValue<T extends string>(
  value: unknown,
  values: readonly T[],
  fallback: T,
): T {
  return typeof value === "string" && values.includes(value as T) ? (value as T) : fallback;
}

function normalizedUUID(value: unknown): string {
  return typeof value === "string" && UUID_PATTERN.test(value) ? value : createUUID();
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}

function saturatingAdd(left: number, right: number): number {
  const sum = left + right;
  return Number.isSafeInteger(sum) && sum <= MAX_SAFE_INTEGER ? sum : MAX_SAFE_INTEGER;
}

function saturatingMultiply(left: number, right: number): number {
  const product = left * right;
  return Number.isSafeInteger(product) && product <= MAX_SAFE_INTEGER
    ? product
    : MAX_SAFE_INTEGER;
}

function normalizeColor(value: unknown, fallback: RGBAColor): RGBAColor {
  if (!isRecord(value)) return { ...fallback };
  return {
    red: clamp(finiteNumber(value.red, fallback.red), 0, 1),
    green: clamp(finiteNumber(value.green, fallback.green), 0, 1),
    blue: clamp(finiteNumber(value.blue, fallback.blue), 0, 1),
    alpha: clamp(finiteNumber(value.alpha, fallback.alpha), 0, 1),
  };
}

function normalizeRect(value: unknown, fallback: RectMM): RectMM {
  if (!isRecord(value)) return { ...fallback };
  return {
    x: finiteNumber(value.x, fallback.x),
    y: finiteNumber(value.y, fallback.y),
    width: finiteNumber(value.width, fallback.width),
    height: finiteNumber(value.height, fallback.height),
  };
}

function normalizeSheet(value: unknown, fallback: SheetTemplate): SheetTemplate {
  if (!isRecord(value)) return { ...fallback };
  return {
    id: stringValue(value.id, fallback.id),
    name: stringValue(value.name, fallback.name),
    pageWidthMM: Math.max(1, finiteNumber(value.pageWidthMM, fallback.pageWidthMM)),
    pageHeightMM: Math.max(1, finiteNumber(value.pageHeightMM, fallback.pageHeightMM)),
    columns: Math.max(1, integer(value.columns, fallback.columns)),
    rows: Math.max(1, integer(value.rows, fallback.rows)),
    labelWidthMM: Math.max(1, finiteNumber(value.labelWidthMM, fallback.labelWidthMM)),
    labelHeightMM: Math.max(1, finiteNumber(value.labelHeightMM, fallback.labelHeightMM)),
    horizontalGapMM: finiteNumber(value.horizontalGapMM, fallback.horizontalGapMM),
    verticalGapMM: finiteNumber(value.verticalGapMM, fallback.verticalGapMM),
    marginLeftMM: finiteNumber(value.marginLeftMM, fallback.marginLeftMM),
    marginTopMM: finiteNumber(value.marginTopMM, fallback.marginTopMM),
    shape: enumValue<LabelShape>(value.shape, LABEL_SHAPES, fallback.shape),
    cornerRadiusMM: Math.max(0, finiteNumber(value.cornerRadiusMM, fallback.cornerRadiusMM)),
  };
}

function normalizeSerial(value: unknown, fallback: SerialSettings): SerialSettings {
  if (!isRecord(value)) return { ...fallback };
  return {
    mode: enumValue<SerialMode>(value.mode, SERIAL_MODES, fallback.mode),
    start: integer(value.start, fallback.start),
    step: integer(value.step, fallback.step),
    end: integer(value.end, fallback.end),
    repeatSets: integer(value.repeatSets, fallback.repeatSets),
    digits: integer(value.digits, fallback.digits),
    prefix: stringValue(value.prefix, fallback.prefix),
    suffix: stringValue(value.suffix, fallback.suffix),
  };
}

function normalizeDataTable(value: unknown): DataTable | undefined {
  if (!isRecord(value) || !Array.isArray(value.headers) || !Array.isArray(value.rows)) {
    return undefined;
  }
  const headers = value.headers.map((header, index) =>
    typeof header === "string" ? header : `Column${index + 1}`,
  );
  const rows = value.rows.map((row) => {
    const normalized: Record<string, string> = {};
    if (isRecord(row)) {
      for (const [key, cell] of Object.entries(row)) {
        normalized[key] = typeof cell === "string" ? cell : String(cell ?? "");
      }
    }
    return normalized;
  });
  return { headers, rows };
}

function normalizePrintAutomation(
  value: unknown,
  fallback: PrintAutomationSettings,
): PrintAutomationSettings {
  if (!isRecord(value)) return { ...fallback };
  const result: PrintAutomationSettings = {
    enabled: booleanValue(value.enabled, fallback.enabled),
    wifiService: stringValue(value.wifiService, fallback.wifiService),
    printerSSID: stringValue(value.printerSSID, fallback.printerSSID),
    printerPassword: stringValue(value.printerPassword, fallback.printerPassword),
    reconnectToPreviousWiFi: booleanValue(
      value.reconnectToPreviousWiFi,
      fallback.reconnectToPreviousWiFi,
    ),
    settleSeconds: finiteNumber(value.settleSeconds, fallback.settleSeconds),
  };
  if (typeof value.restoreSSID === "string") result.restoreSSID = value.restoreSSID;
  return result;
}

function normalizePlacement(value: unknown, fallback: PlacementSettings): PlacementSettings {
  if (!isRecord(value)) {
    return { ...fallback, selectedSlotIndices: [...fallback.selectedSlotIndices] };
  }
  return {
    selectedSlotIndices: Array.isArray(value.selectedSlotIndices)
      ? value.selectedSlotIndices
          .filter((slot): slot is number => typeof slot === "number" && Number.isFinite(slot))
          .map(Math.trunc)
      : [...fallback.selectedSlotIndices],
    fillDirection: enumValue<PlacementFillDirection>(
      value.fillDirection,
      FILL_DIRECTIONS,
      fallback.fillDirection,
    ),
  };
}

function normalizeElement(value: unknown, index: number): LabelElement {
  const raw = isRecord(value) ? value : {};
  const type = enumValue<ElementType>(raw.type, ELEMENT_TYPES, "text");
  const fallback = makeElement(type, index);
  const result: LabelElement = {
    id: normalizedUUID(raw.id),
    type,
    name: stringValue(raw.name, fallback.name),
    frame: normalizeRect(raw.frame, fallback.frame),
    rotation: finiteNumber(raw.rotation, fallback.rotation),
    opacity: clamp(finiteNumber(raw.opacity, fallback.opacity), 0, 1),
    content: stringValue(raw.content, fallback.content),
    fontSize: Math.max(0.1, finiteNumber(raw.fontSize, fallback.fontSize)),
    fontName: stringValue(raw.fontName, fallback.fontName),
    isBold: booleanValue(raw.isBold, fallback.isBold),
    isItalic: booleanValue(raw.isItalic, fallback.isItalic),
    isUnderline: booleanValue(raw.isUnderline, fallback.isUnderline),
    textAlignment: enumValue<TextAlignModel>(
      raw.textAlignment,
      TEXT_ALIGNMENTS,
      fallback.textAlignment,
    ),
    foreground: normalizeColor(raw.foreground, fallback.foreground),
    background: normalizeColor(raw.background, fallback.background),
    stroke: normalizeColor(raw.stroke, fallback.stroke),
    strokeWidth: Math.max(0, finiteNumber(raw.strokeWidth, fallback.strokeWidth)),
    cornerRadiusMM: Math.max(0, finiteNumber(raw.cornerRadiusMM, fallback.cornerRadiusMM)),
    imageScaleMode: enumValue(raw.imageScaleMode, ["fit", "fill"] as const, "fit"),
  };

  // Do not manufacture these two optionals for legacy documents: absence is
  // used to recognize and migrate the old circular-text frame.
  if (typeof raw.verticalTextLayout === "boolean") {
    result.verticalTextLayout = raw.verticalTextLayout;
  }
  if (typeof raw.usesCircularTextFlow === "boolean") {
    result.usesCircularTextFlow = raw.usesCircularTextFlow;
  }
  if (typeof raw.richTextRTF === "string") result.richTextRTF = raw.richTextRTF;
  if (typeof raw.imageData === "string") result.imageData = raw.imageData;
  return result;
}

function normalizeEmbeddedFont(value: unknown): EmbeddedFont | undefined {
  if (!isRecord(value)) return undefined;
  if (
    typeof value.postScriptName !== "string" ||
    typeof value.familyName !== "string" ||
    typeof value.data !== "string"
  ) {
    return undefined;
  }
  return {
    postScriptName: value.postScriptName,
    familyName: value.familyName,
    data: value.data,
  };
}

function normalizeBatch(value: unknown, index: number): PrintBatch {
  const raw = isRecord(value) ? value : {};
  const batch: PrintBatch = {
    id: normalizedUUID(raw.id),
    name: stringValue(raw.name, `Label ${index}`),
    quantity: clamp(integer(raw.quantity, 1), 1, MAX_PRINT_BATCH_QUANTITY),
    elements: Array.isArray(raw.elements)
      ? raw.elements.map((element, elementIndex) => normalizeElement(element, elementIndex + 1))
      : [],
  };
  if (isRecord(raw.serialSettings)) {
    batch.serialSettings = normalizeSerial(raw.serialSettings, DEFAULT_SERIAL_SETTINGS);
  }
  const table = normalizeDataTable(raw.dataTable);
  if (table) batch.dataTable = table;
  if (isRecord(raw.capturedPlacement)) {
    batch.capturedPlacement = normalizePlacement(raw.capturedPlacement, DEFAULT_PLACEMENT);
  }
  if (typeof raw.startPageIndex === "number") {
    batch.startPageIndex = safeNonnegativeInteger(raw.startPageIndex);
  }
  if (typeof raw.startSlotOffset === "number") {
    batch.startSlotOffset = safeNonnegativeInteger(raw.startSlotOffset);
  }
  if (typeof raw.legacySequenceOffset === "number") {
    batch.legacySequenceOffset = safeNonnegativeInteger(raw.legacySequenceOffset);
  }
  return batch;
}

/** Parse and sanitize a Swift project JSON value into the shared model. */
export function normalizeDocument(value: unknown): LabelDocument {
  const fallback = createStarterDocument();
  if (!isRecord(value) || !isRecord(value.sheet)) return fallback;

  const document: LabelDocument = {
    title: stringValue(value.title, fallback.title),
    sheet: normalizeSheet(value.sheet, fallback.sheet),
    elements: Array.isArray(value.elements)
      ? value.elements.map((element, index) => normalizeElement(element, index + 1))
      : fallback.elements,
    serial: normalizeSerial(value.serial, fallback.serial),
    notes: stringValue(value.notes, fallback.notes),
    printAutomation: normalizePrintAutomation(value.printAutomation, DEFAULT_PRINT_AUTOMATION),
    placement: normalizePlacement(value.placement, DEFAULT_PLACEMENT),
  };

  const dataTable = normalizeDataTable(value.dataTable);
  if (dataTable) document.dataTable = dataTable;
  if (typeof value.formatCode === "string") document.formatCode = value.formatCode;
  if (
    typeof value.formatFamily === "string" &&
    PRODUCT_FAMILIES.includes(value.formatFamily as ProductFamily)
  ) {
    document.formatFamily = value.formatFamily as ProductFamily;
  }
  if (typeof value.formatSourceURL === "string") {
    document.formatSourceURL = value.formatSourceURL;
  }
  if (typeof value.formatPDFTemplateURL === "string") {
    document.formatPDFTemplateURL = value.formatPDFTemplateURL;
  }
  if (Array.isArray(value.embeddedFonts)) {
    const fonts = value.embeddedFonts
      .map(normalizeEmbeddedFont)
      .filter((font): font is EmbeddedFont => font !== undefined);
    if (fonts.length > 0) document.embeddedFonts = fonts;
  }
  if (Array.isArray(value.printQueue)) {
    const batches = value.printQueue.map((batch, index) => normalizeBatch(batch, index + 1));
    if (batches.length > 0) document.printQueue = batches;
  }

  return clampDocumentElements(normalizeCircleTextFrames(document));
}

/** Deep clone for reducer-style UI updates. */
export function cloneDocument(document: LabelDocument): LabelDocument {
  if (typeof globalThis.structuredClone === "function") {
    return globalThis.structuredClone(document);
  }
  return JSON.parse(JSON.stringify(document)) as LabelDocument;
}

export function sheetFromOfficialFormat(format: OfficialFormatDefinition): SheetTemplate {
  return {
    id: format.code,
    name: format.name,
    pageWidthMM: format.pageWidthMM,
    pageHeightMM: format.pageHeightMM,
    columns: Math.max(format.columns, 1),
    rows: Math.max(format.rows, 1),
    labelWidthMM: format.labelWidthMM,
    labelHeightMM: format.labelHeightMM,
    horizontalGapMM: format.horizontalGapMM,
    verticalGapMM: format.verticalGapMM,
    marginLeftMM: format.marginLeftMM,
    marginTopMM: format.marginTopMM,
    shape: format.shape,
    cornerRadiusMM: format.cornerRadiusMM,
  };
}

export function slotFrame(sheet: SheetTemplate, column: number, row: number): RectMM {
  return {
    x: sheet.marginLeftMM + column * (sheet.labelWidthMM + sheet.horizontalGapMM),
    y: sheet.marginTopMM + row * (sheet.labelHeightMM + sheet.verticalGapMM),
    width: sheet.labelWidthMM,
    height: sheet.labelHeightMM,
  };
}

export function textSafeFrame(sheet: SheetTemplate): RectMM {
  if (sheet.shape !== "circle") {
    return { x: 0, y: 0, width: sheet.labelWidthMM, height: sheet.labelHeightMM };
  }
  const width = sheet.labelWidthMM / Math.sqrt(2);
  const height = sheet.labelHeightMM / Math.sqrt(2);
  return {
    x: (sheet.labelWidthMM - width) / 2,
    y: (sheet.labelHeightMM - height) / 2,
    width,
    height,
  };
}

export function clampRect(frame: RectMM, maxWidth: number, maxHeight: number): RectMM {
  const safeWidth = Math.max(5, Math.min(frame.width, maxWidth));
  const safeHeight = Math.max(5, Math.min(frame.height, maxHeight));
  return {
    x: Math.min(Math.max(0, frame.x), Math.max(0, maxWidth - safeWidth)),
    y: Math.min(Math.max(0, frame.y), Math.max(0, maxHeight - safeHeight)),
    width: safeWidth,
    height: safeHeight,
  };
}

function clampElements(elements: LabelElement[], sheet: SheetTemplate): LabelElement[] {
  return elements.map((element) => {
    const copy = { ...element, frame: { ...element.frame } };
    copy.frame =
      sheet.shape === "circle" &&
      element.type === "text" &&
      element.usesCircularTextFlow === true
        ? { x: 0, y: 0, width: sheet.labelWidthMM, height: sheet.labelHeightMM }
        : clampRect(element.frame, sheet.labelWidthMM, sheet.labelHeightMM);
    return copy;
  });
}

export function clampDocumentElements(document: LabelDocument): LabelDocument {
  const copy = cloneDocument(document);
  copy.elements = clampElements(copy.elements, copy.sheet);
  if (copy.printQueue) {
    copy.printQueue = copy.printQueue.map((batch) => ({
      ...batch,
      elements: clampElements(batch.elements, copy.sheet),
    }));
  }
  return copy;
}

function approximatelyEqual(left: RectMM, right: RectMM, tolerance = 0.02): boolean {
  return (
    Math.abs(left.x - right.x) <= tolerance &&
    Math.abs(left.y - right.y) <= tolerance &&
    Math.abs(left.width - right.width) <= tolerance &&
    Math.abs(left.height - right.height) <= tolerance
  );
}

/** Upgrade the legacy 680/circular text frames used by the Swift app. */
export function normalizeCircleTextFrames(document: LabelDocument): LabelDocument {
  if (document.sheet.shape !== "circle") return cloneDocument(document);
  const copy = cloneDocument(document);
  const safeFrame = textSafeFrame(copy.sheet);
  const fullFrame = {
    x: 0,
    y: 0,
    width: copy.sheet.labelWidthMM,
    height: copy.sheet.labelHeightMM,
  };
  const legacyWidth = Math.max(8, copy.sheet.labelWidthMM * 0.92);
  const legacyHeight = Math.max(8, copy.sheet.labelHeightMM * 0.92);
  const legacyX = Math.max(0, (copy.sheet.labelWidthMM - legacyWidth) / 2);
  const legacyY = Math.max(0, (copy.sheet.labelHeightMM - legacyHeight) / 2);
  const legacyCenteredFrame = {
    x: legacyX,
    y: legacyY,
    width: legacyWidth,
    height: legacyHeight,
  };
  const legacy680Frame = {
    ...legacyCenteredFrame,
    y: Math.max(0, legacyY - 0.12),
  };

  const normalizeElements = (elements: LabelElement[]): LabelElement[] =>
    elements.map((element) => {
      if (element.type !== "text") return { ...element, frame: { ...element.frame } };
      const legacyCircularFrame =
        element.usesCircularTextFlow === undefined &&
        (approximatelyEqual(element.frame, safeFrame) ||
          approximatelyEqual(element.frame, fullFrame) ||
          approximatelyEqual(element.frame, legacyCenteredFrame) ||
          (copy.formatCode === "680" && approximatelyEqual(element.frame, legacy680Frame)));
      if (element.usesCircularTextFlow === true || legacyCircularFrame) {
        return { ...element, usesCircularTextFlow: true, frame: { ...fullFrame } };
      }
      return {
        ...element,
        frame: clampRect(element.frame, copy.sheet.labelWidthMM, copy.sheet.labelHeightMM),
      };
    });

  copy.elements = normalizeElements(copy.elements);
  if (copy.printQueue) {
    copy.printQueue = copy.printQueue.map((batch) => ({
      ...batch,
      elements: normalizeElements(batch.elements),
    }));
  }
  return copy;
}

export function totalSlotCount(document: LabelDocument): number {
  return Math.max(1, saturatingMultiply(document.sheet.columns, document.sheet.rows));
}

export function orderedSlotIndices(
  document: LabelDocument,
  placement: PlacementSettings = document.placement,
): number[] {
  const total = totalSlotCount(document);
  const valid = placement.selectedSlotIndices.filter(
    (slot) => Number.isInteger(slot) && slot >= 0 && slot < total,
  );
  const normalized = valid.length === 0 ? Array.from({ length: total }, (_, index) => index) : [...new Set(valid)];
  if (placement.fillDirection === "horizontal") return normalized.sort((a, b) => a - b);

  const columns = Math.max(1, document.sheet.columns);
  return normalized.sort((left, right) => {
    const leftColumn = left % columns;
    const rightColumn = right % columns;
    if (leftColumn === rightColumn) {
      return Math.floor(left / columns) - Math.floor(right / columns);
    }
    return leftColumn - rightColumn;
  });
}

export function slotIndicesStarting(
  document: LabelDocument,
  slotIndex: number,
  fillDirection: PlacementFillDirection = document.placement.fillDirection,
): number[] {
  const allSlots = orderedSlotIndices(document, {
    selectedSlotIndices: [],
    fillDirection,
  });
  const start = allSlots.indexOf(slotIndex);
  return start < 0 ? [] : allSlots.slice(start);
}

export function pageCapacity(document: LabelDocument): number {
  return Math.max(1, orderedSlotIndices(document).length);
}

export function currentSetupLabelCount(document: LabelDocument): number {
  if (document.dataTable && document.dataTable.rows.length > 0) {
    return document.dataTable.rows.length;
  }
  const generated = serialTotalGeneratedCount(document.serial);
  if (document.serial.mode === "rangedSets" && generated > 0) return generated;
  return pageCapacity(document);
}

export function queuedLabelCount(document: LabelDocument): number {
  return (document.printQueue ?? []).reduce(
    (count, batch) => saturatingAdd(count, batch.quantity),
    0,
  );
}

export function hasQueuedLabels(document: LabelDocument): boolean {
  return queuedLabelCount(document) > 0;
}

export function mergeRowCount(document: LabelDocument): number {
  return hasQueuedLabels(document) ? queuedLabelCount(document) : currentSetupLabelCount(document);
}

function pagesNeeded(quantity: number, capacity: number, startOffset = 0): number {
  const normalizedQuantity = Math.max(1, Math.trunc(quantity));
  const normalizedCapacity = Math.max(1, Math.trunc(capacity));
  const normalizedOffset = clamp(Math.trunc(startOffset), 0, normalizedCapacity - 1);
  const adjusted = saturatingAdd(normalizedQuantity, normalizedOffset);
  return Math.floor((adjusted - 1) / normalizedCapacity) + 1;
}

export function pageCount(document: LabelDocument): number {
  if (!hasQueuedLabels(document)) {
    const count = mergeRowCount(document);
    return count > 0 ? Math.max(1, pagesNeeded(count, pageCapacity(document))) : 1;
  }

  let maximumPageCount = 0;
  let legacyQuantity = 0;
  for (const batch of document.printQueue ?? []) {
    if (!batch.capturedPlacement) {
      legacyQuantity = saturatingAdd(legacyQuantity, batch.quantity);
      continue;
    }
    const capacity = Math.max(1, orderedSlotIndices(document, batch.capturedPlacement).length);
    const span = pagesNeeded(batch.quantity, capacity, batch.startSlotOffset ?? 0);
    maximumPageCount = Math.max(
      maximumPageCount,
      saturatingAdd(Math.max(0, batch.startPageIndex ?? 0), span),
    );
  }
  if (legacyQuantity > 0) {
    maximumPageCount = Math.max(
      maximumPageCount,
      pagesNeeded(legacyQuantity, pageCapacity(document)),
    );
  }
  return Math.max(1, maximumPageCount);
}

interface QueueSlotPosition {
  batch: PrintBatch;
  localIndex: number;
  sequenceIndex: number;
}

interface PlacementSchedule {
  placement: PlacementSettings;
  startPageIndex: number;
  startSlotOffset: number;
  quantity: number;
  name: string;
}

function placementScheduleForBatch(batch: PrintBatch): PlacementSchedule | null {
  if (!batch.capturedPlacement) return null;
  return {
    placement: batch.capturedPlacement,
    startPageIndex: Math.max(0, batch.startPageIndex ?? 0),
    startSlotOffset: Math.max(0, batch.startSlotOffset ?? 0),
    quantity: batch.quantity,
    name: batch.name,
  };
}

function placementScheduleForPlan(plan: DraftPlacementPlan): PlacementSchedule {
  return {
    placement: plan.placement,
    startPageIndex: Math.max(0, plan.startPageIndex),
    startSlotOffset: 0,
    quantity: Math.max(1, plan.quantity),
    name: "Current setup",
  };
}

function localIndex(
  document: LabelDocument,
  schedule: PlacementSchedule,
  slotIndex: number,
  targetPageIndex: number,
): number | null {
  const relativePage = targetPageIndex - schedule.startPageIndex;
  if (relativePage < 0) return null;
  const slots = orderedSlotIndices(document, schedule.placement);
  const indexOnPage = slots.indexOf(slotIndex);
  if (indexOnPage < 0) return null;
  const index = saturatingAdd(saturatingMultiply(relativePage, slots.length), indexOnPage);
  const normalizedStartOffset = Math.min(
    schedule.startSlotOffset,
    Math.max(0, slots.length - 1),
  );
  if (index < normalizedStartOffset) return null;
  const local = index - normalizedStartOffset;
  return local < schedule.quantity ? local : null;
}

function usedSlots(
  document: LabelDocument,
  schedule: PlacementSchedule,
  targetPageIndex: number,
): number[] {
  return orderedSlotIndices(document, schedule.placement).filter(
    (slot) => localIndex(document, schedule, slot, targetPageIndex) !== null,
  );
}

function globalIndex(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
): number | null {
  if (targetPageIndex < 0) return null;
  const logicalSlot = orderedSlotIndices(document).indexOf(slotIndex);
  if (logicalSlot < 0) return null;
  return saturatingAdd(saturatingMultiply(targetPageIndex, pageCapacity(document)), logicalSlot);
}

function queuedBatchPosition(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
): QueueSlotPosition | null {
  if (targetPageIndex < 0 || slotIndex < 0 || slotIndex >= totalSlotCount(document)) {
    return null;
  }
  const legacyGlobalIndex = globalIndex(document, slotIndex, targetPageIndex);
  let remainingLegacyIndex = legacyGlobalIndex;

  for (const batch of document.printQueue ?? []) {
    const schedule = placementScheduleForBatch(batch);
    if (schedule) {
      const batchLocalIndex = localIndex(document, schedule, slotIndex, targetPageIndex);
      if (batchLocalIndex !== null) {
        return {
          batch,
          localIndex: batchLocalIndex,
          sequenceIndex: saturatingAdd(
            Math.max(0, batch.legacySequenceOffset ?? 0),
            batchLocalIndex,
          ),
        };
      }
      continue;
    }

    if (remainingLegacyIndex === null) continue;
    if (remainingLegacyIndex < batch.quantity) {
      return {
        batch,
        localIndex: remainingLegacyIndex,
        sequenceIndex: legacyGlobalIndex ?? remainingLegacyIndex,
      };
    }
    remainingLegacyIndex -= batch.quantity;
  }
  return null;
}

function inactiveMergeContext(slotIndex: number, targetPageIndex: number): MergeContext {
  return {
    row: {},
    serialValue: null,
    rowNumber: 0,
    pageNumber: Math.max(0, targetPageIndex) + 1,
    slotNumber: Math.max(0, slotIndex) + 1,
    isActive: false,
  };
}

function serialRowData(
  settings: SerialSettings,
  serialValue: number,
  sequenceIndex: number,
): Record<string, string> {
  const count = Math.max(serialCountPerSet(settings), 1);
  return {
    serial: formatSerialForRow(settings, serialValue),
    serial_raw: String(serialValue),
    set: String(Math.floor(sequenceIndex / count) + 1),
    index_in_set: String((sequenceIndex % count) + 1),
  };
}

function formatSerialForRow(settings: SerialSettings, value: number): string {
  const digits = Math.max(settings.digits, 1);
  const sign = value < 0 ? "-" : "";
  const width = Math.max(0, digits - sign.length);
  return `${settings.prefix}${sign}${Math.abs(Math.trunc(value))
    .toString()
    .padStart(width, "0")}${settings.suffix}`;
}

export function mergeContext(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
): MergeContext {
  if (hasQueuedLabels(document)) {
    const position = queuedBatchPosition(document, slotIndex, targetPageIndex);
    if (!position) return inactiveMergeContext(slotIndex, targetPageIndex);

    const batchSerial = position.batch.serialSettings ?? document.serial;
    const sequenceIndex = position.batch.serialSettings
      ? position.localIndex
      : position.sequenceIndex;
    const tableRows = position.batch.serialSettings
      ? position.batch.dataTable?.rows ?? []
      : document.dataTable?.rows ?? [];

    let row: Record<string, string> = {};
    let serialValue: number;
    if (tableRows.length > 0) {
      row = tableRows[sequenceIndex] ?? {};
      serialValue = batchSerial.start + sequenceIndex * batchSerial.step;
    } else if (batchSerial.mode === "rangedSets") {
      serialValue =
        generatedSerialValue(batchSerial, sequenceIndex) ??
        batchSerial.start + sequenceIndex * batchSerial.step;
      row = serialRowData(batchSerial, serialValue, sequenceIndex);
    } else {
      serialValue = batchSerial.start + sequenceIndex * batchSerial.step;
    }

    return {
      row,
      serialValue,
      rowNumber: sequenceIndex + 1,
      pageNumber: targetPageIndex + 1,
      slotNumber: slotIndex + 1,
      isActive: true,
    };
  }

  const index = globalIndex(document, slotIndex, targetPageIndex);
  if (index === null) return inactiveMergeContext(slotIndex, targetPageIndex);

  let isActive: boolean;
  let row: Record<string, string> = {};
  let serialValue: number | null;
  if (document.dataTable && document.dataTable.rows.length > 0) {
    isActive = index < document.dataTable.rows.length;
    row = isActive ? document.dataTable.rows[index] ?? {} : {};
    serialValue = isActive ? document.serial.start + index * document.serial.step : null;
  } else if (document.serial.mode === "rangedSets") {
    serialValue = generatedSerialValue(document.serial, index);
    isActive = serialValue !== null;
    if (serialValue !== null) row = serialRowData(document.serial, serialValue, index);
  } else {
    isActive = true;
    serialValue = document.serial.start + index * document.serial.step;
  }

  return {
    row,
    serialValue,
    rowNumber: index + 1,
    pageNumber: targetPageIndex + 1,
    slotNumber: slotIndex + 1,
    isActive,
  };
}

export function currentSetupMergeContext(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
): MergeContext {
  const current = cloneDocument(document);
  delete current.printQueue;
  return mergeContext(current, slotIndex, targetPageIndex);
}

export function renderPayload(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
): SlotRenderPayload {
  const context = mergeContext(document, slotIndex, targetPageIndex);
  if (!hasQueuedLabels(document) || !context.isActive) {
    return { elements: document.elements, context, serialSettings: document.serial };
  }
  const position = queuedBatchPosition(document, slotIndex, targetPageIndex);
  if (!position) {
    return { elements: document.elements, context, serialSettings: document.serial };
  }
  return {
    elements: position.batch.elements,
    context,
    serialSettings: position.batch.serialSettings ?? document.serial,
    batchID: position.batch.id,
  };
}

export function visiblePreviewSlotIndices(
  document: LabelDocument,
  targetPageIndex: number,
): number[] {
  const activeSlots = orderedSlotIndices(document);
  if (mergeRowCount(document) <= 0) return activeSlots;
  const hasCapturedPlacement = (document.printQueue ?? []).some(
    (batch) => batch.capturedPlacement !== undefined,
  );
  const candidates = hasCapturedPlacement
    ? Array.from({ length: totalSlotCount(document) }, (_, index) => index)
    : activeSlots;
  const visible = candidates.filter(
    (slotIndex) => mergeContext(document, slotIndex, targetPageIndex).isActive,
  );
  if (hasQueuedLabels(document)) return visible;
  return visible.length === 0 ? activeSlots.slice(0, 1) : visible;
}

export function draftPlacementPlan(
  document: LabelDocument,
  startPageIndex: number,
): DraftPlacementPlan {
  return {
    placement: clonePlacement(document.placement),
    startPageIndex: Math.max(0, Math.trunc(startPageIndex)),
    quantity: Math.max(1, currentSetupLabelCount(document)),
  };
}

function clonePlacement(placement: PlacementSettings): PlacementSettings {
  return {
    selectedSlotIndices: [...placement.selectedSlotIndices],
    fillDirection: placement.fillDirection,
  };
}

export function draftPreviewSlotIndices(
  document: LabelDocument,
  targetPageIndex: number,
  plan: DraftPlacementPlan,
): number[] {
  return usedSlots(document, placementScheduleForPlan(plan), targetPageIndex);
}

export function draftPreviewPayload(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
  plan: DraftPlacementPlan,
): SlotRenderPayload {
  const schedule = placementScheduleForPlan(plan);
  if (localIndex(document, schedule, slotIndex, targetPageIndex) === null) {
    return {
      elements: document.elements,
      context: inactiveMergeContext(slotIndex, targetPageIndex),
      serialSettings: document.serial,
    };
  }
  const current = cloneDocument(document);
  delete current.printQueue;
  current.placement = clonePlacement(plan.placement);
  const payload = renderPayload(current, slotIndex, targetPageIndex - plan.startPageIndex);
  payload.context.pageNumber = targetPageIndex + 1;
  return payload;
}

export function interactivePreviewPayload(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex: number,
  validDraftPlan?: DraftPlacementPlan,
): InteractiveSlotRenderPayload {
  const committed = renderPayload(document, slotIndex, targetPageIndex);
  if (committed.context.isActive && committed.batchID) {
    return {
      payload: committed,
      source: { kind: "captured", batchID: committed.batchID },
    };
  }
  if (validDraftPlan) {
    const draft = draftPreviewPayload(document, slotIndex, targetPageIndex, validDraftPlan);
    if (draft.context.isActive) return { payload: draft, source: { kind: "draft" } };
  }
  return { payload: committed, source: { kind: "inactive" } };
}

export function draftConflictSlotIndices(
  document: LabelDocument,
  targetPageIndex: number,
  plan: DraftPlacementPlan,
): number[] {
  return draftPreviewSlotIndices(document, targetPageIndex, plan).filter((slotIndex) => {
    const committed = renderPayload(document, slotIndex, targetPageIndex);
    return committed.context.isActive && committed.batchID !== undefined;
  });
}

function firstCollision(
  document: LabelDocument,
  left: PlacementSchedule,
  right: PlacementSchedule,
): { pageIndex: number; slotIndex: number } | null {
  const leftSpan = pagesNeeded(
    left.quantity,
    orderedSlotIndices(document, left.placement).length,
    left.startSlotOffset,
  );
  const rightSpan = pagesNeeded(
    right.quantity,
    orderedSlotIndices(document, right.placement).length,
    right.startSlotOffset,
  );
  const overlapStart = Math.max(left.startPageIndex, right.startPageIndex);
  const overlapEnd = Math.min(
    saturatingAdd(left.startPageIndex, leftSpan),
    saturatingAdd(right.startPageIndex, rightSpan),
  );
  if (overlapStart >= overlapEnd) return null;

  const pages = new Set([overlapStart, overlapEnd - 1]);
  if (overlapEnd - overlapStart > 2) pages.add(overlapStart + 1);
  for (const targetPageIndex of [...pages].sort((a, b) => a - b)) {
    const rightSlots = new Set(usedSlots(document, right, targetPageIndex));
    const collision = usedSlots(document, left, targetPageIndex)
      .filter((slot) => rightSlots.has(slot))
      .sort((a, b) => a - b)[0];
    if (collision !== undefined) return { pageIndex: targetPageIndex, slotIndex: collision };
  }
  return null;
}

export function firstPlacementConflict(
  document: LabelDocument,
  candidate: PrintBatch | DraftPlacementPlan,
): PrintPlacementConflict | null {
  const candidateSchedule = "elements" in candidate
    ? placementScheduleForBatch(candidate)
    : placementScheduleForPlan(candidate);
  if (!candidateSchedule) return null;

  for (const existing of document.printQueue ?? []) {
    const existingSchedule = placementScheduleForBatch(existing);
    if (!existingSchedule) continue;
    const collision = firstCollision(document, candidateSchedule, existingSchedule);
    if (collision) {
      return {
        existingBatchName: existing.name,
        pageIndex: collision.pageIndex,
        slotIndex: collision.slotIndex,
      };
    }
  }

  const legacy = (document.printQueue ?? []).filter((batch) => !batch.capturedPlacement);
  const legacyQuantity = legacy.reduce(
    (total, batch) => saturatingAdd(total, batch.quantity),
    0,
  );
  if (legacyQuantity > 0) {
    const legacySchedule: PlacementSchedule = {
      placement: document.placement,
      startPageIndex: 0,
      startSlotOffset: 0,
      quantity: legacyQuantity,
      name: legacy[0]?.name ?? "Existing capture",
    };
    const collision = firstCollision(document, candidateSchedule, legacySchedule);
    if (collision) {
      return {
        existingBatchName: legacySchedule.name,
        pageIndex: collision.pageIndex,
        slotIndex: collision.slotIndex,
      };
    }
  }
  return null;
}

export function freezeLegacyPrintQueuePlacement(document: LabelDocument): LabelDocument {
  const copy = cloneDocument(document);
  if (!copy.printQueue?.some((batch) => !batch.capturedPlacement)) return copy;
  const frozenPlacement = clonePlacement(copy.placement);
  const capacity = Math.max(1, orderedSlotIndices(copy, frozenPlacement).length);
  let legacyOffset = 0;
  copy.printQueue = copy.printQueue.map((batch) => {
    if (batch.capturedPlacement) return batch;
    const frozen: PrintBatch = {
      ...batch,
      capturedPlacement: clonePlacement(frozenPlacement),
      startPageIndex: Math.floor(legacyOffset / capacity),
      startSlotOffset: legacyOffset % capacity,
      legacySequenceOffset: legacyOffset,
    };
    legacyOffset = saturatingAdd(legacyOffset, batch.quantity);
    return frozen;
  });
  return copy;
}

export type DocumentCoreErrorCode =
  | "emptyArtwork"
  | "queueLimit"
  | "placementConflict"
  | "invalidSlot"
  | "capturedSlot";

export class DocumentCoreError extends Error {
  readonly code: DocumentCoreErrorCode;
  readonly conflict?: PrintPlacementConflict;

  constructor(
    code: DocumentCoreErrorCode,
    message: string,
    conflict?: PrintPlacementConflict,
  ) {
    super(message);
    this.name = "DocumentCoreError";
    this.code = code;
    if (conflict) this.conflict = conflict;
  }
}

function batchName(elements: LabelElement[], fallbackNumber: number): string {
  for (const element of elements) {
    if (element.type !== "text") continue;
    for (const line of element.content.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed.length === 0) continue;
      const characters = [...trimmed];
      return characters.length <= 30 ? trimmed : `${characters.slice(0, 29).join("")}…`;
    }
  }
  return `Label ${fallbackNumber}`;
}

export interface CaptureBatchOptions {
  id?: string;
  name?: string;
}

/** Snapshot the current artwork/merge setup and append it to the fixed queue. */
export function captureBatch(
  document: LabelDocument,
  startPageIndex = 0,
  options: CaptureBatchOptions = {},
): LabelDocument {
  const snapshot = freezeLegacyPrintQueuePlacement(document);
  if (snapshot.elements.length === 0) {
    throw new DocumentCoreError("emptyArtwork", "Add at least one object before saving a label");
  }
  const quantity = currentSetupLabelCount(snapshot);
  if (quantity > MAX_PRINT_BATCH_QUANTITY - queuedLabelCount(snapshot)) {
    throw new DocumentCoreError(
      "queueLimit",
      `This capture would exceed the ${MAX_PRINT_BATCH_QUANTITY.toLocaleString()}-label queue limit.`,
    );
  }

  const batch: PrintBatch = {
    id: options.id && UUID_PATTERN.test(options.id) ? options.id : createUUID(),
    name: options.name ?? batchName(snapshot.elements, (snapshot.printQueue?.length ?? 0) + 1),
    quantity,
    elements: cloneDocument(snapshot).elements,
    serialSettings: { ...snapshot.serial },
    capturedPlacement: clonePlacement(snapshot.placement),
    startPageIndex: Math.max(0, Math.trunc(startPageIndex)),
    startSlotOffset: 0,
  };
  if (snapshot.dataTable) {
    batch.dataTable = {
      headers: [...snapshot.dataTable.headers],
      rows: snapshot.dataTable.rows.map((row) => ({ ...row })),
    };
  }
  return enqueueBatch(snapshot, batch);
}

/** Append an already-created batch while enforcing the queue safety contract. */
export function enqueueBatch(document: LabelDocument, value: PrintBatch): LabelDocument {
  const copy = freezeLegacyPrintQueuePlacement(document);
  const batch = normalizeBatch(value, (copy.printQueue?.length ?? 0) + 1);
  if (batch.quantity > MAX_PRINT_BATCH_QUANTITY - queuedLabelCount(copy)) {
    throw new DocumentCoreError(
      "queueLimit",
      `This capture would exceed the ${MAX_PRINT_BATCH_QUANTITY.toLocaleString()}-label queue limit.`,
    );
  }
  const conflict = firstPlacementConflict(copy, batch);
  if (conflict) {
    throw new DocumentCoreError(
      "placementConflict",
      `Page ${conflict.pageIndex + 1}, slot ${conflict.slotIndex + 1} is already fixed by “${conflict.existingBatchName}”.`,
      conflict,
    );
  }
  copy.printQueue = [...(copy.printQueue ?? []), batch];
  return copy;
}

export function removeBatch(document: LabelDocument, id: string): LabelDocument {
  const copy = cloneDocument(document);
  const batches = (copy.printQueue ?? []).filter((batch) => batch.id !== id);
  if (batches.length > 0) copy.printQueue = batches;
  else delete copy.printQueue;
  return copy;
}

export function moveBatch(document: LabelDocument, id: string, offset: number): LabelDocument {
  const copy = cloneDocument(document);
  if (!copy.printQueue || offset === 0) return copy;
  const source = copy.printQueue.findIndex((batch) => batch.id === id);
  if (source < 0) return copy;
  const destination = clamp(source + Math.trunc(offset), 0, copy.printQueue.length - 1);
  if (destination === source) return copy;
  const [batch] = copy.printQueue.splice(source, 1);
  if (batch) copy.printQueue.splice(destination, 0, batch);
  return copy;
}

export function clearBatches(document: LabelDocument): LabelDocument {
  const copy = cloneDocument(document);
  delete copy.printQueue;
  return copy;
}

export function selectPlacementStart(
  document: LabelDocument,
  slotIndex: number,
  targetPageIndex = 0,
): LabelDocument {
  const copy = freezeLegacyPrintQueuePlacement(document);
  if (!Number.isInteger(slotIndex) || slotIndex < 0 || slotIndex >= totalSlotCount(copy)) {
    throw new DocumentCoreError("invalidSlot", `Invalid label slot: ${slotIndex}`);
  }
  if (hasQueuedLabels(copy)) {
    // The pending/staging page remains UI state, so callers pass it explicitly.
    const committed = renderPayload(copy, slotIndex, targetPageIndex);
    if (committed.context.isActive && committed.batchID) {
      throw new DocumentCoreError("capturedSlot", `Slot ${slotIndex + 1} is already captured.`);
    }
  }
  copy.placement.selectedSlotIndices = slotIndicesStarting(
    copy,
    slotIndex,
    copy.placement.fillDirection,
  );
  return copy;
}

export function selectPlacementRect(
  document: LabelDocument,
  startSlot: number,
  endSlot: number,
): LabelDocument {
  const copy = freezeLegacyPrintQueuePlacement(document);
  const columns = Math.max(1, copy.sheet.columns);
  const rows = Math.max(1, copy.sheet.rows);
  const lastSlot = columns * rows - 1;
  const start = clamp(Math.trunc(startSlot), 0, lastSlot);
  const end = clamp(Math.trunc(endSlot), 0, lastSlot);
  const startRow = Math.floor(start / columns);
  const startColumn = start % columns;
  const endRow = Math.floor(end / columns);
  const endColumn = end % columns;
  const indices: number[] = [];
  for (let row = Math.min(startRow, endRow); row <= Math.max(startRow, endRow); row += 1) {
    for (
      let column = Math.min(startColumn, endColumn);
      column <= Math.max(startColumn, endColumn);
      column += 1
    ) {
      indices.push(row * columns + column);
    }
  }
  copy.placement.selectedSlotIndices = indices;
  return copy;
}

export function clearPlacementSelection(document: LabelDocument): LabelDocument {
  const copy = freezeLegacyPrintQueuePlacement(document);
  copy.placement.selectedSlotIndices = [];
  return copy;
}

export function updatePlacementFillDirection(
  document: LabelDocument,
  fillDirection: PlacementFillDirection,
): LabelDocument {
  const copy = freezeLegacyPrintQueuePlacement(document);
  const oldPlacement = clonePlacement(copy.placement);
  if (oldPlacement.fillDirection === fillDirection) return copy;
  const first = orderedSlotIndices(copy, oldPlacement)[0];
  const oldStartSelection =
    first !== undefined &&
    oldPlacement.selectedSlotIndices.length > 0 &&
    setEquals(
      new Set(oldPlacement.selectedSlotIndices),
      new Set(slotIndicesStarting(copy, first, oldPlacement.fillDirection)),
    );
  copy.placement.fillDirection = fillDirection;
  if (oldStartSelection && first !== undefined) {
    copy.placement.selectedSlotIndices = slotIndicesStarting(copy, first, fillDirection);
  }
  return copy;
}

function setEquals<T>(left: Set<T>, right: Set<T>): boolean {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

export function capturedStartPosition(
  document: LabelDocument,
  batch: PrintBatch,
): { pageIndex: number; slotIndex: number } | null {
  const schedule = placementScheduleForBatch(batch);
  if (!schedule) return null;
  const first = usedSlots(document, schedule, schedule.startPageIndex)[0];
  return first === undefined ? null : { pageIndex: schedule.startPageIndex, slotIndex: first };
}

export function coordinateForSlot(
  document: LabelDocument,
  slotIndex: number,
): { row: number; column: number } {
  const columns = Math.max(1, document.sheet.columns);
  return {
    row: Math.floor(slotIndex / columns) + 1,
    column: (slotIndex % columns) + 1,
  };
}

export function coordinateLabel(document: LabelDocument, slotIndex: number): string {
  const coordinate = coordinateForSlot(document, slotIndex);
  return `(${coordinate.row},${coordinate.column})`;
}
