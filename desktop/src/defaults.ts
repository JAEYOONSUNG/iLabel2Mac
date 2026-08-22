import type {
  ElementType,
  LabelDocument,
  LabelElement,
  PlacementSettings,
  PrintAutomationSettings,
  RGBAColor,
  SerialSettings,
  SheetTemplate,
  UUID,
} from "./types";

export const MM_TO_POINTS_RATIO = 72 / 25.4;
export const TEXT_ELEMENT_INSET_X_MM = 1;
export const TEXT_ELEMENT_INSET_Y_MM = 0.6;
export const MAX_PRINT_BATCH_QUANTITY = 100_000;

export const COLORS = {
  clear: { red: 0, green: 0, blue: 0, alpha: 0 },
  black: { red: 0, green: 0, blue: 0, alpha: 1 },
  white: { red: 1, green: 1, blue: 1, alpha: 1 },
  accent: { red: 0.17, green: 0.31, blue: 0.88, alpha: 1 },
  softGray: { red: 0.94, green: 0.95, blue: 0.98, alpha: 1 },
  ink: { red: 0.12, green: 0.14, blue: 0.18, alpha: 1 },
} as const satisfies Record<string, RGBAColor>;

export const SHEET_PRESETS: readonly SheetTemplate[] = [
  {
    id: "a4-2x5-shipping",
    name: "A4 Shipping 2x5",
    pageWidthMM: 210,
    pageHeightMM: 297,
    columns: 2,
    rows: 5,
    labelWidthMM: 99.1,
    labelHeightMM: 57,
    horizontalGapMM: 2.8,
    verticalGapMM: 2.5,
    marginLeftMM: 4.5,
    marginTopMM: 4.5,
    shape: "roundedRectangle",
    cornerRadiusMM: 2.4,
  },
  {
    id: "a4-3x8-address",
    name: "A4 Address 3x8",
    pageWidthMM: 210,
    pageHeightMM: 297,
    columns: 3,
    rows: 8,
    labelWidthMM: 63.5,
    labelHeightMM: 33.9,
    horizontalGapMM: 3,
    verticalGapMM: 2.5,
    marginLeftMM: 6.5,
    marginTopMM: 8,
    shape: "roundedRectangle",
    cornerRadiusMM: 1.8,
  },
  {
    id: "a4-round-4x5",
    name: "A4 Round 4x5",
    pageWidthMM: 210,
    pageHeightMM: 297,
    columns: 4,
    rows: 5,
    labelWidthMM: 42,
    labelHeightMM: 42,
    horizontalGapMM: 6,
    verticalGapMM: 8.5,
    marginLeftMM: 9,
    marginTopMM: 10,
    shape: "circle",
    cornerRadiusMM: 21,
  },
  {
    id: "roll-100x50",
    name: "Roll 100 x 50",
    pageWidthMM: 100,
    pageHeightMM: 50,
    columns: 1,
    rows: 1,
    labelWidthMM: 100,
    labelHeightMM: 50,
    horizontalGapMM: 0,
    verticalGapMM: 0,
    marginLeftMM: 0,
    marginTopMM: 0,
    shape: "roundedRectangle",
    cornerRadiusMM: 2.5,
  },
];

export const CUSTOM_SHEET_DEFAULT: SheetTemplate = {
  id: "custom",
  name: "Custom",
  pageWidthMM: 210,
  pageHeightMM: 297,
  columns: 2,
  rows: 5,
  labelWidthMM: 95,
  labelHeightMM: 55,
  horizontalGapMM: 4,
  verticalGapMM: 4,
  marginLeftMM: 6,
  marginTopMM: 6,
  shape: "roundedRectangle",
  cornerRadiusMM: 2,
};

export const DEFAULT_SERIAL_SETTINGS: SerialSettings = {
  mode: "rangedSets",
  start: 1,
  step: 1,
  end: 12,
  repeatSets: 1,
  digits: 1,
  prefix: "(",
  suffix: ")",
};

export const DEFAULT_PRINT_AUTOMATION: PrintAutomationSettings = {
  enabled: false,
  wifiService: "Wi-Fi",
  printerSSID: "",
  printerPassword: "",
  reconnectToPreviousWiFi: true,
  settleSeconds: 2,
};

