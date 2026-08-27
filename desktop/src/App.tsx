import {
  type ChangeEvent,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  DEFAULT_OFFICIAL_FORMAT_CODE,
  DEFAULT_PRINT_AUTOMATION,
  SHEET_PRESETS,
  createStarterDocument,
  makeElement,
} from "./defaults";
import {
  type CaptureBatchOptions,
  DocumentCoreError,
  beginBatchEdit,
  captureBatch,
  clearBatches,
  clearPlacementSelection,
  currentSetupLabelCount,
  draftConflictSlotIndices,
  draftPlacementPlan,
  draftPreviewSlotIndices,
  firstPlacementConflict,
  moveBatch,
  normalizeDocument,
  orderedSlotIndices,
  pageCount,
  removeBatch,
  renderPayload,
  repositionBatch,
  selectPlacementRect,
  selectPlacementStart,
  updatePlacementFillDirection,
  visiblePreviewSlotIndices,
} from "./core/document";
import { parseCSV } from "./core/csv";
import { normalizeDocumentImages, normalizeImportedImage } from "./core/image";
import { documentWithCollectedFonts } from "./core/fontCollection";
import {
  fontDataFingerprint,
  standaloneFontFaceBase64,
} from "./core/fontData";
import { rasterPixelSize, setPNGDataURLDPI } from "./core/png";
import { coordinatePrinterNetwork } from "./core/printCoordinator";
import { elementRichText } from "./core/richText";
import { serializeBase64RTF } from "./core/rtf";
import UpdateBanner from "./components/UpdateBanner";
import RichTextEditor, {
  type RichTextAction,
  type RichTextEditorHandle,
} from "./components/RichTextEditor";
import {
  renderLabelSVG,
  renderPageSVG,
  renderPrintHTML,
} from "./core/svg";
import type {
  AppAppearanceMode,
  CanvasMode,
  ElementType,
  LabelDocument,
  LabelElement,
  OfficialFormatDefinition,
  OfficialFormatPayload,
  ProductFamily,
  RGBAColor,
  SheetTemplate,
} from "./types";
import type { IPCResult } from "./electron";
import officialFormatPayload from "../../Resources/official_formats.json";

const OFFICIAL_FORMATS = (officialFormatPayload as unknown as OfficialFormatPayload).formats;

const BUILTIN_TOKENS = [
  "{{serial}}",
  "{{serial_raw}}",
  "{{set}}",
  "{{index_in_set}}",
  "{{page}}",
  "{{slot}}",
  "{{row}}",
  "{{date}}",
  "{{time}}",
];

const DRAFT_BATCH_ID = "00000000-0000-4000-8000-000000000001";

const FAMILY_LABELS: Record<ProductFamily, string> = {
  a4Label: "A4 Label",
  a3Label: "A3 Label",
  zLabel: "Jet Label",
  rollLabel: "Roll Label",
  a4Tag: "A4 Tag",
  zTag: "Jet Tag",
  rollTag: "Roll Tag",
};

const COMMON_FONTS = [
  "Arial",
  "Arial Narrow",
  "Calibri",
  "Cambria",
  "Courier New",
  "Georgia",
  "Malgun Gothic",
  "Noto Sans",
  "Noto Sans CJK KR",
  "Segoe UI",
  "Tahoma",
  "Times New Roman",
  "Ubuntu",
  "Verdana",
];

const clone = <T,>(value: T): T => structuredClone(value);

