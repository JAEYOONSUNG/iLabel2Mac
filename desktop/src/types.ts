/**
 * Serializable application model.
 *
 * Property names and enum values intentionally mirror Swift's `Codable`
 * representation. `Data` and `UUID` values are represented by the base64 and
 * string values emitted by `JSONEncoder`, so a project can round-trip between
 * the macOS and Electron applications without a conversion step.
 */

export type UUID = string;

export interface RGBAColor {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

export interface RectMM {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type LabelShape =
  | "roundedRectangle"
  | "rectangle"
  | "capsule"
  | "circle";

export type ElementType = "text" | "rectangle" | "image" | "qrCode" | "code128";
export type ImageScaleMode = "fit" | "fill";
export type TextAlignModel = "leading" | "center" | "trailing";
export type CanvasMode = "label" | "page";
export type AppAppearanceMode = "system" | "light" | "dark";

export interface SheetTemplate {
  id: string;
  name: string;
  pageWidthMM: number;
  pageHeightMM: number;
  columns: number;
  rows: number;
  labelWidthMM: number;
  labelHeightMM: number;
  horizontalGapMM: number;
  verticalGapMM: number;
  marginLeftMM: number;
  marginTopMM: number;
  shape: LabelShape;
  cornerRadiusMM: number;
}

export type SerialMode = "continuous" | "rangedSets";

export interface SerialSettings {
  mode: SerialMode;
  start: number;
  step: number;
  end: number;
  repeatSets: number;
  digits: number;
  prefix: string;
  suffix: string;
}

export interface DataTable {
  headers: string[];
  rows: Array<Record<string, string>>;
}

export interface PrintAutomationSettings {
  enabled: boolean;
  wifiService: string;
  printerSSID: string;
  printerPassword: string;
  reconnectToPreviousWiFi: boolean;
  settleSeconds: number;
  restoreSSID?: string;
}

export type PlacementFillDirection = "horizontal" | "vertical";

export interface PlacementSettings {
  selectedSlotIndices: number[];
  fillDirection: PlacementFillDirection;
}

export interface LabelElement {
  id: UUID;
  type: ElementType;
  name: string;
  frame: RectMM;
  rotation: number;
  opacity: number;
  content: string;
  fontSize: number;
  fontName: string;
  isBold: boolean;
  isItalic: boolean;
  isUnderline: boolean;
  textAlignment: TextAlignModel;
  foreground: RGBAColor;
  background: RGBAColor;
  stroke: RGBAColor;
  strokeWidth: number;
  cornerRadiusMM: number;
  /** Optional for compatibility with projects created before vertical text. */
  verticalTextLayout?: boolean;
  /** Optional so legacy circular text frames can be detected while loading. */
  usesCircularTextFlow?: boolean;
  /** Base64-encoded RTF bytes, matching Swift `Data` JSON encoding. */
  richTextRTF?: string;
  /** Base64-encoded source image bytes, matching Swift `Data` JSON encoding. */
  imageData?: string;
  imageScaleMode: ImageScaleMode;
}

export interface EmbeddedFont {
  postScriptName: string;
  familyName: string;
  /** Base64-encoded font bytes. */
  data: string;
}

export interface PrintBatch {
  id: UUID;
  name: string;
  quantity: number;
  elements: LabelElement[];
  serialSettings?: SerialSettings;
  dataTable?: DataTable;
  capturedPlacement?: PlacementSettings;
  startPageIndex?: number;
  startSlotOffset?: number;
  legacySequenceOffset?: number;
}

export type ProductFamily =
  | "a4Label"
  | "a3Label"
  | "zLabel"
  | "rollLabel"
  | "a4Tag"
  | "zTag"
  | "rollTag";

export interface OfficialFormatDefinition {
  code: string;
  name: string;
  family: ProductFamily;
  familyLabel: string;
  sourceURL: string;
  detailURL: string;
  pdfTemplateURL?: string;
  pageWidthMM: number;
  pageHeightMM: number;
  columns: number;
  rows: number;
  labelWidthMM: number;
  labelHeightMM: number;
  horizontalGapMM: number;
  verticalGapMM: number;
  marginLeftMM: number;
  marginTopMM: number;
  marginRightMM: number;
  marginBottomMM: number;
  labelsPerPage: number;
  cornerRadiusMM: number;
  shape: LabelShape;
  officialType: string;
  continuous: boolean;
}

export interface OfficialFormatPayload {
  generatedAt: string;
  source: string;
  count: number;
  formats: OfficialFormatDefinition[];
}

export interface LabelDocument {
  title: string;
  sheet: SheetTemplate;
  elements: LabelElement[];
  serial: SerialSettings;
  dataTable?: DataTable;
  notes: string;
  formatCode?: string;
  formatFamily?: ProductFamily;
  formatSourceURL?: string;
  formatPDFTemplateURL?: string;
  printAutomation: PrintAutomationSettings;
  placement: PlacementSettings;
  embeddedFonts?: EmbeddedFont[];
  printQueue?: PrintBatch[];
}

export interface MergeContext {
  row: Record<string, string>;
  serialValue: number | null;
  rowNumber: number;
  pageNumber: number;
  slotNumber: number;
  isActive: boolean;
}

export interface SlotRenderPayload {
  elements: LabelElement[];
  context: MergeContext;
  serialSettings: SerialSettings;
  batchID?: UUID;
}

export interface PrintPlacementConflict {
  existingBatchName: string;
  pageIndex: number;
  slotIndex: number;
}

export interface DraftPlacementPlan {
  placement: PlacementSettings;
  startPageIndex: number;
  quantity: number;
}

export type InteractiveSlotRenderSource =
  | { kind: "captured"; batchID: UUID }
  | { kind: "draft" }
  | { kind: "inactive" };

export interface InteractiveSlotRenderPayload {
  payload: SlotRenderPayload;
  source: InteractiveSlotRenderSource;
}