export const DEFAULT_PLACEMENT: PlacementSettings = {
  selectedSlotIndices: [],
  fillDirection: "horizontal",
};

function fallbackUUID(): UUID {
  // RFC 4122-shaped fallback for runtimes where Web Crypto is unavailable.
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (token) => {
    const random = Math.floor(Math.random() * 16);
    const value = token === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

export function createUUID(): UUID {
  return globalThis.crypto?.randomUUID?.() ?? fallbackUUID();
}

function color(color: RGBAColor): RGBAColor {
  return { ...color };
}

export function makeElement(type: ElementType, index = 1): LabelElement {
  const common = {
    id: createUUID(),
    type,
    rotation: 0,
    opacity: 1,
    fontSize: 12,
    fontName: "SF Pro",
    isBold: false,
    isItalic: false,
    isUnderline: false,
    textAlignment: "center" as const,
    verticalTextLayout: false,
    usesCircularTextFlow: false,
    imageScaleMode: "fit" as const,
  };

  switch (type) {
    case "text":
      return {
        ...common,
        name: `Text ${index}`,
        frame: { x: 10, y: 8 + index * 4, width: 76, height: 12 },
        content: index === 1 ? "Product Label" : "Edit this text or use {{Column}}",
        fontSize: index === 1 ? 22 : 12,
        fontName: "Arial",
        isBold: index === 1,
        foreground: color(COLORS.black),
        background: color(COLORS.clear),
        stroke: color(COLORS.clear),
        strokeWidth: 0,
        cornerRadiusMM: 0,
      };
    case "rectangle":
      return {
        ...common,
        name: `Shape ${index}`,
        frame: { x: 6, y: 6, width: 87, height: 45 },
        content: "",
        foreground: color(COLORS.clear),
        background: { red: 0.96, green: 0.97, blue: 0.99, alpha: 1 },
        stroke: { red: 0.68, green: 0.74, blue: 0.91, alpha: 1 },
        strokeWidth: 1,
        cornerRadiusMM: 2.5,
      };
    case "image":
      return {
        ...common,
        name: `Image ${index}`,
        frame: { x: 8, y: 8, width: 24, height: 24 },
        content: "",
        foreground: color(COLORS.black),
        background: color(COLORS.softGray),
        stroke: { red: 0.78, green: 0.8, blue: 0.84, alpha: 1 },
        strokeWidth: 1,
        cornerRadiusMM: 2,
      };
    case "qrCode":
      return {
        ...common,
        name: `QR ${index}`,
        frame: { x: 68, y: 8, width: 22, height: 22 },
        content: "https://label.kr",
        foreground: color(COLORS.black),
        background: color(COLORS.white),
        stroke: { red: 0.75, green: 0.77, blue: 0.82, alpha: 1 },
        strokeWidth: 1,
        cornerRadiusMM: 1.2,
      };
    case "code128":
      return {
        ...common,
        name: `Barcode ${index}`,
        frame: { x: 10, y: 33, width: 80, height: 14 },
        content: "SKU-0001",
        fontSize: 11,
        foreground: color(COLORS.black),
        background: color(COLORS.white),
        stroke: { red: 0.75, green: 0.77, blue: 0.82, alpha: 1 },
        strokeWidth: 1,
        cornerRadiusMM: 1.2,
      };
  }
}

export function createStarterDocument(): LabelDocument {
  return {
    title: "iLabel2Mac Demo",
    sheet: { ...SHEET_PRESETS[0] },
    elements: [
      makeElement("rectangle", 1),
      makeElement("text", 1),
      makeElement("text", 2),
      makeElement("qrCode", 1),
      makeElement("code128", 1),
    ],
    serial: { ...DEFAULT_SERIAL_SETTINGS },
    notes: "Use {{Column}}, {{serial}}, {{page}}, {{slot}}, {{row}}, {{date}} placeholders.",
    printAutomation: { ...DEFAULT_PRINT_AUTOMATION },
    placement: { ...DEFAULT_PLACEMENT, selectedSlotIndices: [] },
  };
}