function safeFilename(value: string): string {
  const cleaned = value.trim().replace(/[<>:"/\\|?*\u0000-\u001f]+/g, "-");
  return cleaned || "label-project";
}

function colorToCSS(color: RGBAColor): string {
  const r = Math.round(Math.min(1, Math.max(0, color.red)) * 255);
  const g = Math.round(Math.min(1, Math.max(0, color.green)) * 255);
  const b = Math.round(Math.min(1, Math.max(0, color.blue)) * 255);
  return `rgba(${r}, ${g}, ${b}, ${Math.min(1, Math.max(0, color.alpha))})`;
}

function colorToHex(color: RGBAColor): string {
  const channel = (value: number) =>
    Math.round(Math.min(1, Math.max(0, value)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(color.red)}${channel(color.green)}${channel(color.blue)}`;
}

function hexToColor(hex: string, alpha = 1): RGBAColor {
  const value = hex.replace("#", "").padEnd(6, "0");
  return {
    red: Number.parseInt(value.slice(0, 2), 16) / 255,
    green: Number.parseInt(value.slice(2, 4), 16) / 255,
    blue: Number.parseInt(value.slice(4, 6), 16) / 255,
    alpha,
  };
}

function formatMM(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function sheetFromFormat(format: OfficialFormatDefinition): SheetTemplate {
  return {
    id: format.code,
    name: format.name,
    pageWidthMM: format.pageWidthMM,
    pageHeightMM: format.pageHeightMM,
    columns: Math.max(1, format.columns),
    rows: Math.max(1, format.rows),
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

function hasStarterArtwork(document: LabelDocument): boolean {
  const signature = (element: LabelElement) => [
    element.type,
    element.name,
    element.content,
    element.frame.x,
    element.frame.y,
    element.frame.width,
    element.frame.height,
  ].join("|");
  const starter = createStarterDocument();
  return document.elements.length === starter.elements.length
    && document.elements.every((element, index) => signature(element) === signature(starter.elements[index]));
}

function createInitialDocument(): LabelDocument {
  const document = createStarterDocument();
  try {
    const cached = JSON.parse(localStorage.getItem("ilabel2.printAutomation") ?? "null") as Partial<LabelDocument["printAutomation"]> | null;
    if (cached && typeof cached === "object") {
      const { printerPassword: _discardedPassword, ...machineSafeSettings } = cached;
      void _discardedPassword;
      document.printAutomation = { ...DEFAULT_PRINT_AUTOMATION, ...machineSafeSettings };
    }
  } catch {
    // A damaged preference must never prevent the editor from opening.
  }
  const defaultFormat = OFFICIAL_FORMATS.find(
    (format) => format.code === DEFAULT_OFFICIAL_FORMAT_CODE,
  );
  if (defaultFormat) {
    document.title = defaultFormat.code;
    document.sheet = sheetFromFormat(defaultFormat);
    document.elements = [];
    document.formatCode = defaultFormat.code;
    document.formatFamily = defaultFormat.family;
    document.formatSourceURL = defaultFormat.detailURL;
    document.formatPDFTemplateURL = defaultFormat.pdfTemplateURL;
  }
  return normalizeDocument(document);
}

function fontTraits(value: string): { bold: boolean; italic: boolean } {
  return {
    bold: /(?:bold|semibold|demibold|black|heavy)/i.test(value),
    italic: /(?:italic|oblique)/i.test(value),
  };
}

function base64Buffer(value: string): ArrayBuffer {
  const decoded = atob(value.replace(/\s+/g, ""));
  const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  return bytes.buffer as ArrayBuffer;
}

function embeddedFontFaceSource(data: string, postScriptName: string): ArrayBuffer {
  const standalone = standaloneFontFaceBase64(data, postScriptName);
  if (!standalone) throw new Error(`Embedded font ${postScriptName} is invalid.`);
  return base64Buffer(standalone);
}

function isEditingControl(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement ||
    (target instanceof HTMLElement && target.isContentEditable)
  );
}

function useElementSize<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const update = () => {
      const rect = node.getBoundingClientRect();
      setSize({ width: rect.width, height: rect.height });
    };
    update();
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return { ref, size };
}

interface SectionProps {
  title: string;
  children: ReactNode;
  className?: string;
}

function Section({ title, children, className = "" }: SectionProps) {
  return (
    <section className={`section-card ${className}`.trim()}>
      <h2>{title}</h2>
      {children}
    </section>
  );
}

interface NumberFieldProps {
  label: string;
  value: number;
  onChange: (value: number) => void;
  min?: number;
  max?: number;
  step?: number;
  suffix?: string;
  disabled?: boolean;
}

function NumberField({
  label,
  value,
  onChange,
  min,
  max,
  step = 0.1,
  suffix,
  disabled,
}: NumberFieldProps) {
  return (
    <label className="field-label">
      <span>{label}{suffix ? ` · ${suffix}` : ""}</span>
      <input
        type="number"
        value={Number.isFinite(value) ? value : 0}
        min={min}
        max={max}
        step={step}
        disabled={disabled}
        onChange={(event) => {
          const next = Number(event.currentTarget.value);
          if (Number.isFinite(next)) onChange(next);
        }}
      />
    </label>
  );
}

interface ColorFieldProps {
  label: string;
  value: RGBAColor;
  onChange: (value: RGBAColor) => void;
}

function ColorField({ label, value, onChange }: ColorFieldProps) {
  return (
    <div className="field-label inline">
      <span>{label}</span>
      <span className="color-control">
        <input
          type="color"
          aria-label={label}
          value={colorToHex(value)}
          onChange={(event) => onChange(hexToColor(event.currentTarget.value, 1))}
        />
        <button
          type="button"
          aria-label={`${value.alpha > 0 ? "Clear" : "Enable"} ${label.toLocaleLowerCase()}`}
          onClick={() => onChange({ ...value, alpha: value.alpha > 0 ? 0 : 1 })}
        >
          {value.alpha > 0 ? "Clear" : "Use"}
        </button>
      </span>
    </div>
  );
}

function elementTypeLabel(type: ElementType): string {
  switch (type) {
    case "text": return "Text";
    case "rectangle": return "Shape";
    case "image": return "Image";
    case "qrCode": return "QR";
    case "code128": return "Code128";
  }
}

interface BoardMetrics {
  width: number;
  height: number;
}

function fittedBoardMetrics(
  areaWidth: number,
  areaHeight: number,
  contentWidth: number,
  contentHeight: number,
  inset: number,
): BoardMetrics {
  if (areaWidth <= 0 || areaHeight <= 0 || contentWidth <= 0 || contentHeight <= 0) {
    return { width: 1, height: 1 };
  }
  const scale = Math.max(
    0.01,
    Math.min((areaWidth - inset * 2) / contentWidth, (areaHeight - inset * 2) / contentHeight),
  );
  return { width: contentWidth * scale, height: contentHeight * scale };
}

async function svgToPNG(
  svg: string,
  widthMM: number,
  heightMM: number,
  dpi = 720,
): Promise<string> {
  const { width, height } = rasterPixelSize(widthMM, heightMM, dpi);
  const blob = new Blob([svg], { type: "image/svg+xml;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  try {
    const image = new Image();
    image.decoding = "async";
    await new Promise<void>((resolve, reject) => {
      image.onload = () => resolve();
      image.onerror = () => reject(new Error("The print page could not be rasterized."));
      image.src = url;
    });
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Canvas rendering is unavailable.");
    context.fillStyle = "white";
    context.fillRect(0, 0, width, height);
    context.drawImage(image, 0, 0, width, height);
    return setPNGDataURLDPI(canvas.toDataURL("image/png"), dpi);
  } finally {
    URL.revokeObjectURL(url);
  }
}

interface SidebarProps {
  document: LabelDocument;
  catalog: OfficialFormatDefinition[];
  selectedID?: string;
  onDocumentField: <K extends keyof LabelDocument>(key: K, value: LabelDocument[K]) => void;
  onSheetField: <K extends keyof SheetTemplate>(key: K, value: SheetTemplate[K]) => void;
  onApplyPreset: (sheet: SheetTemplate) => void;
  onApplyFormat: (format: OfficialFormatDefinition) => void;
  onSelect: (id: string) => void;
  onDuplicate: () => void;
  onDelete: () => void;
  onInsertToken: (token: string) => void;
}

function Sidebar({
  document,
  catalog,
  selectedID,
  onDocumentField,
  onSheetField,
  onApplyPreset,
  onApplyFormat,
  onSelect,
  onDuplicate,
  onDelete,
  onInsertToken,
}: SidebarProps) {
  const [search, setSearch] = useState("");
  const [family, setFamily] = useState<ProductFamily | "all">("all");
  const hasQueue = (document.printQueue?.length ?? 0) > 0;
  const currentFormat = catalog.find((format) => format.code === document.formatCode);

  const filteredFormats = useMemo(() => {
    const query = search.trim().toLocaleLowerCase();
    return catalog.filter((format) => {
      if (family !== "all" && format.family !== family) return false;
      if (!query) return true;
      return [
        format.code,
        format.name,
        format.familyLabel,
        format.officialType,
        `${format.labelWidthMM} ${format.labelHeightMM}`,
      ]
        .join(" ")
        .toLocaleLowerCase()
        .includes(query);
    });
  }, [catalog, family, search]);

  return (
    <aside className="sidebar" aria-label="Project and label stock">
      <div className="panel-stack">
        <Section title="Project" className="project-section">
          <div className="field-stack">
            <label className="field-label">
              <span className="visually-hidden">Title</span>
              <input
                aria-label="Title"
                placeholder="Title"
                value={document.title}
                onChange={(event) => onDocumentField("title", event.currentTarget.value)}
              />
            </label>

            {currentFormat ? (
              <div className="format-summary">
                <div className="metric-line">
                  <strong>{currentFormat.code}</strong>
                  <span>{currentFormat.familyLabel}</span>
                </div>
                <span>
                  {currentFormat.continuous
                    ? `${formatMM(currentFormat.labelWidthMM)} × ${formatMM(currentFormat.labelHeightMM)} mm`
                    : `${currentFormat.columns}×${currentFormat.rows} · ${formatMM(currentFormat.labelWidthMM)} × ${formatMM(currentFormat.labelHeightMM)} mm`}
                </span>
              </div>
            ) : (
              <p className="microcopy">No official format selected. Sheet geometry remains fully editable.</p>
            )}

            <label className="field-label">
              <span className="visually-hidden">Quick presets</span>
              <select
                aria-label="Quick presets"
                className="quick-preset-menu"
                disabled={hasQueue}
                value=""
                onChange={(event) => {
                  const preset = SHEET_PRESETS.find((item) => item.id === event.currentTarget.value);
                  if (preset) onApplyPreset(preset);
                }}
              >
                <option value="">Quick Presets</option>
                {SHEET_PRESETS.map((preset) => (
                  <option key={preset.id} value={preset.id}>{preset.name}</option>
                ))}
              </select>
            </label>
          </div>
        </Section>

        <Section title="Official Formats" className="formats-section">
          <div className="compact-stack">
            <input
              aria-label="Search official formats"
              placeholder="Search code or size"
              value={search}
              onChange={(event) => setSearch(event.currentTarget.value)}
            />
            <label className="filter-row">
              <span>Family</span>
              <select
                aria-label="Product family"
                value={family}
                onChange={(event) => setFamily(event.currentTarget.value as ProductFamily | "all")}
              >
                <option value="all">All Families</option>
                {(Object.keys(FAMILY_LABELS) as ProductFamily[]).map((key) => (
                  <option key={key} value={key}>{FAMILY_LABELS[key]}</option>
                ))}
              </select>
            </label>
            <p className="microcopy">{filteredFormats.length.toLocaleString()} matches / {catalog.length.toLocaleString()} official formats</p>
            <div className="format-list" role="listbox" aria-label="Official formats">
              {filteredFormats.slice(0, 180).map((format) => (
                <button
                  key={format.code}
                  className={`format-row ${document.formatCode === format.code ? "active" : ""}`}
                  disabled={hasQueue}
                  onClick={() => onApplyFormat(format)}
                  role="option"
                  aria-selected={document.formatCode === format.code}
                >
                  <span className="format-row-copy">
                    <strong>{format.code}</strong>
                    <span>
                      {format.continuous
                        ? `${formatMM(format.labelWidthMM)} × ${formatMM(format.labelHeightMM)} mm`
                        : `${format.columns}×${format.rows} · ${formatMM(format.labelWidthMM)} × ${formatMM(format.labelHeightMM)} mm`}
                    </span>
                    <span>{format.familyLabel} · {format.continuous ? format.officialType : `${format.labelsPerPage} up`}</span>
                  </span>
                </button>
              ))}
            </div>
          </div>
        </Section>

        <Section title="Sheet" className="sheet-section">
          <fieldset disabled={hasQueue} style={{ border: 0, margin: 0, padding: 0 }}>
            <div className="sheet-settings">
              <div className="dimension-group">
                <span className="dimension-title">Page</span>
                <div className="field-grid">
                  <NumberField label="W" suffix="mm" value={document.sheet.pageWidthMM} min={10} onChange={(value) => onSheetField("pageWidthMM", value)} />
                  <NumberField label="H" suffix="mm" value={document.sheet.pageHeightMM} min={10} onChange={(value) => onSheetField("pageHeightMM", value)} />
                </div>
              </div>
              <div className="sheet-count-grid">
                <NumberField label="Columns" value={document.sheet.columns} min={1} max={50} step={1} onChange={(value) => onSheetField("columns", Math.round(value))} />
                <NumberField label="Rows" value={document.sheet.rows} min={1} max={100} step={1} onChange={(value) => onSheetField("rows", Math.round(value))} />
              </div>
              <div className="dimension-group">
                <span className="dimension-title">Label</span>
                <div className="field-grid">
                  <NumberField label="W" suffix="mm" value={document.sheet.labelWidthMM} min={1} onChange={(value) => onSheetField("labelWidthMM", value)} />
                  <NumberField label="H" suffix="mm" value={document.sheet.labelHeightMM} min={1} onChange={(value) => onSheetField("labelHeightMM", value)} />
                </div>
              </div>
              <div className="dimension-group">
                <span className="dimension-title">Gap</span>
                <div className="field-grid">
                  <NumberField label="W" suffix="mm" value={document.sheet.horizontalGapMM} min={0} onChange={(value) => onSheetField("horizontalGapMM", value)} />
                  <NumberField label="H" suffix="mm" value={document.sheet.verticalGapMM} min={0} onChange={(value) => onSheetField("verticalGapMM", value)} />
                </div>
              </div>
              <div className="dimension-group">
                <span className="dimension-title">Margins</span>
                <div className="field-grid">
                  <NumberField label="X" suffix="mm" value={document.sheet.marginLeftMM} min={0} onChange={(value) => onSheetField("marginLeftMM", value)} />
                  <NumberField label="Y" suffix="mm" value={document.sheet.marginTopMM} min={0} onChange={(value) => onSheetField("marginTopMM", value)} />
                </div>
              </div>
              <div className="sheet-final-grid">
                <NumberField label="Corner" suffix="mm" value={document.sheet.cornerRadiusMM} min={0} onChange={(value) => onSheetField("cornerRadiusMM", value)} />
                <label className="field-label inline">
                  <span>Shape</span>
                  <select value={document.sheet.shape} onChange={(event) => onSheetField("shape", event.currentTarget.value as SheetTemplate["shape"])}>
                    <option value="roundedRectangle">Rounded</option>
                    <option value="rectangle">Rectangle</option>
                    <option value="capsule">Capsule</option>
                    <option value="circle">Circle</option>
                  </select>
                </label>
              </div>
            </div>
          </fieldset>
          {hasQueue && <p className="microcopy">Reset the capture queue before changing sheet geometry.</p>}
        </Section>

        <Section title="Data" className="data-section">
          <div className="compact-stack">
            <div className="metric-line">
              <span>Imported rows</span>
              <strong>{document.dataTable?.rows.length ?? 0}</strong>
            </div>
            <p className="microcopy">Tokens are resolved independently for every printed slot.</p>
            <div className="token-cloud">
              {document.dataTable?.headers.map((header) => (
                <button key={header} onClick={() => onInsertToken(`{{${header}}}`)}>{`{{${header}}}`}</button>
              ))}
            </div>
          </div>
        </Section>

        <Section title="Objects" className="objects-section">
          <div className="object-list" role="listbox" aria-label="Label objects">
            {document.elements.map((element) => (
              <button
                key={element.id}
                className={`object-row ${selectedID === element.id ? "active" : ""}`}
                onClick={() => onSelect(element.id)}
                role="option"
                aria-selected={selectedID === element.id}
              >
                <span className="object-copy">
                  <span>{elementTypeLabel(element.type)}</span>
                  <strong>{element.name}</strong>
                </span>
              </button>
            ))}
            {document.elements.length === 0 && <div className="empty-state">Add text, a shape, an image, QR, or barcode from the toolbar.</div>}
          </div>
          <div className="object-actions" style={{ marginTop: 8 }}>
            <button disabled={!selectedID} onClick={onDuplicate}>Duplicate</button>
            <button className="danger" disabled={!selectedID} onClick={onDelete}>Delete</button>
          </div>
        </Section>
      </div>
    </aside>
  );
}

interface NumberingQueueProps {
  document: LabelDocument;
  captureIssue?: string;
  captureHint?: string;
  canCapture: boolean;
  onSerialField: <K extends keyof LabelDocument["serial"]>(key: K, value: LabelDocument["serial"][K]) => void;
  onFillDirection: (value: LabelDocument["placement"]["fillDirection"]) => void;
  editingCaptureName?: string;
  movingCaptureID?: string;
  movingCaptureName?: string;
  onCapture: () => void;
  onEditBatch: (id: string) => void;
  onCancelEditBatch: () => void;
  onBeginMoveBatch: (id: string) => void;
  onCancelMoveBatch: () => void;
  onRemoveBatch: (id: string) => void;
  onMoveBatch: (id: string, offset: number) => void;
  onResetQueue: () => void;
  onPrintAll: () => void;
}

function NumberingQueue({
  document,
  captureIssue,
  captureHint,
  canCapture,
  editingCaptureName,
  movingCaptureID,
  movingCaptureName,
  onSerialField,
  onFillDirection,
  onCapture,
  onEditBatch,
  onCancelEditBatch,
  onBeginMoveBatch,
  onCancelMoveBatch,
  onRemoveBatch,
  onMoveBatch,
  onResetQueue,
  onPrintAll,
}: NumberingQueueProps) {
  const batches = document.printQueue ?? [];
  const countPerSet = document.serial.step > 0 && document.serial.end >= document.serial.start
    ? Math.floor((document.serial.end - document.serial.start) / document.serial.step) + 1
    : 0;
  const generatedCount = countPerSet * Math.max(1, document.serial.repeatSets);
  const setupCount = currentSetupLabelCount(document);
  const queuedCount = batches.reduce((sum, batch) => sum + Math.max(0, batch.quantity), 0);

  return (
    <>
      <Section title="Numbering" className="numbering-section">
        <div className="field-grid">
          <label className="field-label">
            <span>Mode</span>
            <select value={document.serial.mode} onChange={(event) => onSerialField("mode", event.currentTarget.value as LabelDocument["serial"]["mode"])}>
              <option value="continuous">Continuous</option>
              <option value="rangedSets">Range + Sets</option>
            </select>
          </label>
          <label className="field-label">
            <span>Fill order</span>
            <select value={document.placement.fillDirection} onChange={(event) => onFillDirection(event.currentTarget.value as LabelDocument["placement"]["fillDirection"])}>
              <option value="horizontal">Horizontal</option>
              <option value="vertical">Vertical</option>
            </select>
          </label>
          <NumberField label="Start" value={document.serial.start} min={0} max={999999} step={1} onChange={(value) => onSerialField("start", Math.round(value))} />
          <NumberField label="Step" value={document.serial.step} min={1} max={999} step={1} onChange={(value) => onSerialField("step", Math.max(1, Math.round(value)))} />
          {document.serial.mode === "rangedSets" && (
            <>
              <NumberField label="End" value={document.serial.end} min={0} max={999999} step={1} onChange={(value) => onSerialField("end", Math.round(value))} />
              <NumberField label="Repeat" value={document.serial.repeatSets} min={1} max={999} step={1} onChange={(value) => onSerialField("repeatSets", Math.max(1, Math.round(value)))} />
            </>
          )}
          <NumberField label="Digits" value={document.serial.digits} min={1} max={12} step={1} onChange={(value) => onSerialField("digits", Math.max(1, Math.round(value)))} />
          <span />
          <label className="field-label">
            <span>Prefix</span>
            <input value={document.serial.prefix} onChange={(event) => onSerialField("prefix", event.currentTarget.value)} />
          </label>
          <label className="field-label">
            <span>Suffix</span>
            <input value={document.serial.suffix} onChange={(event) => onSerialField("suffix", event.currentTarget.value)} />
          </label>
        </div>
        <p className="microcopy" style={{ marginTop: 8 }}>
          {document.serial.mode === "rangedSets"
            ? `${countPerSet} per set × ${Math.max(1, document.serial.repeatSets)} = ${generatedCount} labels`
            : `Continuous · ${setupCount} labels in selected area`}
        </p>
      </Section>

      <Section title="Capture Queue" className="queue-section">
        <div className="compact-stack">
          <p className="microcopy">Each capture locks its label, Numbering/CSV setup, page, and start position. Changing the sheet start area only affects the next capture.</p>
          <div className="metric-line">
            <span>Current setup</span>
            <strong>{setupCount.toLocaleString()} label(s)</strong>
          </div>
          {editingCaptureName ? (
            <div className="button-row">
              <button className="primary" disabled={!canCapture} onClick={onCapture}>Update Capture</button>
              <button onClick={onCancelEditBatch}>Cancel Edit</button>
            </div>
          ) : (
            <button className="primary" disabled={!canCapture} onClick={onCapture}>Capture Current Setup</button>
          )}
          {editingCaptureName && (
            <div className="capture-hint">Editing “{editingCaptureName}”. Update Capture applies your changes back to its queue position.</div>
          )}
          {movingCaptureName && (
            <div className="button-row">
              <span className="capture-hint">Moving “{movingCaptureName}”. Click an empty label position on the sheet preview.</span>
              <button onClick={onCancelMoveBatch}>Cancel Move</button>
            </div>
          )}
          {captureIssue && <div className="toast-error">{captureIssue}</div>}
          {!captureIssue && captureHint && <div className="capture-hint">{captureHint}</div>}

          {batches.length > 0 ? (
            <>
              <div className="metric-line">
                <span>{queuedCount.toLocaleString()} label(s)</span>
                <strong>{pageCount(document)} page(s)</strong>
              </div>
              <div className="queue-list">
                {batches.map((batch, index) => (
                  <div className="queue-row" key={batch.id}>
                    <span className="queue-index">{index + 1}</span>
                    <span className="queue-copy">
                      <strong>{batch.name}</strong>
                      <span>{batch.quantity.toLocaleString()} labels · page {(batch.startPageIndex ?? 0) + 1}</span>
                    </span>
                    <span className="queue-actions">
                      <button aria-label="Edit capture" title="Load this capture back into the editor" disabled={Boolean(editingCaptureName)} onClick={() => onEditBatch(batch.id)}>✎</button>
                      <button aria-label="Reposition capture" title="Move this capture to a new sheet position" className={movingCaptureID === batch.id ? "active" : undefined} disabled={Boolean(editingCaptureName)} onClick={() => onBeginMoveBatch(batch.id)}>⌖</button>
                      <button aria-label="Move capture earlier" disabled={index === 0} onClick={() => onMoveBatch(batch.id, -1)}>↑</button>
                      <button aria-label="Move capture later" disabled={index === batches.length - 1} onClick={() => onMoveBatch(batch.id, 1)}>↓</button>
                      <button className="danger" aria-label="Remove capture" onClick={() => onRemoveBatch(batch.id)}>×</button>
                    </span>
                  </div>
                ))}
              </div>
              <div className="button-row">
                <button onClick={onResetQueue}>Reset Queue</button>
                <button className="primary" onClick={onPrintAll}>Print Captures</button>
              </div>
            </>
          ) : (
            <div className="empty-state">No captured setups yet.</div>
          )}
        </div>
      </Section>
    </>
  );
}

interface InspectorProps {
  document: LabelDocument;
  selected?: LabelElement;
  canvasMode: CanvasMode;
  captureIssue?: string;
  captureHint?: string;
  canCapture: boolean;
  fontFamilies: readonly string[];
  availableFontNames: ReadonlySet<string>;
  quickTextPresets: readonly string[];
  newQuickTextPreset: string;
  onNewQuickTextPreset: (value: string) => void;
  onSaveQuickTextPreset: () => void;
  onRemoveQuickTextPreset: (value: string) => void;
  onUpdateSelected: (update: (element: LabelElement) => void, key?: string) => void;
  onRichTextChange: (id: string, content: string, richTextRTF: string | undefined) => void;
  onActivateRichEditor: (editor: RichTextEditorHandle) => void;
  onTextStyleAction: (action: RichTextAction) => void;
  onChooseImage: () => void;
  onFitText: () => void;
  onInsertToken: (token: string) => void;
  onDocumentField: <K extends keyof LabelDocument>(key: K, value: LabelDocument[K]) => void;
  onPrintSettings: <K extends keyof LabelDocument["printAutomation"]>(key: K, value: LabelDocument["printAutomation"][K]) => void;
  onTestWiFi: () => void;
  onSerialField: NumberingQueueProps["onSerialField"];
  onFillDirection: NumberingQueueProps["onFillDirection"];
  editingCaptureName?: string;
  movingCaptureID?: string;
  movingCaptureName?: string;
  onCapture: () => void;
  onEditBatch: NumberingQueueProps["onEditBatch"];
  onCancelEditBatch: NumberingQueueProps["onCancelEditBatch"];
  onBeginMoveBatch: NumberingQueueProps["onBeginMoveBatch"];
  onCancelMoveBatch: NumberingQueueProps["onCancelMoveBatch"];
  onRemoveBatch: NumberingQueueProps["onRemoveBatch"];
  onMoveBatch: NumberingQueueProps["onMoveBatch"];
  onResetQueue: () => void;
  onPrintAll: () => void;
}

function Inspector({
  document,
  selected,
  canvasMode,
  captureIssue,
  captureHint,
  canCapture,
  fontFamilies,
  availableFontNames,
  quickTextPresets,
  newQuickTextPreset,
  onNewQuickTextPreset,
  onSaveQuickTextPreset,
  onRemoveQuickTextPreset,
  onUpdateSelected,
  onRichTextChange,
  onActivateRichEditor,
  onTextStyleAction,
  onChooseImage,
  onFitText,
  onInsertToken,
  onDocumentField,
  onPrintSettings,
  onTestWiFi,
  onSerialField,
  onFillDirection,
  editingCaptureName,
  movingCaptureID,
  movingCaptureName,
  onCapture,
  onEditBatch,
  onCancelEditBatch,
  onBeginMoveBatch,
  onCancelMoveBatch,
  onRemoveBatch,
  onMoveBatch,
  onResetQueue,
  onPrintAll,
}: InspectorProps) {
  const tokens = [...BUILTIN_TOKENS, ...(document.dataTable?.headers.map((header) => `{{${header}}}`) ?? [])];
  const [notesExpanded, setNotesExpanded] = useState(
    () => localStorage.getItem("ilabel2.inspector.notesExpanded") === "true",
  );
  const [wifiExpanded, setWiFiExpanded] = useState(
    () => localStorage.getItem("ilabel2.inspector.wifiExpanded") === "true",
  );
  const [highlightColor, setHighlightColor] = useState<RGBAColor>(
    { red: 1, green: 0.84, blue: 0.2, alpha: 0 },
  );

  useEffect(() => {
    localStorage.setItem("ilabel2.inspector.notesExpanded", String(notesExpanded));
  }, [notesExpanded]);

  useEffect(() => {
    localStorage.setItem("ilabel2.inspector.wifiExpanded", String(wifiExpanded));
  }, [wifiExpanded]);

  return (
    <aside className="inspector" aria-label="Selected object inspector">
      <div className="panel-stack">
        {canvasMode === "page" && (
          <NumberingQueue
            document={document}
            captureIssue={captureIssue}
            captureHint={captureHint}
            canCapture={canCapture}
            editingCaptureName={editingCaptureName}
            movingCaptureID={movingCaptureID}
            movingCaptureName={movingCaptureName}
            onSerialField={onSerialField}
            onFillDirection={onFillDirection}
            onCapture={onCapture}
            onEditBatch={onEditBatch}
            onCancelEditBatch={onCancelEditBatch}
            onBeginMoveBatch={onBeginMoveBatch}
            onCancelMoveBatch={onCancelMoveBatch}
            onRemoveBatch={onRemoveBatch}
            onMoveBatch={onMoveBatch}
            onResetQueue={onResetQueue}
            onPrintAll={onPrintAll}
          />
        )}

        {selected ? (
          <>
            <Section title="Selection" className="selected-object-section">
              <div className="field-stack">
                <label className="field-label">
                  <span>Name</span>
                  <input value={selected.name} onChange={(event) => {
                    const value = event.currentTarget.value;
                    onUpdateSelected((element) => { element.name = value; }, "selected-name");
                  }} />
                </label>
                <div className="metric-line"><span>Type</span><strong>{elementTypeLabel(selected.type)}</strong></div>

                {(selected.type === "text" || selected.type === "qrCode" || selected.type === "code128") && (
                  <>
                    <div className="field-label">
                      <span>Content</span>
                      {selected.type === "text" ? (
                        <RichTextEditor
                          element={selected}
                          ariaLabel="Text content"
                          fontScale={12 / Math.max(0.5, selected.fontSize)}
                          style={{ textAlign: "left" }}
                          onChange={(content, richTextRTF) => onRichTextChange(
                            selected.id,
                            content,
                            richTextRTF,
                          )}
                          onActive={onActivateRichEditor}
                        />
                      ) : (
                        <textarea
                          rows={5}
                          value={selected.content}
                          onChange={(event) => {
                            const value = event.currentTarget.value;
                            onUpdateSelected((element) => {
                              element.content = value;
                              element.richTextRTF = undefined;
                            }, "selected-content");
                          }}
                        />
                      )}
                    </div>
                    <div className="token-cloud">
                      {tokens.map((token) => <button key={token} onClick={() => onInsertToken(token)}>{token}</button>)}
                    </div>
                    {selected.type === "text" && (
                      <div className="compact-stack">
                        <span>Quick presets</span>
                        <div className="token-cloud">
                          {quickTextPresets.map((preset) => (
                            <span className="preset-chip" key={preset}>
                              <button onClick={() => onInsertToken(preset)}>{preset}</button>
                              <button
                                className="danger"
                                aria-label={`Remove ${preset}`}
                                onClick={() => onRemoveQuickTextPreset(preset)}
                              >×</button>
                            </span>
                          ))}
                        </div>
                        <div className="button-row">
                          <input
                            placeholder="Add preset"
                            value={newQuickTextPreset}
                            onChange={(event) => onNewQuickTextPreset(event.currentTarget.value)}
                          />
                          <button onClick={onSaveQuickTextPreset}>Save</button>
                        </div>
                      </div>
                    )}
                  </>
                )}

                {selected.type === "image" && <button onClick={onChooseImage}>Choose image…</button>}
              </div>
            </Section>

            <Section title="Frame" className="frame-section">
              <div className="field-grid">
                <NumberField label="X" suffix="mm" value={selected.frame.x} step={0.1} onChange={(value) => onUpdateSelected((element) => { element.frame.x = value; }, "frame-x")} />
                <NumberField label="Y" suffix="mm" value={selected.frame.y} step={0.1} onChange={(value) => onUpdateSelected((element) => { element.frame.y = value; }, "frame-y")} />
                <NumberField label="W" suffix="mm" value={selected.frame.width} min={0.5} step={0.1} onChange={(value) => onUpdateSelected((element) => { element.frame.width = Math.max(0.5, value); }, "frame-w")} />
                <NumberField label="H" suffix="mm" value={selected.frame.height} min={0.5} step={0.1} onChange={(value) => onUpdateSelected((element) => { element.frame.height = Math.max(0.5, value); }, "frame-h")} />
                <NumberField label="Rotation" suffix="deg" value={selected.rotation} step={1} onChange={(value) => onUpdateSelected((element) => { element.rotation = value; }, "rotation")} />
                <NumberField label="Opacity" value={selected.opacity} min={0} max={1} step={0.05} onChange={(value) => onUpdateSelected((element) => { element.opacity = Math.min(1, Math.max(0, value)); }, "opacity")} />
              </div>
              {selected.type === "text" && <button style={{ marginTop: 8 }} onClick={onFitText}>{document.sheet.shape === "circle" ? "Fit text to circle" : "Center in label"}</button>}
            </Section>

            <Section title="Appearance" className="appearance-section">
              <div className="field-stack">
                {selected.type === "text" && (
                  <>
                    <div className="field-grid">
                      <label className="field-label">
                        <span>Size · pt</span>
                        <input
                          key={`${selected.id}-font-size-${selected.fontSize}`}
                          type="number"
                          defaultValue={selected.fontSize}
                          min={0.5}
                          step={0.5}
                          onBlur={(event) => {
                            if (event.currentTarget.dataset.dirty !== "true") return;
                            delete event.currentTarget.dataset.dirty;
                            const value = Number(event.currentTarget.value);
                            if (Number.isFinite(value)) {
                              onTextStyleAction({ kind: "fontSize", value: Math.max(0.5, value) });
                            }
                          }}
                          onInput={(event) => { event.currentTarget.dataset.dirty = "true"; }}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") event.currentTarget.blur();
                            if (event.key === "Escape") {
                              delete event.currentTarget.dataset.dirty;
                              event.currentTarget.value = String(selected.fontSize);
                              event.currentTarget.blur();
                            }
                          }}
                        />
                      </label>
                      <label className="field-label">
                        <span>Font</span>
                        <input
                          key={`${selected.id}-font-family-${selected.fontName}`}
                          list="common-fonts"
                          defaultValue={selected.fontName}
                          onBlur={(event) => {
                            if (event.currentTarget.dataset.dirty !== "true") return;
                            delete event.currentTarget.dataset.dirty;
                            const value = event.currentTarget.value.trim();
                            if (value) onTextStyleAction({ kind: "fontFamily", value });
                          }}
                          onInput={(event) => { event.currentTarget.dataset.dirty = "true"; }}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") event.currentTarget.blur();
                            if (event.key === "Escape") {
                              delete event.currentTarget.dataset.dirty;
                              event.currentTarget.value = selected.fontName;
                              event.currentTarget.blur();
                            }
                          }}
                        />
                        <datalist id="common-fonts">{fontFamilies.map((font) => <option key={font} value={font} />)}</datalist>
                      </label>
                    </div>
                    {(() => {
                      const missing = [...new Set(
                        elementRichText(selected).runs
                          .map((run) => run.fontName || selected.fontName)
                          .filter((name) => !availableFontNames.has(name.toLocaleLowerCase())),
                      )];
                      return missing.length > 0 ? (
                        <div className="toast-error">
                          Missing font{missing.length === 1 ? "" : "s"}: {missing.join(", ")}. Install the font or save from its source machine to embed it.
                        </div>
                      ) : null;
                    })()}
                    <div className="style-buttons segmented">
                      <button className={selected.isBold ? "active" : ""} onClick={() => onTextStyleAction({ kind: "bold" })}>Bold</button>
                      <button className={selected.isItalic ? "active" : ""} onClick={() => onTextStyleAction({ kind: "italic" })}>Italic</button>
                      <button className={selected.isUnderline ? "active" : ""} onClick={() => onTextStyleAction({ kind: "underline" })}>Underline</button>
                    </div>
                    <label className="field-label inline">
                      <span>Align</span>
                      <select value={selected.textAlignment} onChange={(event) => {
                        const value = event.currentTarget.value as LabelElement["textAlignment"];
                        onUpdateSelected((element) => { element.textAlignment = value; });
                      }}>
                        <option value="leading">Left</option>
                        <option value="center">Center</option>
                        <option value="trailing">Right</option>
                      </select>
                    </label>
                    <label className="field-label checkbox-row">
                      <input type="checkbox" checked={selected.verticalTextLayout ?? false} onChange={(event) => {
                        const checked = event.currentTarget.checked;
                        onUpdateSelected((element) => { element.verticalTextLayout = checked; });
                      }} />
                      Vertical text
                    </label>
                    {document.sheet.shape === "circle" && (
                      <label className="field-label checkbox-row">
                        <input type="checkbox" checked={selected.usesCircularTextFlow ?? false} onChange={(event) => {
                          const checked = event.currentTarget.checked;
                          onUpdateSelected((element) => { element.usesCircularTextFlow = checked; });
                        }} />
                        Follow circular chords
                      </label>
                    )}
                  </>
                )}

                {selected.type === "image" && (
                  <label className="field-label inline">
                    <span>Scaling</span>
                    <select value={selected.imageScaleMode} onChange={(event) => {
                      const value = event.currentTarget.value as LabelElement["imageScaleMode"];
                      onUpdateSelected((element) => { element.imageScaleMode = value; });
                    }}>
                      <option value="fit">Fit</option>
                      <option value="fill">Fill</option>
                    </select>
                  </label>
                )}

                <ColorField label={selected.type === "text" ? "Text color" : "Foreground"} value={selected.foreground} onChange={(value) => selected.type === "text"
                  ? onTextStyleAction({ kind: "foreground", value })
                  : onUpdateSelected((element) => { element.foreground = value; }, "foreground")} />
                {selected.type === "text" && (
                  <ColorField label="Highlight" value={highlightColor} onChange={(value) => {
                    setHighlightColor(value);
                    onTextStyleAction({ kind: "highlight", value: value.alpha > 0 ? value : undefined });
                  }} />
                )}
                <ColorField label="Background" value={selected.background} onChange={(value) => onUpdateSelected((element) => { element.background = value; }, "background")} />
                <ColorField label="Stroke" value={selected.stroke} onChange={(value) => onUpdateSelected((element) => { element.stroke = value; }, "stroke")} />
                <div className="field-grid">
                  <NumberField label="Stroke" suffix="pt" value={selected.strokeWidth} min={0} step={0.25} onChange={(value) => onUpdateSelected((element) => { element.strokeWidth = Math.max(0, value); }, "stroke-width")} />
                  <NumberField label="Corner" suffix="mm" value={selected.cornerRadiusMM} min={0} step={0.25} onChange={(value) => onUpdateSelected((element) => { element.cornerRadiusMM = Math.max(0, value); }, "element-corner")} />
                </div>
              </div>
            </Section>
          </>
        ) : (
          <Section title="Selection" className="selection-empty-section">
            <div className="selection-empty">Select an object from the canvas or object list to edit it.</div>
          </Section>
        )}

        <details
          className="section-card"
          open={notesExpanded}
          onToggle={(event) => setNotesExpanded(event.currentTarget.open)}
        >
          <summary>Project Notes</summary>
          <textarea rows={5} value={document.notes} onChange={(event) => onDocumentField("notes", event.currentTarget.value)} />
        </details>

        <details
          className="section-card"
          open={wifiExpanded}
          onToggle={(event) => setWiFiExpanded(event.currentTarget.open)}
        >
          <summary>Wi-Fi Print</summary>
          <div className="field-stack">
            <label className="field-label checkbox-row">
              <input type="checkbox" checked={document.printAutomation.enabled} onChange={(event) => onPrintSettings("enabled", event.currentTarget.checked)} />
              Switch Wi-Fi when printing
            </label>
            <label className="field-label"><span>Wi-Fi service / adapter</span><input value={document.printAutomation.wifiService} onChange={(event) => onPrintSettings("wifiService", event.currentTarget.value)} /></label>
            <label className="field-label"><span>Printer SSID</span><input value={document.printAutomation.printerSSID} onChange={(event) => onPrintSettings("printerSSID", event.currentTarget.value)} /></label>
            <label className="field-label"><span>Password</span><input type="password" value={document.printAutomation.printerPassword} onChange={(event) => onPrintSettings("printerPassword", event.currentTarget.value)} /></label>
            <label className="field-label checkbox-row">
              <input type="checkbox" checked={document.printAutomation.reconnectToPreviousWiFi} onChange={(event) => onPrintSettings("reconnectToPreviousWiFi", event.currentTarget.checked)} />
              Return to previous Wi-Fi
            </label>
            <label className="field-label"><span>Restore SSID (optional)</span><input value={document.printAutomation.restoreSSID ?? ""} onChange={(event) => onPrintSettings("restoreSSID", event.currentTarget.value || undefined)} /></label>
            <NumberField label="Settle time" suffix="sec" value={document.printAutomation.settleSeconds} min={0} max={60} step={0.5} onChange={(value) => onPrintSettings("settleSeconds", Math.max(0, value))} />
            <button onClick={onTestWiFi}>Connect test</button>
            <p className="microcopy">Windows uses saved WLAN profiles; Linux uses NetworkManager (nmcli). Leave this off for printers available on the current network.</p>
          </div>
        </details>
      </div>
    </aside>
  );
}

interface LabelEditorProps {
  document: LabelDocument;
  selectedID?: string;
  onSelect: (id: string) => void;
  onFrameChange: (id: string, frame: LabelElement["frame"]) => void;
  onRichTextChange: (id: string, content: string, richTextRTF: string | undefined) => void;
  onActivateRichEditor: (editor: RichTextEditorHandle) => void;
  onActivateText: () => Promise<string | undefined>;
}

function LabelEditor({
  document,
  selectedID,
  onSelect,
  onFrameChange,
  onRichTextChange,
  onActivateRichEditor,
  onActivateText,
}: LabelEditorProps) {
  const { ref: stageRef, size: stageSize } = useElementSize<HTMLDivElement>();
  const [editingID, setEditingID] = useState<string>();
  const editorRef = useRef<RichTextEditorHandle>(null);
  const boardMetrics = fittedBoardMetrics(
    stageSize.width,
    stageSize.height,
    document.sheet.labelWidthMM,
    document.sheet.labelHeightMM,
    22,
  );
  const liveDocument = useMemo(() => {
    const next = clone(document);
    next.printQueue = undefined;
    if (editingID) {
      const editing = next.elements.find((element) => element.id === editingID);
      if (editing) editing.opacity = 0;
    }
    return next;
  }, [document, editingID]);
  const payload = useMemo(() => renderPayload(liveDocument, orderedSlotIndices(liveDocument)[0] ?? 0, 0), [liveDocument]);
  const svg = useMemo(() => renderLabelSVG(liveDocument, payload, { showGuides: true }), [liveDocument, payload]);

  useEffect(() => {
    if (editingID) {
      requestAnimationFrame(() => {
        editorRef.current?.focus();
      });
    }
  }, [editingID]);

  const drag = useRef<{
    mode: "move" | "resize";
    id: string;
    startX: number;
    startY: number;
    frame: LabelElement["frame"];
  } | undefined>(undefined);

  const startDrag = (
    event: ReactPointerEvent<HTMLElement>,
    element: LabelElement,
    mode: "move" | "resize",
  ) => {
    if (editingID) return;
    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    onSelect(element.id);
    drag.current = {
      mode,
      id: element.id,
      startX: event.clientX,
      startY: event.clientY,
      frame: { ...element.frame },
    };
  };

  const updateDrag = (event: ReactPointerEvent<HTMLElement>) => {
    const active = drag.current;
    if (!active) return;
    const deltaX = ((event.clientX - active.startX) / Math.max(boardMetrics.width, 1)) * document.sheet.labelWidthMM;
    const deltaY = ((event.clientY - active.startY) / Math.max(boardMetrics.height, 1)) * document.sheet.labelHeightMM;
    if (active.mode === "move") {
      onFrameChange(active.id, {
        ...active.frame,
        x: Math.min(Math.max(0, active.frame.x + deltaX), Math.max(0, document.sheet.labelWidthMM - active.frame.width)),
        y: Math.min(Math.max(0, active.frame.y + deltaY), Math.max(0, document.sheet.labelHeightMM - active.frame.height)),
      });
    } else {
      onFrameChange(active.id, {
        ...active.frame,
        width: Math.min(Math.max(0.5, active.frame.width + deltaX), document.sheet.labelWidthMM - active.frame.x),
        height: Math.min(Math.max(0.5, active.frame.height + deltaY), document.sheet.labelHeightMM - active.frame.y),
      });
    }
  };

  const endDrag = (event: ReactPointerEvent<HTMLElement>) => {
    if (drag.current) {
      try { event.currentTarget.releasePointerCapture(event.pointerId); } catch { /* capture may already be released */ }
      drag.current = undefined;
    }
  };

  const editingElement = editingID ? document.elements.find((element) => element.id === editingID) : undefined;
  const pxPerMM = boardMetrics.width / Math.max(document.sheet.labelWidthMM, 0.1);
  const editorTopInsetMM = useMemo(() => {
    if (!editingElement) return 0.6;
    try {
      const parsed = new DOMParser().parseFromString(svg, "image/svg+xml");
      const group = [...parsed.querySelectorAll("[data-element-id]")]
        .find((candidate) => candidate.getAttribute("data-element-id") === editingElement.id);
      const firstLine = group?.querySelector("[data-text-start]");
      const baseline = Number(firstLine?.getAttribute("y"));
      const fontSize = Number(firstLine?.getAttribute("data-line-font-size"));
      if (Number.isFinite(baseline) && Number.isFinite(fontSize)) {
        return Math.max(0, baseline - fontSize * 0.82 - editingElement.frame.y);
      }
    } catch {
      // Keep the shared default inset when the preview is still initializing.
    }
    return 0.6;
  }, [editingElement, svg]);

  return (
    <div
      className="label-editor-stage"
      ref={stageRef}
      onPointerDown={() => {
        // Click the label and type: a click on empty space while editing puts
        // the pen down; otherwise it picks up a text element (creating one on
        // an empty label) and starts typing there — same as the macOS edition.
        if (editingID) {
          setEditingID(undefined);
          return;
        }
        void onActivateText().then((id) => { if (id) setEditingID(id); });
      }}
    >
      <div
        className="label-board"
        data-width={formatMM(document.sheet.labelWidthMM)}
        data-height={formatMM(document.sheet.labelHeightMM)}
        style={{ width: boardMetrics.width, height: boardMetrics.height }}
      >
        <div className="svg-surface" dangerouslySetInnerHTML={{ __html: svg }} />
        {document.elements.map((element) => {
          const style: CSSProperties = {
            left: `${(element.frame.x / document.sheet.labelWidthMM) * 100}%`,
            top: `${(element.frame.y / document.sheet.labelHeightMM) * 100}%`,
            width: `${(element.frame.width / document.sheet.labelWidthMM) * 100}%`,
            height: `${(element.frame.height / document.sheet.labelHeightMM) * 100}%`,
            transform: `rotate(${element.rotation}deg)`,
          };
          return (
            <button
              key={element.id}
              aria-label={`Select ${element.name}`}
              className={`element-hitbox ${selectedID === element.id ? "selected" : ""}`}
              style={style}
              onClick={(event) => { event.stopPropagation(); onSelect(element.id); }}
              onDoubleClick={(event) => {
                event.stopPropagation();
                if (element.type === "text") setEditingID(element.id);
              }}
              onPointerDown={(event) => startDrag(event, element, "move")}
              onPointerMove={updateDrag}
              onPointerUp={endDrag}
              onPointerCancel={endDrag}
            >
              {selectedID === element.id && (
                <span
                  className="resize-handle"
                  role="presentation"
                  onPointerDown={(event) => startDrag(event, element, "resize")}
                  onPointerMove={updateDrag}
                  onPointerUp={endDrag}
                  onPointerCancel={endDrag}
                />
              )}
            </button>
          );
        })}

        {editingElement && (
          <RichTextEditor
            ref={editorRef}
            className="inline-editor"
            ariaLabel={`Edit ${editingElement.name}`}
            element={editingElement}
            fontScale={(25.4 / 96) * pxPerMM}
            circularFlow={editingElement.usesCircularTextFlow === true}
            onPointerDown={(event) => event.stopPropagation()}
            onChange={(content, richTextRTF) => onRichTextChange(
              editingElement.id,
              content,
              richTextRTF,
            )}
            onActive={onActivateRichEditor}
            onEscape={() => setEditingID(undefined)}
            style={{
              left: `${(editingElement.frame.x / document.sheet.labelWidthMM) * 100}%`,
              top: `${(editingElement.frame.y / document.sheet.labelHeightMM) * 100}%`,
              width: `${(editingElement.frame.width / document.sheet.labelWidthMM) * 100}%`,
              height: `${(editingElement.frame.height / document.sheet.labelHeightMM) * 100}%`,
              transform: `rotate(${editingElement.rotation}deg)`,
              color: colorToCSS(editingElement.foreground),
              background: colorToCSS(editingElement.background),
              padding: `${editorTopInsetMM * pxPerMM}px ${editingElement.usesCircularTextFlow ? 0 : 1 * pxPerMM}px 0`,
              borderRadius: editingElement.usesCircularTextFlow ? "50%" : "2px",
              clipPath: editingElement.usesCircularTextFlow ? "ellipse(50% 50% at 50% 50%)" : undefined,
              lineHeight: 1.2,
              "--circle-flow-padding": `${1 * pxPerMM}px`,
            }}
          />
        )}
      </div>
    </div>
  );
}

interface PageBoardProps {
  document: LabelDocument;
  pageIndex: number;
  conflictSlots?: Set<number>;
  interactive?: boolean;
  compact?: boolean;
  draftBatchID?: string;
  onSelectSlot?: (slotIndex: number) => void;
  onSelectRange?: (startSlot: number, endSlot: number) => void;
}

function PageBoard({
  document,
  pageIndex,
  conflictSlots = new Set<number>(),
  interactive = false,
  compact = false,
  draftBatchID,
  onSelectSlot,
  onSelectRange,
}: PageBoardProps) {
  const { ref, size } = useElementSize<HTMLDivElement>();
  const inset = compact ? 20 : 28;
  const board = fittedBoardMetrics(size.width, size.height, document.sheet.pageWidthMM, document.sheet.pageHeightMM, inset);
  const svg = useMemo(
    () => renderPageSVG(document, pageIndex, {
      showGuides: true,
      allowEmptyPage: pageIndex === pageCount(document),
    }),
    [document, pageIndex],
  );
  const slots = Array.from({ length: Math.max(1, document.sheet.columns * document.sheet.rows) }, (_, index) => index);
  const dragStart = useRef<number | undefined>(undefined);
  const dragMoved = useRef(false);

  useEffect(() => {
    const clearDrag = () => { dragStart.current = undefined; };
    globalThis.addEventListener("pointerup", clearDrag);
    globalThis.addEventListener("pointercancel", clearDrag);
    return () => {
      globalThis.removeEventListener("pointerup", clearDrag);
      globalThis.removeEventListener("pointercancel", clearDrag);
    };
  }, []);

  return (
    <div className={compact ? "mini-page-wrap" : "page-editor-stage"} ref={ref}>
      <div className="page-board with-indexes" style={{ width: board.width, height: board.height }}>
        <div className="page-surface" dangerouslySetInnerHTML={{ __html: svg }} />
        <div className="page-column-axis" aria-hidden="true">
          {Array.from({ length: document.sheet.columns }, (_, column) => {
            const center = document.sheet.marginLeftMM
              + column * (document.sheet.labelWidthMM + document.sheet.horizontalGapMM)
              + document.sheet.labelWidthMM / 2;
            return <span key={column} style={{ left: `${(center / document.sheet.pageWidthMM) * 100}%` }}>{column + 1}</span>;
          })}
        </div>
        <div className="page-row-axis" aria-hidden="true">
          {Array.from({ length: document.sheet.rows }, (_, row) => {
            const center = document.sheet.marginTopMM
              + row * (document.sheet.labelHeightMM + document.sheet.verticalGapMM)
              + document.sheet.labelHeightMM / 2;
            return <span key={row} style={{ top: `${(center / document.sheet.pageHeightMM) * 100}%` }}>{row + 1}</span>;
          })}
        </div>
        {interactive && slots.map((slotIndex) => {
          const row = Math.floor(slotIndex / document.sheet.columns);
          const column = slotIndex % document.sheet.columns;
          const left = document.sheet.marginLeftMM + column * (document.sheet.labelWidthMM + document.sheet.horizontalGapMM);
          const top = document.sheet.marginTopMM + row * (document.sheet.labelHeightMM + document.sheet.verticalGapMM);
          const payload = renderPayload(document, slotIndex, pageIndex);
          const cornerRadiusMM = Math.min(
            Math.max(0, document.sheet.cornerRadiusMM),
            Math.min(document.sheet.labelWidthMM, document.sheet.labelHeightMM) / 2,
          );
          const cornerRadiusXPX = cornerRadiusMM
            * (board.width / Math.max(document.sheet.pageWidthMM, 0.1));
          const cornerRadiusYPX = cornerRadiusMM
            * (board.height / Math.max(document.sheet.pageHeightMM, 0.1));
          return (
            <button
              key={slotIndex}
              data-slot-index={slotIndex}
              aria-label={`Start at row ${row + 1}, column ${column + 1}`}
              className={`page-slot-hit shape-${document.sheet.shape} ${conflictSlots.has(slotIndex) ? "conflict" : payload.batchID === draftBatchID ? "draft" : payload.batchID ? "captured" : payload.context.isActive ? "active" : ""}`}
              data-label-shape={document.sheet.shape}
              style={{
                left: `${(left / document.sheet.pageWidthMM) * 100}%`,
                top: `${(top / document.sheet.pageHeightMM) * 100}%`,
                width: `${(document.sheet.labelWidthMM / document.sheet.pageWidthMM) * 100}%`,
                height: `${(document.sheet.labelHeightMM / document.sheet.pageHeightMM) * 100}%`,
                "--slot-corner-radius-x": `${cornerRadiusXPX}px`,
                "--slot-corner-radius-y": `${cornerRadiusYPX}px`,
              } as CSSProperties}
              onPointerDown={(event) => {
                if (event.button !== 0) return;
                event.preventDefault();
                dragStart.current = slotIndex;
                dragMoved.current = false;
              }}
              onPointerOver={(event) => {
                if (dragStart.current === undefined || event.buttons !== 1) return;
                dragMoved.current = dragMoved.current || dragStart.current !== slotIndex;
                onSelectRange?.(dragStart.current, slotIndex);
              }}
              onPointerUp={() => {
                if (dragStart.current === undefined) return;
                if (dragMoved.current) onSelectRange?.(dragStart.current, slotIndex);
                else onSelectSlot?.(slotIndex);
                dragStart.current = undefined;
              }}
            />
          );
        })}
      </div>
    </div>
  );
}

interface EditorProps extends NumberingQueueProps {
  document: LabelDocument;
  previewDocument: LabelDocument;
  pageIndex: number;
  canvasMode: CanvasMode;
  pendingPage?: number;
  selectedID?: string;
  onSelect: (id: string) => void;
  onFrameChange: LabelEditorProps["onFrameChange"];
  onRichTextChange: LabelEditorProps["onRichTextChange"];
  onActivateRichEditor: LabelEditorProps["onActivateRichEditor"];
  onActivateText: LabelEditorProps["onActivateText"];
  onSelectSlot: (slotIndex: number) => void;
  onSelectSlotRange: (startSlot: number, endSlot: number) => void;
  onResetArea: () => void;
}

function Editor({
  document,
  previewDocument,
  pageIndex,
  canvasMode,
  selectedID,
  pendingPage,
  captureIssue,
  captureHint,
  canCapture,
  onSelect,
  onFrameChange,
  onRichTextChange,
  onActivateRichEditor,
  onActivateText,
  onSelectSlot,
  onSelectSlotRange,
  onResetArea,
  onSerialField,
  onFillDirection,
  editingCaptureName,
  movingCaptureID,
  movingCaptureName,
  onCapture,
  onEditBatch,
  onCancelEditBatch,
  onBeginMoveBatch,
  onCancelMoveBatch,
  onRemoveBatch,
  onMoveBatch,
  onResetQueue,
  onPrintAll,
}: EditorProps) {
  const selectedText = document.elements.find((element) => element.id === selectedID && element.type === "text")
    ?? document.elements.find((element) => element.type === "text");
  const queued = (document.printQueue?.length ?? 0) > 0;
  const draftPlan = queued && pendingPage !== undefined
    ? draftPlacementPlan(document, pendingPage)
    : undefined;
  const draftSlots = draftPlan
    ? draftPreviewSlotIndices(document, pageIndex, draftPlan)
    : [];
  const conflicts = new Set(
    draftPlan ? draftConflictSlotIndices(document, pageIndex, draftPlan) : [],
  );
  const capturedOnPage = visiblePreviewSlotIndices(document, pageIndex).length;

  return (
    <main className="editor-pane">
      <header className="editor-heading">
        <div>
          <div className="editor-title-line">
            <h1>{canvasMode === "label" ? "Label Editor" : "Page Preview"}</h1>
            <span>{canvasMode === "label" ? "Click the label and type." : "Full-sheet output preview."}</span>
          </div>
          {canvasMode === "label" && (
            <p className="editor-spec">
              Print spec: {selectedText ? `${selectedText.fontName} size ${formatMM(selectedText.fontSize)} · box ${formatMM(selectedText.frame.width)} × ${formatMM(selectedText.frame.height)} mm` : "No text object selected"}
            </p>
          )}
        </div>
        <div className="stock-badge">
          <strong>◇ {document.formatCode ?? document.sheet.name}</strong>
          <span>{document.formatFamily ? FAMILY_LABELS[document.formatFamily] : `${formatMM(document.sheet.labelWidthMM)} × ${formatMM(document.sheet.labelHeightMM)} mm`}</span>
        </div>
      </header>

      <div className={`editor-workspace ${canvasMode === "page" ? "page-mode" : ""}`}>
        {canvasMode === "label" ? (
          <>
            <LabelEditor
              document={document}
              selectedID={selectedID}
              onSelect={onSelect}
              onFrameChange={onFrameChange}
              onRichTextChange={onRichTextChange}
              onActivateRichEditor={onActivateRichEditor}
              onActivateText={onActivateText}
            />
            <div className="preview-column">
              <div className="preview-pane">
                <div>
                  <div className="preview-heading"><strong>Print Preview</strong><span>Page {pageIndex + 1}</span></div>
                  <p className="microcopy">
                    {queued
                      ? "Blue labels are captured for print. Orange labels preview the next uncaptured setup."
                      : "This is the full-sheet layout that will be exported or printed."}
                  </p>
                </div>
                <PageBoard document={previewDocument} pageIndex={pageIndex} conflictSlots={conflicts} interactive compact draftBatchID={DRAFT_BATCH_ID} onSelectSlot={onSelectSlot} onSelectRange={onSelectSlotRange} />
                <div className="preview-legend">
                  <button onClick={onResetArea}>Reset Area</button>
                  <span className="legend-key"><span className="legend-dot" />{queued ? "Captured" : "Print now"}</span>
                  {queued && <span className="legend-key next"><span className="legend-dot next" />Next</span>}
                  {conflicts.size > 0 && <span className="legend-key conflict"><span className="legend-dot conflict" />Overlap</span>}
                  <span className="legend-summary">
                    {queued
                      ? `captured ${capturedOnPage} · next ${draftSlots.length} · conflicts ${conflicts.size}`
                      : `print ${capturedOnPage} · pages ${pageCount(document)}`}
                  </span>
                </div>
              </div>
              <div className="preview-controls">
                <div className="panel-stack">
                  <NumberingQueue
                    document={document}
                    captureIssue={captureIssue}
                    captureHint={captureHint}
                    canCapture={canCapture}
                    editingCaptureName={editingCaptureName}
                    movingCaptureID={movingCaptureID}
                    movingCaptureName={movingCaptureName}
                    onSerialField={onSerialField}
                    onFillDirection={onFillDirection}
                    onCapture={onCapture}
                    onEditBatch={onEditBatch}
                    onCancelEditBatch={onCancelEditBatch}
                    onBeginMoveBatch={onBeginMoveBatch}
                    onCancelMoveBatch={onCancelMoveBatch}
                    onRemoveBatch={onRemoveBatch}
                    onMoveBatch={onMoveBatch}
                    onResetQueue={onResetQueue}
                    onPrintAll={onPrintAll}
                  />
                </div>
              </div>
            </div>
          </>
        ) : (
          <PageBoard document={previewDocument} pageIndex={pageIndex} conflictSlots={conflicts} interactive draftBatchID={DRAFT_BATCH_ID} onSelectSlot={onSelectSlot} onSelectRange={onSelectSlotRange} />
        )}
      </div>
    </main>
  );
}

function unwrapIPC<T>(result: IPCResult<T>): T | undefined {
  if (result.status === "cancelled") return undefined;
  if (result.status === "error") throw new Error(result.error.message);
  return result.data;
}

interface HistorySnapshot {
  document: LabelDocument;
  pendingPage?: number;
}

interface RegisteredEmbeddedFont {
  face: FontFace;
  names: readonly string[];
}

/** Bookkeeping while a captured batch is checked out of the queue for editing. */
interface CaptureEditSession {
  id: string;
  name: string;
  queueIndex: number;
  startPageIndex: number;
  startSlotOffset: number;
  /** Snapshot from before the edit began, so Cancel restores the queue untouched. */
  previous: HistorySnapshot;
}

function App() {
  const [document, setDocument] = useState<LabelDocument>(() => createInitialDocument());
  const documentRef = useRef(document);
  const catalog = OFFICIAL_FORMATS;
  const [projectPath, setProjectPath] = useState<string>();
  const [selectedID, setSelectedID] = useState<string | undefined>(() => document.elements[0]?.id);
  const [canvasMode, setCanvasMode] = useState<CanvasMode>("label");
  const [theme, setTheme] = useState<AppAppearanceMode>(() => {
    const saved = localStorage.getItem("ilabel2.theme");
    return saved === "light" || saved === "dark" || saved === "system"
      ? saved
      : "light";
  });
  const [quickTextPresets, setQuickTextPresets] = useState<string[]>(() => {
    try {
      const saved = JSON.parse(localStorage.getItem("ilabel2.quickTextPresets") ?? "null") as unknown;
      if (Array.isArray(saved) && saved.every((value) => typeof value === "string")) {
        return [...new Set(saved.map((value) => value.trim()).filter(Boolean))].sort();
      }
    } catch {
      // Use the native defaults below.
    }
    return ["DH5a", "TOP10", "JM110", "BL21(DE3)", "Stbl3"].sort();
  });
  const [newQuickTextPreset, setNewQuickTextPreset] = useState("");
  const [currentPage, setCurrentPage] = useState(0);
  const [pendingPage, setPendingPage] = useState<number | undefined>(0);
  const pendingPageRef = useRef<number | undefined>(0);
  const [status, setStatus] = useState("Ready");
  const [captureIssue, setCaptureIssue] = useState<string>();
  const [captureEdit, setCaptureEdit] = useState<CaptureEditSession>();
  const [captureMove, setCaptureMove] = useState<{ id: string; name: string }>();
  const [busy, setBusy] = useState<string>();
  const [platform, setPlatform] = useState<string>();
  const [localFonts, setLocalFonts] = useState<LocalFontData[]>([]);
  const [loadedEmbeddedFontNames, setLoadedEmbeddedFontNames] = useState<Set<string>>(
    () => new Set(),
  );
  const registeredEmbeddedFonts = useRef(new Map<string, RegisteredEmbeddedFont>());
  const activeRichEditor = useRef<RichTextEditorHandle | null>(null);
  const undoStack = useRef<HistorySnapshot[]>([]);
  const redoStack = useRef<HistorySnapshot[]>([]);
  const lastHistory = useRef<{ key?: string; time: number }>({ time: 0 });
  const [historyVersion, setHistoryVersion] = useState(0);

  useEffect(() => {
    documentRef.current = document;
  }, [document]);

  useEffect(() => {
    activeRichEditor.current = null;
  }, [selectedID]);

  const updatePendingPage = useCallback((value?: number) => {
    const normalized = value === undefined ? undefined : Math.max(0, Math.trunc(value));
    pendingPageRef.current = normalized;
    setPendingPage(normalized);
  }, []);

  useEffect(() => {
    const { printerPassword: _discardedPassword, ...machineSafeSettings } = document.printAutomation;
    void _discardedPassword;
    localStorage.setItem("ilabel2.printAutomation", JSON.stringify(machineSafeSettings));
  }, [document.printAutomation]);

  useEffect(() => {
    window.iLabelDesktop.getOSInfo().then((result) => {
      if (result.status === "success") setPlatform(result.data.platform);
    }).catch(() => undefined);
  }, []);

  useEffect(() => {
    let cancelled = false;
    window.queryLocalFonts?.()
      .then((fonts) => {
        if (!cancelled) setLocalFonts(fonts);
      })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    const fonts = document.embeddedFonts ?? [];
    let cancelled = false;
    const requests: Array<{
      key: string;
      family: string;
      names: string[];
      source: ArrayBuffer;
      descriptors: FontFaceDescriptors;
    }> = [];
    for (const font of fonts) {
      if (!font.data || font.data.length > 48 * 1024 * 1024) continue;
      const fingerprint = fontDataFingerprint(font.data);
      if (!fingerprint) continue;
      const lowerName = font.postScriptName.toLocaleLowerCase();
      const descriptors: FontFaceDescriptors = {
        weight: /(?:bold|semibold|demibold|black|heavy)/i.test(lowerName) ? "700" : "400",
        style: /(?:italic|oblique)/i.test(lowerName) ? "italic" : "normal",
      };
      let source: ArrayBuffer;
      try {
        source = embeddedFontFaceSource(font.data, font.postScriptName);
      } catch {
        continue;
      }
      const names = [font.familyName, font.postScriptName]
        .map((name) => name.trim().toLocaleLowerCase())
        .filter(Boolean);
      for (const rawFamily of new Set([font.familyName, font.postScriptName])) {
        const family = rawFamily.trim();
        if (!family) continue;
        requests.push({
          key: `${family}\u0000${font.postScriptName}\u0000${fingerprint}`,
          family,
          names,
          source,
          descriptors,
        });
      }
    }

    const activeKeys = new Set(requests.map((request) => request.key));
    let removedFace = false;
    for (const [key, registered] of registeredEmbeddedFonts.current) {
      if (activeKeys.has(key)) continue;
      globalThis.document.fonts.delete(registered.face);
      registeredEmbeddedFonts.current.delete(key);
      removedFace = true;
    }

    const publishLoadedNames = (): void => {
      const names = new Set<string>();
      for (const key of activeKeys) {
        const registered = registeredEmbeddedFonts.current.get(key);
        if (registered) {
          for (const name of registered.names) names.add(name);
        }
      }
      setLoadedEmbeddedFontNames(names);
    };

    const loads = requests
      .filter((request) => !registeredEmbeddedFonts.current.has(request.key))
      .map(async (request) => {
        const face = new FontFace(
          request.family,
          request.source,
          request.descriptors,
        );
        const loaded = await face.load();
        if (cancelled) return false;
        globalThis.document.fonts.add(loaded);
        registeredEmbeddedFonts.current.set(request.key, {
          face: loaded,
          names: request.names,
        });
        return true;
      });

    if (loads.length === 0) {
      publishLoadedNames();
      if (removedFace) setDocument((current) => ({ ...current }));
    } else {
      void Promise.allSettled(loads).then((results) => {
        if (cancelled) return;
        publishLoadedNames();
        if (removedFace || results.some((result) => result.status === "fulfilled" && result.value)) {
          setDocument((current) => ({ ...current }));
        }
      });
    }
    return () => { cancelled = true; };
  }, [document.embeddedFonts]);

  useEffect(() => () => {
    for (const registered of registeredEmbeddedFonts.current.values()) {
      globalThis.document.fonts.delete(registered.face);
    }
    registeredEmbeddedFonts.current.clear();
  }, []);

  const fontFamilies = useMemo(() => {
    const names = new Set(COMMON_FONTS);
    for (const font of localFonts) {
      if (font.family.trim()) names.add(font.family.trim());
    }
    return [...names].sort((left, right) => left.localeCompare(right));
  }, [localFonts]);
  const availableFontNames = useMemo(() => {
    const names = new Set<string>(["serif", "sans-serif", "monospace", "system-ui"]);
    for (const font of localFonts) {
      names.add(font.family.toLocaleLowerCase());
      names.add(font.fullName.toLocaleLowerCase());
      names.add(font.postscriptName.toLocaleLowerCase());
    }
    for (const name of loadedEmbeddedFontNames) names.add(name);
    return names;
  }, [loadedEmbeddedFontNames, localFonts]);

  useEffect(() => {
    localStorage.setItem("ilabel2.theme", theme);
    void window.iLabelDesktop.setTheme(theme);
    const root = globalThis.document.documentElement;
    if (theme !== "system") {
      root.dataset.theme = theme;
      return;
    }
    const media = globalThis.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => { root.dataset.theme = media.matches ? "dark" : "light"; };
    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [theme]);

  useEffect(() => {
    localStorage.setItem("ilabel2.quickTextPresets", JSON.stringify(quickTextPresets));
  }, [quickTextPresets]);

  const recordHistory = useCallback((previous: LabelDocument, key?: string) => {
    const now = Date.now();
    const coalesce = Boolean(key) && lastHistory.current.key === key && now - lastHistory.current.time < 650;
    lastHistory.current = { key, time: now };
    if (!coalesce) {
      undoStack.current.push({
        document: clone(previous),
        pendingPage: pendingPageRef.current,
      });
      if (undoStack.current.length > 100) undoStack.current.shift();
      redoStack.current = [];
      setHistoryVersion((value) => value + 1);
    }
  }, []);

  const replaceDocument = useCallback((next: LabelDocument, message?: string, record = true, key?: string) => {
    const previous = documentRef.current;
    if (record) recordHistory(previous, key);
    const normalized = normalizeDocument(next);
    documentRef.current = normalized;
    setDocument(normalized);
    if (message) setStatus(message);
  }, [recordHistory]);

  const mutateDocument = useCallback((
    update: (draft: LabelDocument) => void,
    key?: string,
    message?: string,
  ) => {
    const previous = documentRef.current;
    recordHistory(previous, key);
    const draft = clone(previous);
    update(draft);
    const normalized = normalizeDocument(draft);
    documentRef.current = normalized;
    setDocument(normalized);
    if (message) setStatus(message);
  }, [recordHistory]);

  const resetHistory = useCallback(() => {
    undoStack.current = [];
    redoStack.current = [];
    lastHistory.current = { time: 0 };
    setHistoryVersion((value) => value + 1);
  }, []);

  const undo = useCallback(() => {
    const previous = undoStack.current.pop();
    if (!previous) return;
    redoStack.current.push({ document: clone(documentRef.current), pendingPage: pendingPageRef.current });
    documentRef.current = previous.document;
    setDocument(previous.document);
    updatePendingPage(previous.pendingPage);
    setSelectedID((id) => previous.document.elements.some((element) => element.id === id) ? id : previous.document.elements[0]?.id);
    setCaptureEdit(undefined);
    setCaptureMove(undefined);
    setStatus("Undo");
    lastHistory.current = { time: 0 };
    setHistoryVersion((value) => value + 1);
  }, [updatePendingPage]);

  const redo = useCallback(() => {
    const next = redoStack.current.pop();
    if (!next) return;
    undoStack.current.push({ document: clone(documentRef.current), pendingPage: pendingPageRef.current });
    documentRef.current = next.document;
    setDocument(next.document);
    updatePendingPage(next.pendingPage);
    setSelectedID((id) => next.document.elements.some((element) => element.id === id) ? id : next.document.elements[0]?.id);
    setCaptureEdit(undefined);
    setCaptureMove(undefined);
    setStatus("Redo");
    lastHistory.current = { time: 0 };
    setHistoryVersion((value) => value + 1);
  }, [updatePendingPage]);

  const newProject = useCallback(() => {
    const next = createStarterDocument();
    next.printAutomation = clone(documentRef.current.printAutomation ?? DEFAULT_PRINT_AUTOMATION);
    const defaultFormat = catalog.find(
      (format) => format.code === DEFAULT_OFFICIAL_FORMAT_CODE,
    );
    if (defaultFormat) {
      next.title = defaultFormat.code;
      next.sheet = sheetFromFormat(defaultFormat);
      next.elements = [];
      next.formatCode = defaultFormat.code;
      next.formatFamily = defaultFormat.family;
      next.formatSourceURL = defaultFormat.detailURL;
      next.formatPDFTemplateURL = defaultFormat.pdfTemplateURL;
    }
    documentRef.current = next;
    setDocument(next);
    setSelectedID(next.elements[0]?.id);
    setProjectPath(undefined);
    setCurrentPage(0);
    updatePendingPage(0);
    setCaptureIssue(undefined);
    setCaptureEdit(undefined);
    setCaptureMove(undefined);
    resetHistory();
    setStatus("Started a new label project");
  }, [catalog, resetHistory, updatePendingPage]);

  const openProject = useCallback(async () => {
    try {
      const result = unwrapIPC(await window.iLabelDesktop.openProject());
      if (!result) return;
      const loaded = await normalizeDocumentImages(
        normalizeDocument(JSON.parse(result.text)),
      );
      const machineSettings = documentRef.current.printAutomation;
      if (machineSettings.printerSSID.trim()) {
        loaded.printAutomation = {
          ...loaded.printAutomation,
          ...clone(machineSettings),
          printerPassword: machineSettings.printerPassword || loaded.printAutomation.printerPassword,
        };
      }
      documentRef.current = loaded;
      setDocument(loaded);
      setProjectPath(result.path);
      setSelectedID(loaded.elements[0]?.id);
      setCurrentPage(0);
      updatePendingPage((loaded.printQueue?.length ?? 0) > 0 ? undefined : 0);
      setCaptureIssue(undefined);
      setCaptureEdit(undefined);
      setCaptureMove(undefined);
      resetHistory();
      setStatus(`Opened ${result.name}`);
    } catch (error) {
      setStatus(`Open failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }, [resetHistory, updatePendingPage]);

  const saveProject = useCallback(async () => {
    try {
      activeRichEditor.current?.flush();
      setBusy("Collecting document fonts…");
      const current = await documentWithCollectedFonts(
        documentRef.current,
        localFonts,
      );
      const result = unwrapIPC(await window.iLabelDesktop.saveProject({
        data: JSON.stringify(current, null, 2),
        suggestedName: `${safeFilename(current.title)}.ilabel.json`,
        existingPath: projectPath,
      }));
      if (!result) return;
      setProjectPath(result.path);
      setStatus(`Saved ${result.name}`);
    } catch (error) {
      setStatus(`Save failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(undefined);
    }
  }, [localFonts, projectPath]);

  const importCSV = useCallback(async () => {
    try {
      const result = unwrapIPC(await window.iLabelDesktop.openCSV());
      if (!result) return;
      const table = parseCSV(result.text);
      mutateDocument((draft) => { draft.dataTable = table; }, undefined, `Loaded ${table.rows.length} rows from ${result.name}`);
      setCurrentPage(0);
    } catch (error) {
      setStatus(`CSV import failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }, [mutateDocument]);

  const applyPreset = useCallback((sheet: SheetTemplate) => {
    if ((documentRef.current.printQueue?.length ?? 0) > 0) return;
    mutateDocument((draft) => {
      draft.sheet = clone(sheet);
      delete draft.formatCode;
      delete draft.formatFamily;
      delete draft.formatSourceURL;
      delete draft.formatPDFTemplateURL;
    }, undefined, `Applied preset: ${sheet.name}`);
  }, [mutateDocument]);

  const applyFormat = useCallback((format: OfficialFormatDefinition) => {
    if ((documentRef.current.printQueue?.length ?? 0) > 0) return;
    const shouldResetArtwork = documentRef.current.elements.length === 0 || hasStarterArtwork(documentRef.current);
    mutateDocument((draft) => {
      draft.sheet = sheetFromFormat(format);
      draft.formatCode = format.code;
      draft.formatFamily = format.family;
      draft.formatSourceURL = format.detailURL;
      draft.formatPDFTemplateURL = format.pdfTemplateURL;
      if (shouldResetArtwork) draft.elements = [];
      if (!draft.title || draft.title === "iLabel2Mac Demo") draft.title = format.code;
    }, undefined, `Applied official format: ${format.code}`);
    if (shouldResetArtwork) setSelectedID(undefined);
  }, [mutateDocument]);

  const addElement = useCallback(async (type: ElementType) => {
    try {
      let image: { name: string; base64: string } | undefined;
      if (type === "image") {
        const result = unwrapIPC(await window.iLabelDesktop.openImage());
        if (!result) return;
        image = {
          name: result.name.replace(/\.[^.]+$/, ""),
          base64: await normalizeImportedImage(result.base64, result.mime),
        };
      }
      const current = documentRef.current;
      const index = current.elements.filter((element) => element.type === type).length + 1;
      const element = makeElement(type, index);
      if (type === "text") {
        const width = current.sheet.shape === "circle" ? current.sheet.labelWidthMM : Math.max(5, current.sheet.labelWidthMM * 0.9);
        const height = current.sheet.shape === "circle" ? current.sheet.labelHeightMM : Math.max(5, current.sheet.labelHeightMM * 0.78);
        element.frame = {
          x: Math.max(0, (current.sheet.labelWidthMM - width) / 2),
          y: Math.max(0, (current.sheet.labelHeightMM - height) / 2),
          width,
          height,
        };
        element.content = current.serial.mode === "rangedSets" ? "{{serial}}\n{{date}}" : "{{date}}";
        element.fontSize = 3.5;
        element.isBold = false;
        element.usesCircularTextFlow = current.sheet.shape === "circle";
      }
      if (type !== "text") {
        element.frame.width = Math.min(element.frame.width, current.sheet.labelWidthMM);
        element.frame.height = Math.min(element.frame.height, current.sheet.labelHeightMM);
        element.frame.x = Math.max(0, Math.min(element.frame.x, current.sheet.labelWidthMM - element.frame.width));
        element.frame.y = Math.max(0, Math.min(element.frame.y, current.sheet.labelHeightMM - element.frame.height));
      }
      if (image) {
        element.name = image.name;
        element.imageData = image.base64;
      }
      mutateDocument((draft) => { draft.elements.push(element); }, undefined, `Added ${elementTypeLabel(type)}`);
      setSelectedID(element.id);
      return element.id;
    } catch (error) {
      setStatus(`Image import failed: ${error instanceof Error ? error.message : String(error)}`);
      return undefined;
    }
  }, [mutateDocument]);

  /* "Click the label and type", same as the macOS edition: focus the selected
     text element, else the first one, else create one — so a first click on
     the empty label always lands somewhere typing works. */
  const activatePrimaryText = useCallback(async (): Promise<string | undefined> => {
    const current = documentRef.current;
    const chosen = current.elements.find((el) => el.id === selectedID && el.type === "text")
      ?? current.elements.find((el) => el.type === "text");
    if (chosen) {
      setSelectedID(chosen.id);
      return chosen.id;
    }
    return addElement("text");
  }, [selectedID, addElement]);

  const selected = document.elements.find((element) => element.id === selectedID);
  const hasQueuedCaptures = (document.printQueue?.length ?? 0) > 0;
  const canCapture = document.elements.length > 0 && (!hasQueuedCaptures || pendingPage !== undefined);
  const captureHint = hasQueuedCaptures && pendingPage === undefined
    ? "Click an empty label position to stage the next capture."
    : undefined;
  const previewDocument = useMemo(() => {
    if ((document.printQueue?.length ?? 0) === 0 || document.elements.length === 0 || pendingPage === undefined) return document;
    try {
      return captureBatch(document, pendingPage, {
        id: DRAFT_BATCH_ID,
        name: "Current setup preview",
      });
    } catch {
      return document;
    }
  }, [document, pendingPage]);

  const updateSelected = useCallback((update: (element: LabelElement) => void, key?: string) => {
    if (!selectedID) return;
    mutateDocument((draft) => {
      const element = draft.elements.find((candidate) => candidate.id === selectedID);
      if (element) {
        const portableTextStyleBefore = JSON.stringify({
          content: element.content,
          fontSize: element.fontSize,
          fontName: element.fontName,
          isBold: element.isBold,
          isItalic: element.isItalic,
          isUnderline: element.isUnderline,
        });
        update(element);
        const portableTextStyleAfter = JSON.stringify({
          content: element.content,
          fontSize: element.fontSize,
          fontName: element.fontName,
          isBold: element.isBold,
          isItalic: element.isItalic,
          isUnderline: element.isUnderline,
        });
        if (portableTextStyleBefore !== portableTextStyleAfter) {
          element.richTextRTF = undefined;
        }
      }
    }, key);
  }, [mutateDocument, selectedID]);

  const chooseImage = useCallback(async () => {
    if (!selectedID) return;
    try {
      const result = unwrapIPC(await window.iLabelDesktop.openImage());
      if (!result) return;
      const normalizedImage = await normalizeImportedImage(result.base64, result.mime);
      updateSelected((element) => {
        if (element.type !== "image") return;
        element.imageData = normalizedImage;
        element.name = result.name.replace(/\.[^.]+$/, "");
      });
      setStatus(`Placed image: ${result.name}`);
    } catch (error) {
      setStatus(`Image import failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }, [selectedID, updateSelected]);

  const updateRichText = useCallback((
    id: string,
    content: string,
    richTextRTF: string | undefined,
  ) => {
    mutateDocument((draft) => {
      const element = draft.elements.find((candidate) => candidate.id === id);
      if (!element || element.type !== "text") return;
      element.content = content;
      element.richTextRTF = richTextRTF;
    }, `rich-text-${id}`);
  }, [mutateDocument]);

  const applyTextStyleAction = useCallback((action: RichTextAction) => {
    if (activeRichEditor.current?.applyAction(action)) {
      setStatus("Applied style to the text selection");
      return;
    }
    if (!selectedID) return;
    mutateDocument((draft) => {
      const element = draft.elements.find((candidate) => candidate.id === selectedID);
      if (!element || element.type !== "text") return;
      const rich = elementRichText(element);
      const runs = rich.runs.map((run) => ({ ...run }));
      switch (action.kind) {
        case "bold":
          runs.forEach((run) => { run.bold = !run.bold; });
          element.isBold = runs.length > 0
            ? runs.every((run) => run.bold)
            : !element.isBold;
          break;
        case "italic":
          runs.forEach((run) => { run.italic = !run.italic; });
          element.isItalic = runs.length > 0
            ? runs.every((run) => run.italic)
            : !element.isItalic;
          break;
        case "underline":
          runs.forEach((run) => { run.underline = !run.underline; });
          element.isUnderline = runs.length > 0
            ? runs.every((run) => run.underline)
            : !element.isUnderline;
          break;
        case "fontFamily":
          element.fontName = action.value;
          runs.forEach((run) => { run.fontName = action.value; });
          break;
        case "fontSize": {
          const previousSize = Math.max(0.1, element.fontSize);
          const ratio = action.value / previousSize;
          element.fontSize = action.value;
          runs.forEach((run) => {
            run.fontSize = Math.max(0.5, (run.fontSize ?? previousSize) * ratio);
          });
          break;
        }
        case "foreground":
          element.foreground = { ...action.value };
          runs.forEach((run) => { run.foreground = { ...action.value }; });
          break;
        case "highlight":
          runs.forEach((run) => {
            if (action.value) run.background = { ...action.value };
            else delete run.background;
          });
          break;
      }
      element.richTextRTF = element.content.length > 0
        ? serializeBase64RTF(element.content, runs)
        : undefined;
    }, undefined, "Applied text style");
  }, [mutateDocument, selectedID]);

  const insertToken = useCallback((token: string) => {
    if (activeRichEditor.current?.insertText(token)) return;
    if (!selectedID) return;
    mutateDocument((draft) => {
      const element = draft.elements.find((candidate) => candidate.id === selectedID);
      if (!element) return;
      if (element.type === "text") {
        const rich = elementRichText(element);
        const start = element.content.length;
        const style = rich.runs.at(-1) ?? {
          start,
          length: 0,
          fontName: element.fontName,
          fontSize: element.fontSize,
          bold: element.isBold,
          italic: element.isItalic,
          underline: element.isUnderline,
          foreground: element.foreground,
        };
        element.content += token;
        element.richTextRTF = serializeBase64RTF(element.content, [
          ...rich.runs,
          { ...style, start, length: token.length },
        ]);
      } else if (element.type === "qrCode" || element.type === "code128") {
        element.content += token;
      }
    }, "insert-token");
  }, [mutateDocument, selectedID]);

  const saveQuickTextPreset = useCallback(() => {
    const value = newQuickTextPreset.trim();
    if (!value) return;
    setQuickTextPresets((current) =>
      current.includes(value) ? current : [...current, value].sort());
    setNewQuickTextPreset("");
    setStatus(`Saved preset: ${value}`);
  }, [newQuickTextPreset]);

  const removeQuickTextPreset = useCallback((value: string) => {
    setQuickTextPresets((current) => current.filter((preset) => preset !== value));
    setStatus(`Removed preset: ${value}`);
  }, []);

  const duplicateSelected = useCallback(() => {
    if (!selected) return;
    const copy = clone(selected);
    copy.id = crypto.randomUUID();
    copy.name += " Copy";
    copy.frame.x += 3;
    copy.frame.y += 3;
    mutateDocument((draft) => { draft.elements.push(copy); }, undefined, `Duplicated ${elementTypeLabel(copy.type).toLocaleLowerCase()}`);
    setSelectedID(copy.id);
  }, [mutateDocument, selected]);

  const deleteSelected = useCallback(() => {
    if (!selectedID) return;
    const name = selected?.name ?? "object";
    mutateDocument((draft) => { draft.elements = draft.elements.filter((element) => element.id !== selectedID); }, undefined, `Deleted ${name}`);
    const remaining = documentRef.current.elements.filter((element) => element.id !== selectedID);
    setSelectedID(remaining.at(-1)?.id);
  }, [mutateDocument, selected?.name, selectedID]);

  const fitText = useCallback(() => {
    updateSelected((element) => {
      if (element.type !== "text") return;
      if (documentRef.current.sheet.shape === "circle") {
        element.frame = { x: 0, y: 0, width: documentRef.current.sheet.labelWidthMM, height: documentRef.current.sheet.labelHeightMM };
        element.usesCircularTextFlow = true;
      } else {
        element.frame.x = Math.max(0, (documentRef.current.sheet.labelWidthMM - element.frame.width) / 2);
        element.frame.y = Math.max(0, (documentRef.current.sheet.labelHeightMM - element.frame.height) / 2);
        element.usesCircularTextFlow = false;
      }
      element.textAlignment = "center";
    });
    setStatus(documentRef.current.sheet.shape === "circle" ? "Fitted text to the full circular label" : "Centered text in the label");
  }, [updateSelected]);

  const repositionCaptureTo = useCallback((slotIndex: number) => {
    if (!captureMove) return;
    try {
      const targetPage = Math.max(0, currentPage);
      const next = repositionBatch(documentRef.current, captureMove.id, slotIndex, targetPage);
      replaceDocument(next, `Moved “${captureMove.name}” to page ${targetPage + 1}, slot ${slotIndex + 1}.`, true);
      setCaptureMove(undefined);
      setCaptureIssue(undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setCaptureIssue(message);
      setStatus(message);
    }
  }, [captureMove, currentPage, replaceDocument]);

  const selectSlot = useCallback((slotIndex: number) => {
    if (captureMove) {
      repositionCaptureTo(slotIndex);
      return;
    }
    try {
      const targetPage = Math.max(0, currentPage);
      const payload = renderPayload(documentRef.current, slotIndex, targetPage);
      if (payload.batchID) throw new Error(`Page ${targetPage + 1}, slot ${slotIndex + 1} is already captured.`);
      const next = selectPlacementStart(documentRef.current, slotIndex, targetPage);
      replaceDocument(next, `Start position: page ${targetPage + 1}, slot ${slotIndex + 1}`, true);
      updatePendingPage(targetPage);
      const conflict = (next.printQueue?.length ?? 0) > 0
        ? firstPlacementConflict(next, draftPlacementPlan(next, targetPage))
        : null;
      setCaptureIssue(conflict
        ? `Page ${conflict.pageIndex + 1}, slot ${conflict.slotIndex + 1} is already captured by “${conflict.existingBatchName}”.`
        : undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setCaptureIssue(message);
      setStatus(message);
    }
  }, [captureMove, currentPage, repositionCaptureTo, replaceDocument, updatePendingPage]);

  const selectSlotRange = useCallback((startSlot: number, endSlot: number) => {
    if (captureMove) {
      repositionCaptureTo(startSlot);
      return;
    }
    try {
      const targetPage = Math.max(0, currentPage);
      const next = selectPlacementRect(documentRef.current, startSlot, endSlot);
      replaceDocument(
        next,
        `Selected print area on page ${targetPage + 1}`,
        true,
        "placement-range",
      );
      updatePendingPage(targetPage);
      const conflict = (next.printQueue?.length ?? 0) > 0
        ? firstPlacementConflict(next, draftPlacementPlan(next, targetPage))
        : null;
      setCaptureIssue(conflict
        ? `Page ${conflict.pageIndex + 1}, slot ${conflict.slotIndex + 1} is already captured by “${conflict.existingBatchName}”.`
        : undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setCaptureIssue(message);
      setStatus(message);
    }
  }, [captureMove, currentPage, repositionCaptureTo, replaceDocument, updatePendingPage]);

  const resetPlacementArea = useCallback(() => {
    replaceDocument(
      clearPlacementSelection(documentRef.current),
      "Reset print area",
      true,
    );
    updatePendingPage(currentPage);
    setCaptureIssue(undefined);
  }, [currentPage, replaceDocument, updatePendingPage]);

  const captureCurrent = useCallback(() => {
    try {
      const current = documentRef.current;
      if ((current.printQueue?.length ?? 0) > 0 && pendingPage === undefined) {
        throw new Error("Choose an empty start position for the next capture.");
      }
      const quantity = currentSetupLabelCount(current);
      const capturePage = pendingPage ?? captureEdit?.startPageIndex ?? currentPage;
      const options: CaptureBatchOptions = {};
      if (captureEdit) {
        options.insertIndex = captureEdit.queueIndex;
        if (!current.printQueue?.some((batch) => batch.id === captureEdit.id)) {
          options.id = captureEdit.id;
        }
        if (capturePage === captureEdit.startPageIndex) {
          options.startSlotOffset = captureEdit.startSlotOffset;
        }
      }
      const next = captureBatch(current, capturePage, options);
      replaceDocument(
        next,
        captureEdit
          ? `Updated “${captureEdit.name}” with ${quantity} label(s).`
          : `Captured ${quantity} label(s). Choose another empty position for the next capture.`,
        true,
      );
      setCaptureEdit(undefined);
      updatePendingPage(undefined);
      setCaptureIssue(undefined);
    } catch (error) {
      const message = error instanceof DocumentCoreError || error instanceof Error ? error.message : String(error);
      setCaptureIssue(message);
      setStatus(message);
    }
  }, [captureEdit, currentPage, pendingPage, replaceDocument, updatePendingPage]);

  const editCapturedBatch = useCallback((id: string) => {
    if (captureEdit) {
      const message = `Finish editing “${captureEdit.name}” first — Update Capture or Cancel Edit.`;
      setCaptureIssue(message);
      setStatus(message);
      return;
    }
    setCaptureMove(undefined);
    try {
      const previous: HistorySnapshot = {
        document: clone(documentRef.current),
        pendingPage: pendingPageRef.current,
      };
      const { document: next, batch, queueIndex } = beginBatchEdit(documentRef.current, id);
      replaceDocument(next, `Editing “${batch.name}”. Adjust the setup, then Update Capture.`, true);
      setSelectedID(next.elements[0]?.id);
      setCaptureEdit({
        id: batch.id,
        name: batch.name,
        queueIndex,
        startPageIndex: batch.startPageIndex ?? 0,
        startSlotOffset: batch.startSlotOffset ?? 0,
        previous,
      });
      const page = batch.startPageIndex ?? 0;
      updatePendingPage(page);
      setCurrentPage(page);
      setCaptureIssue(undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setCaptureIssue(message);
      setStatus(message);
    }
  }, [captureEdit, replaceDocument, updatePendingPage]);

  const beginMoveCapturedBatch = useCallback((id: string) => {
    if (captureEdit) {
      const message = `Finish editing “${captureEdit.name}” first — Update Capture or Cancel Edit.`;
      setCaptureIssue(message);
      setStatus(message);
      return;
    }
    if (captureMove?.id === id) {
      setCaptureMove(undefined);
      setStatus("Cancelled the capture move");
      return;
    }
    const batch = documentRef.current.printQueue?.find((candidate) => candidate.id === id);
    if (!batch) return;
    setCaptureMove({ id, name: batch.name });
    setCaptureIssue(undefined);
    setStatus(`Click an empty label position to move “${batch.name}”. Use Prev/Next to reach another page.`);
  }, [captureEdit, captureMove]);

  const cancelMoveCapturedBatch = useCallback(() => {
    if (!captureMove) return;
    setCaptureMove(undefined);
    setStatus("Cancelled the capture move");
  }, [captureMove]);

  const cancelCaptureEdit = useCallback(() => {
    if (!captureEdit) return;
    replaceDocument(
      captureEdit.previous.document,
      `Returned “${captureEdit.name}” to the queue unchanged.`,
      true,
    );
    updatePendingPage(captureEdit.previous.pendingPage);
    setCaptureEdit(undefined);
    setCaptureIssue(undefined);
  }, [captureEdit, replaceDocument, updatePendingPage]);

  const removeCapturedBatch = useCallback((id: string) => {
    const next = removeBatch(documentRef.current, id);
    replaceDocument(next, "Removed capture from the queue", true);
    if ((next.printQueue?.length ?? 0) === 0) updatePendingPage(currentPage);
    setCaptureIssue(undefined);
    setCaptureMove((current) => (current?.id === id ? undefined : current));
  }, [currentPage, replaceDocument, updatePendingPage]);

  const moveCapturedBatch = useCallback((id: string, offset: number) => {
    replaceDocument(moveBatch(documentRef.current, id, offset), "Reordered capture queue", true);
  }, [replaceDocument]);

  const resetQueue = useCallback(() => {
    replaceDocument(clearBatches(documentRef.current), "Reset the capture queue", true);
    updatePendingPage(0);
    setCurrentPage(0);
    setCaptureIssue(undefined);
    setCaptureEdit(undefined);
    setCaptureMove(undefined);
  }, [replaceDocument, updatePendingPage]);

  const changeFillDirection = useCallback((value: LabelDocument["placement"]["fillDirection"]) => {
    replaceDocument(
      updatePlacementFillDirection(documentRef.current, value),
      undefined,
      true,
      "fill-direction",
    );
  }, [replaceDocument]);

  const printSettingsRequest = useCallback(() => {
    const settings = documentRef.current.printAutomation;
    const service = settings.wifiService.trim();
    return {
      ssid: settings.printerSSID,
      password: settings.printerPassword || undefined,
      interfaceName: service && (platform === "win32" || service !== "Wi-Fi") ? service : undefined,
      restoreSSID: settings.restoreSSID?.trim() || undefined,
      timeoutMs: 30_000,
    };
  }, [platform]);

  const testWiFi = useCallback(async () => {
    const settings = documentRef.current.printAutomation;
    if (!settings.printerSSID.trim()) {
      setStatus("Enter the printer SSID first");
      return;
    }
    setBusy(`Testing ${settings.printerSSID}…`);
    try {
      const result = unwrapIPC(await window.iLabelDesktop.wifi.test({ ...printSettingsRequest(), restoreAfterTest: settings.reconnectToPreviousWiFi }));
      if (result) {
        setStatus(result.restoreError
          ? `Connected to ${result.targetSSID}, but restore failed: ${result.restoreError}`
          : result.restored
            ? `Connected to ${result.targetSSID} and restored Wi-Fi`
            : `Connected to ${result.targetSSID}`);
      }
    } catch (error) {
      setStatus(`Wi-Fi test failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(undefined);
    }
  }, [printSettingsRequest]);

  const exportPDF = useCallback(async (allPages: boolean) => {
    const snapshot = clone(documentRef.current);
    const pages = allPages
      ? Array.from({ length: pageCount(snapshot) }, (_, index) => index)
      : [Math.min(currentPage, pageCount(snapshot) - 1)];
    setBusy(allPages ? "Preparing all pages…" : "Preparing PDF…");
    try {
      const result = unwrapIPC(await window.iLabelDesktop.exportPDF({
        html: renderPrintHTML(snapshot, pages, { title: snapshot.title }),
        pageWidthMM: snapshot.sheet.pageWidthMM,
        pageHeightMM: snapshot.sheet.pageHeightMM,
        suggestedName: allPages
          ? `${safeFilename(snapshot.title)}-all-${pages.length}pages.pdf`
          : `${safeFilename(snapshot.title)}-page-${pages[0] + 1}.pdf`,
      }));
      if (result) setStatus(`Exported PDF: ${result.name}`);
    } catch (error) {
      setStatus(`PDF export failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(undefined);
    }
  }, [currentPage]);

  const exportPNG = useCallback(async () => {
    const snapshot = clone(documentRef.current);
    const page = Math.min(currentPage, pageCount(snapshot) - 1);
    setBusy("Rendering 720 DPI PNG…");
    try {
      const dataURL = await svgToPNG(renderPageSVG(snapshot, page), snapshot.sheet.pageWidthMM, snapshot.sheet.pageHeightMM);
      const result = unwrapIPC(await window.iLabelDesktop.savePNG({
        base64: dataURL,
        suggestedName: `${safeFilename(snapshot.title)}-page-${page + 1}.png`,
      }));
      if (result) setStatus(`Exported PNG: ${result.name}`);
    } catch (error) {
      setStatus(`PNG export failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(undefined);
    }
  }, [currentPage]);

  const printDocument = useCallback(async (allPages: boolean) => {
    const snapshot = clone(documentRef.current);
    const pages = allPages
      ? Array.from({ length: pageCount(snapshot) }, (_, index) => index)
      : [Math.min(currentPage, pageCount(snapshot) - 1)];
    setBusy("Preparing print job…");
    let printSubmitted = false;
    let transmissionTimedOut = false;
    try {
      const printResult = unwrapIPC(await window.iLabelDesktop.print({
        html: renderPrintHTML(snapshot, pages, { title: snapshot.title }),
        pageWidthMM: snapshot.sheet.pageWidthMM,
        pageHeightMM: snapshot.sheet.pageHeightMM,
        jobTitle: snapshot.title,
      }));
      if (!printResult) return;
      printSubmitted = true;
      const settings = snapshot.printAutomation;
      if (settings.enabled && settings.printerSSID.trim()) {
        const network = await coordinatePrinterNetwork(
          settings,
          printResult.baselineJobIDs,
          {
            waitForDrain: async (baselineJobIDs, timeoutMs) => {
              const result = unwrapIPC(await window.iLabelDesktop.waitForPrintDrain({
                baselineJobIDs: [...baselineJobIDs],
                timeoutMs,
              }));
              return result ?? { supported: false, drained: false };
            },
            switchToPrinter: async () =>
              unwrapIPC(await window.iLabelDesktop.wifi.switch(printSettingsRequest())) ?? {},
            restore: async (sessionToken) => {
              unwrapIPC(await window.iLabelDesktop.wifi.restore(sessionToken));
            },
            sleep: (milliseconds) => new Promise((resolve) =>
              globalThis.setTimeout(resolve, milliseconds)),
          },
          (phase) => {
            const labels = {
              "checking-current-network": "Print queued · checking the current network…",
              "switching-to-printer": `Print still queued · connecting to ${settings.printerSSID}…`,
              "waiting-for-printer": "Printer connected · waiting for the spool job to finish…",
              "restoring-network": "Restoring Wi-Fi…",
            } as const;
            setBusy(labels[phase]);
          },
        );
        if (network.deliveredOnCurrentNetwork) {
          setStatus("Submitted to the printer on the current network");
          return;
        }
        transmissionTimedOut = network.transmissionTimedOut;
      }
      setStatus(transmissionTimedOut
        ? "Print was queued, but the spool job was still active when Wi-Fi was restored"
        : `Submitted ${pages.length} page${pages.length === 1 ? "" : "s"} to the printer`);
    } catch (error) {
      setStatus(`${printSubmitted ? "Print was queued, but Wi-Fi automation failed" : "Print failed"}: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setBusy(undefined);
    }
  }, [currentPage, printSettingsRequest]);

  const totalPages = pageCount(document);
  const navigationPages = Math.max(
    totalPages + (hasQueuedCaptures ? 1 : 0),
    pageCount(previewDocument),
  );
  const safeCurrentPage = Math.min(currentPage, Math.max(0, navigationPages - 1));
  const canUndo = undoStack.current.length > 0;
  const canRedo = redoStack.current.length > 0;
  void historyVersion;

  useEffect(() => {
    setCurrentPage((page) => Math.min(Math.max(0, page), Math.max(0, navigationPages - 1)));
  }, [navigationPages]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const modifier = event.ctrlKey || event.metaKey;
      if (modifier && event.key.toLocaleLowerCase() === "s") {
        event.preventDefault();
        void saveProject();
      } else if (modifier && event.key.toLocaleLowerCase() === "o") {
        event.preventDefault();
        void openProject();
      } else if (modifier && event.key.toLocaleLowerCase() === "z" && !isEditingControl(event.target)) {
        event.preventDefault();
        if (event.shiftKey) redo(); else undo();
      } else if (modifier && event.key.toLocaleLowerCase() === "y" && !isEditingControl(event.target)) {
        event.preventDefault();
        redo();
      } else if ((event.key === "Delete" || event.key === "Backspace") && !isEditingControl(event.target)) {
        event.preventDefault();
        deleteSelected();
      }
    };
    globalThis.addEventListener("keydown", handler);
    return () => globalThis.removeEventListener("keydown", handler);
  }, [deleteSelected, openProject, redo, saveProject, undo]);

  const documentField = useCallback(<K extends keyof LabelDocument>(key: K, value: LabelDocument[K]) => {
    mutateDocument((draft) => { draft[key] = value; }, `document-${String(key)}`);
  }, [mutateDocument]);

  const sheetField = useCallback(<K extends keyof SheetTemplate>(key: K, value: SheetTemplate[K]) => {
    mutateDocument((draft) => {
      draft.sheet[key] = value;
      delete draft.formatCode;
      delete draft.formatFamily;
      delete draft.formatSourceURL;
      delete draft.formatPDFTemplateURL;
    }, `sheet-${String(key)}`);
  }, [mutateDocument]);

  const serialField = useCallback(<K extends keyof LabelDocument["serial"]>(key: K, value: LabelDocument["serial"][K]) => {
    mutateDocument((draft) => { draft.serial[key] = value; }, `serial-${String(key)}`);
  }, [mutateDocument]);

  const printField = useCallback(<K extends keyof LabelDocument["printAutomation"]>(key: K, value: LabelDocument["printAutomation"][K]) => {
    mutateDocument((draft) => { draft.printAutomation[key] = value; }, `print-${String(key)}`);
  }, [mutateDocument]);

  return (
    <div className="app-shell">
      <UpdateBanner />
      <header className="toolbar" aria-label="Application toolbar">
        <div className="toolbar-group">
          <button onClick={newProject}>New</button>
          <button onClick={() => void openProject()}>Open</button>
          <button onClick={() => void saveProject()}>Save</button>
        </div>
        <span className="toolbar-divider" />
        <div className="toolbar-group">
          <button className="icon-button" aria-label="Undo" title="Undo (Ctrl+Z)" disabled={!canUndo} onClick={undo}>↶</button>
          <button className="icon-button" aria-label="Redo" title="Redo (Ctrl+Shift+Z)" disabled={!canRedo} onClick={redo}>↷</button>
        </div>
        <span className="toolbar-divider" />
        <div className="toolbar-group">
          <button onClick={() => void importCSV()}>CSV</button>
          <button onClick={() => void exportPDF(false)}>PDF</button>
          <button disabled={totalPages <= 1} onClick={() => void exportPDF(true)}>PDF·All</button>
          <button onClick={() => void exportPNG()}>PNG</button>
          <button onClick={() => void printDocument((document.printQueue?.length ?? 0) > 0)}>{(document.printQueue?.length ?? 0) > 0 ? "Print Captures" : "Print"}</button>
        </div>
        <span className="toolbar-divider" />
        <div className="toolbar-group">
          <button onClick={() => void addElement("text")}>Text</button>
          <button onClick={() => void addElement("rectangle")}>Shape</button>
          <button onClick={() => void addElement("image")}>Image</button>
          <button onClick={() => void addElement("qrCode")}>QR</button>
          <button onClick={() => void addElement("code128")}>Barcode</button>
        </div>
        <span className="toolbar-divider" />
        <span className="toolbar-label">Canvas</span>
        <div className="toolbar-group segmented canvas-mode-control" aria-label="Canvas mode">
          <button className={canvasMode === "label" ? "active" : ""} onClick={() => setCanvasMode("label")}>Label</button>
          <button className={canvasMode === "page" ? "active" : ""} onClick={() => setCanvasMode("page")}>Page</button>
        </div>
        <span className="toolbar-divider" />
        <span className="toolbar-label">Theme</span>
        <select className="toolbar-theme" aria-label="Theme" value={theme} onChange={(event) => setTheme(event.currentTarget.value as AppAppearanceMode)}>
          <option value="system">System</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
        <span className="toolbar-divider" />
        <div className="toolbar-group">
          <button disabled={safeCurrentPage === 0} onClick={() => setCurrentPage((page) => Math.max(0, page - 1))}>Prev</button>
          <span className="toolbar-page">
            {safeCurrentPage >= totalPages ? `New Page ${safeCurrentPage + 1}` : `Page ${safeCurrentPage + 1} / ${totalPages}`}
          </span>
          <button disabled={safeCurrentPage >= navigationPages - 1} onClick={() => setCurrentPage((page) => Math.min(navigationPages - 1, page + 1))}>Next</button>
        </div>
        <span className="toolbar-status" title={status}>{status}</span>
      </header>

      <div className="main-grid">
        <Sidebar
          document={document}
          catalog={catalog}
          selectedID={selectedID}
          onDocumentField={documentField}
          onSheetField={sheetField}
          onApplyPreset={applyPreset}
          onApplyFormat={applyFormat}
          onSelect={setSelectedID}
          onDuplicate={duplicateSelected}
          onDelete={deleteSelected}
          onInsertToken={insertToken}
        />
        <Editor
          document={document}
          previewDocument={previewDocument}
          pageIndex={safeCurrentPage}
          canvasMode={canvasMode}
          selectedID={selectedID}
          pendingPage={pendingPage}
          captureIssue={captureIssue}
          captureHint={captureHint}
          canCapture={canCapture}
          onSelect={setSelectedID}
          onFrameChange={(id, frame) => {
            mutateDocument((draft) => {
              const element = draft.elements.find((candidate) => candidate.id === id);
              if (element) element.frame = frame;
            }, `drag-${id}`);
          }}
          onRichTextChange={updateRichText}
          onActivateRichEditor={(editor) => { activeRichEditor.current = editor; }}
          onActivateText={activatePrimaryText}
          onSelectSlot={selectSlot}
          onSelectSlotRange={selectSlotRange}
          onResetArea={resetPlacementArea}
          onSerialField={serialField}
          onFillDirection={changeFillDirection}
          editingCaptureName={captureEdit?.name}
          movingCaptureID={captureMove?.id}
          movingCaptureName={captureMove?.name}
          onCapture={captureCurrent}
          onEditBatch={editCapturedBatch}
          onCancelEditBatch={cancelCaptureEdit}
          onBeginMoveBatch={beginMoveCapturedBatch}
          onCancelMoveBatch={cancelMoveCapturedBatch}
          onRemoveBatch={removeCapturedBatch}
          onMoveBatch={moveCapturedBatch}
          onResetQueue={resetQueue}
          onPrintAll={() => void printDocument(true)}
        />
        <Inspector
          document={document}
          selected={selected}
          canvasMode={canvasMode}
          captureIssue={captureIssue}
          captureHint={captureHint}
          canCapture={canCapture}
          fontFamilies={fontFamilies}
          availableFontNames={availableFontNames}
          quickTextPresets={quickTextPresets}
          newQuickTextPreset={newQuickTextPreset}
          onNewQuickTextPreset={setNewQuickTextPreset}
          onSaveQuickTextPreset={saveQuickTextPreset}
          onRemoveQuickTextPreset={removeQuickTextPreset}
          onUpdateSelected={updateSelected}
          onRichTextChange={updateRichText}
          onActivateRichEditor={(editor) => { activeRichEditor.current = editor; }}
          onTextStyleAction={applyTextStyleAction}
          onChooseImage={() => void chooseImage()}
          onFitText={fitText}
          onInsertToken={insertToken}
          onDocumentField={documentField}
          onPrintSettings={printField}
          onTestWiFi={() => void testWiFi()}
          onSerialField={serialField}
          onFillDirection={changeFillDirection}
          editingCaptureName={captureEdit?.name}
          movingCaptureID={captureMove?.id}
          movingCaptureName={captureMove?.name}
          onCapture={captureCurrent}
          onEditBatch={editCapturedBatch}
          onCancelEditBatch={cancelCaptureEdit}
          onBeginMoveBatch={beginMoveCapturedBatch}
          onCancelMoveBatch={cancelMoveCapturedBatch}
          onRemoveBatch={removeCapturedBatch}
          onMoveBatch={moveCapturedBatch}
          onResetQueue={resetQueue}
          onPrintAll={() => void printDocument(true)}
        />
      </div>

      {busy && <div className="busy-overlay" role="status" aria-live="polite"><div className="busy-card">{busy}</div></div>}
    </div>
  );
}

export default App;
