import * as bwipjs from "bwip-js";
import QRCode from "qrcode";

import {
  MM_TO_POINTS_RATIO,
  TEXT_ELEMENT_INSET_X_MM,
  TEXT_ELEMENT_INSET_Y_MM,
} from "../defaults";
import type {
  EmbeddedFont,
  LabelDocument,
  LabelElement,
  LabelShape,
  MergeContext,
  RectMM,
  RGBAColor,
  SerialSettings,
  SlotRenderPayload,
  TextAlignModel,
} from "../types";
import { pageCount, renderPayload } from "./document";
import { standaloneFontFaceBase64 } from "./fontData";
import { resolveTokens } from "./merge";
import {
  resolveElementRichText,
  runStyleAt,
  type ResolvedRichText,
} from "./richText";
import type { RTFStyleRun } from "./rtf";

const SVG_NAMESPACE = "http://www.w3.org/2000/svg";
const WHITE: RGBAColor = { red: 1, green: 1, blue: 1, alpha: 1 };
const GUIDE: RGBAColor = { red: 0.45, green: 0.49, blue: 0.58, alpha: 0.42 };
const DEFAULT_CODE_PADDING_MM = 3;
const QR_QUIET_ZONE_MODULES = 4;
const MAX_RENDERED_SLOTS = 10_000;
const MAX_EMBEDDED_FONT_ENTRIES = 256;
const MAX_EMBEDDED_FONT_FACES = 64;
const MAX_EMBEDDED_FONT_BYTES = 32 * 1024 * 1024;
const MAX_TOTAL_EMBEDDED_FONT_BYTES = 64 * 1024 * 1024;
const MAX_EMBEDDED_FONT_NAME_LENGTH = 256;
const PREVIEW_GUIDE_STROKE_PX = 1.25;
const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
let textMeasurementContext: CanvasRenderingContext2D | null | undefined;

// bwip-js 4 ships `toSVG()` in its browser and Node bundles. The separate
// legacy @types package still omits it, so keep this small compatibility view
// local until consumers can rely exclusively on bwip-js's bundled types.
const bwipSVG = bwipjs as unknown as {
  toSVG(options: {
    bcid: string;
    text: string;
    scale: number;
    height: number;
    includetext: boolean;
    paddingwidth: number;
    paddingheight: number;
    barcolor: string;
  }): string;
};

export interface SVGRenderOptions {
  /** One timestamp is reused for every token on a rendered page/document. */
  now?: Date;
  /** Draw non-printing label outlines for an editor preview. */
  showGuides?: boolean;
  /** Preview one blank staging page immediately after the rendered document. */
  allowEmptyPage?: boolean;
  guideColor?: RGBAColor;
  /** Undefined is opaque white; null leaves the SVG background transparent. */
  backgroundColor?: RGBAColor | null;
  /** Stable prefix for clip-path IDs when several SVGs share one HTML document. */
  idPrefix?: string;
  /** Padding inside QR/Code128 element frames. Defaults to the macOS UI's 3 mm. */
  codePaddingMM?: number;
}

export interface PrintHTMLOptions extends SVGRenderOptions {
  title?: string;
  /** Useful for a dedicated print window; disabled for printToPDF callers. */
  autoPrint?: boolean;
}

interface ResolvedRenderOptions {
  now: Date;
  showGuides: boolean;
  guideColor: RGBAColor;
  backgroundColor: RGBAColor | null;
  idPrefix: string;
  codePaddingMM: number;
}

interface SVGFragment {
  definitions: string[];
  body: string;
}

interface ElementRenderEnvironment {
  document: LabelDocument;
  context: MergeContext;
  serialSettings: SerialSettings;
  options: ResolvedRenderOptions;
  idPrefix: string;
  embeddedFonts: PreparedEmbeddedFonts;
}

interface EmbeddedFontFormat {
  mimeType: "font/ttf" | "font/otf" | "font/woff" | "font/woff2" | "font/collection";
  cssFormat: "truetype" | "opentype" | "woff" | "woff2" | "collection";
}

interface PreparedEmbeddedFontFace extends EmbeddedFontFormat {
  alias: string;
  data: string;
  weight: number;
  italic: boolean;
}

interface PreparedEmbeddedFonts {
  css: string;
  byPostScriptName: ReadonlyMap<string, PreparedEmbeddedFontFace>;
  byFamilyName: ReadonlyMap<string, readonly PreparedEmbeddedFontFace[]>;
}

const NO_EMBEDDED_FONTS: PreparedEmbeddedFonts = {
  css: "",
  byPostScriptName: new Map(),
  byFamilyName: new Map(),
};

interface TextLine {
  text: string;
  start: number;
  length: number;
  x: number;
  baselineY: number;
  availableWidth: number;
  fontSizeMM: number;
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}

function finite(value: number, fallback = 0): number {
  return Number.isFinite(value) ? value : fallback;
}

function number(value: number): string {
  const normalized = Math.abs(finite(value)) < 0.0000005 ? 0 : finite(value);
  return Number(normalized.toFixed(6)).toString();
}

function millimeters(value: number): string {
  return `${number(value)}mm`;
}

function sanitizeXML(value: string): string {
  // XML 1.0 excludes most C0 controls even when escaped.
  return value.replace(
    /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g,
    "\uFFFD",
  );
}

export function escapeXML(value: string): string {
  return sanitizeXML(String(value))
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function hashString(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}

function xmlID(value: string): string {
  const readable = value
    .normalize("NFKD")
    .replace(/[^A-Za-z0-9_.:-]+/g, "-")
    .replace(/^[^A-Za-z_]+/, "")
    .slice(0, 56);
  return `${readable || "ilabel"}-${hashString(value)}`;
}

function cssString(value: string): string {
  let escaped = "";
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0xfffd;
    if (
      codePoint < 0x20 ||
      codePoint === 0x7f ||
      character === '"' ||
      character === "\\" ||
      character === "<" ||
      character === ">" ||
      character === "&"
    ) {
      escaped += `\\${codePoint.toString(16)} `;
    } else {
      escaped += character;
    }
  }
  return `"${escaped}"`;
}

function normalizedFontName(value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0) return null;
  if (value.length > MAX_EMBEDDED_FONT_NAME_LENGTH) return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  try {
    return trimmed.normalize("NFKC").toLowerCase();
  } catch {
    return null;
  }
}

function base64Prefix(value: string, byteCount: number): number[] {
  const output: number[] = [];
  for (let index = 0; index < value.length && output.length < byteCount; index += 4) {
    const first = BASE64_ALPHABET.indexOf(value[index] ?? "");
    const second = BASE64_ALPHABET.indexOf(value[index + 1] ?? "");
    const third = BASE64_ALPHABET.indexOf(value[index + 2] ?? "");
    const fourth = BASE64_ALPHABET.indexOf(value[index + 3] ?? "");
    if (first < 0 || second < 0) break;
    output.push((first << 2) | (second >> 4));
    if (third < 0 || output.length >= byteCount) continue;
    output.push(((second & 0x0f) << 4) | (third >> 2));
    if (fourth < 0 || output.length >= byteCount) continue;
    output.push(((third & 0x03) << 6) | fourth);
  }
  return output.slice(0, byteCount);
}

function embeddedFontFormat(data: string): EmbeddedFontFormat | null {
  const signature = base64Prefix(data, 4);
  if (signature.length !== 4) return null;
  const [first, second, third, fourth] = signature;
  if (
    (first === 0x00 && second === 0x01 && third === 0x00 && fourth === 0x00) ||
    (first === 0x74 && second === 0x72 && third === 0x75 && fourth === 0x65)
  ) {
    return { mimeType: "font/ttf", cssFormat: "truetype" };
  }
  if (first === 0x4f && second === 0x54 && third === 0x54 && fourth === 0x4f) {
    return { mimeType: "font/otf", cssFormat: "opentype" };
  }
  if (first === 0x77 && second === 0x4f && third === 0x46 && fourth === 0x46) {
    return { mimeType: "font/woff", cssFormat: "woff" };
  }
  if (first === 0x77 && second === 0x4f && third === 0x46 && fourth === 0x32) {
    return { mimeType: "font/woff2", cssFormat: "woff2" };
  }
  if (first === 0x74 && second === 0x74 && third === 0x63 && fourth === 0x66) {
    return { mimeType: "font/collection", cssFormat: "collection" };
  }
  return null;
}

function validatedEmbeddedFontData(
  value: unknown,
): (EmbeddedFontFormat & { data: string; byteLength: number }) | null {
  if (typeof value !== "string" || value.length === 0) return null;
  const maximumEncodedLength = Math.ceil(MAX_EMBEDDED_FONT_BYTES / 3) * 4;
  // Swift's Data encoder does not add whitespace. A small allowance keeps
  // hand-wrapped project JSON compatible without permitting whitespace bombs.
  if (value.length > maximumEncodedLength + 4_096) return null;
  const data = value.replace(/[\t\n\f\r ]+/g, "");
  if (
    data.length === 0 ||
    data.length > maximumEncodedLength ||
    data.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)
  ) {
    return null;
  }
  const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
  const byteLength = (data.length / 4) * 3 - padding;
  if (byteLength < 4 || byteLength > MAX_EMBEDDED_FONT_BYTES) return null;
  const format = embeddedFontFormat(data);
  return format ? { ...format, data, byteLength } : null;
}

function embeddedFontTraits(postScriptName: string): {
  weight: number;
  italic: boolean;
} {
  const name = postScriptName.toLowerCase().replace(/[\s_-]+/g, "");
  let weight = 400;
  if (/(?:black|ultrablack|extrablack)/.test(name)) weight = 900;
  else if (/(?:extrabold|ultrabold|heavy)/.test(name)) weight = 800;
  else if (/(?:semibold|demibold|demi|bold)/.test(name)) weight = 700;
  else if (/(?:medium)/.test(name)) weight = 500;
  else if (/(?:extralight|ultralight)/.test(name)) weight = 200;
  else if (/(?:thin|hairline)/.test(name)) weight = 100;
  else if (/(?:light)/.test(name)) weight = 300;
  return { weight, italic: /(?:italic|oblique|slanted)/.test(name) };
}

function prepareEmbeddedFonts(
  embeddedFonts: readonly EmbeddedFont[] | undefined,
): PreparedEmbeddedFonts {
  if (!embeddedFonts || embeddedFonts.length === 0) return NO_EMBEDDED_FONTS;

  const faces: PreparedEmbeddedFontFace[] = [];
  const byData = new Map<string, PreparedEmbeddedFontFace>();
  const byPostScriptName = new Map<string, PreparedEmbeddedFontFace>();
  const byFamilyName = new Map<string, PreparedEmbeddedFontFace[]>();
  const countedData = new Set<string>();
  let totalBytes = 0;

  const addFamilyFace = (
    familyName: string | null,
    face: PreparedEmbeddedFontFace,
  ): void => {
    if (!familyName) return;
    const family = byFamilyName.get(familyName) ?? [];
    if (!family.includes(face)) family.push(face);
    byFamilyName.set(familyName, family);
  };

  for (
    let index = 0;
    index < Math.min(embeddedFonts.length, MAX_EMBEDDED_FONT_ENTRIES);
    index += 1
  ) {
    const font = embeddedFonts[index];
    if (!font || typeof font !== "object") continue;
    const rawPostScriptName = typeof font.postScriptName === "string"
      ? font.postScriptName.trim()
      : "";
    const postScriptName = normalizedFontName(font.postScriptName);
    const familyName = normalizedFontName(font.familyName);
    if (!postScriptName && !familyName) continue;

    // A PostScript name uniquely identifies a face. Conflicting later entries
    // cannot safely replace the first validated source in an untrusted project.
    const existingNamedFace = postScriptName
      ? byPostScriptName.get(postScriptName)
      : undefined;
    if (existingNamedFace) {
      addFamilyFace(familyName, existingNamedFace);
      continue;
    }

    let validated = validatedEmbeddedFontData(font.data);
    if (!validated) continue;
    if (validated.cssFormat === "collection") {
      const extracted = standaloneFontFaceBase64(
        validated.data,
        rawPostScriptName,
      );
      validated = extracted ? validatedEmbeddedFontData(extracted) : null;
      if (!validated || validated.cssFormat === "collection") continue;
    }
    let face = byData.get(validated.data);
    if (!face) {
      const additionalBytes = countedData.has(validated.data) ? 0 : validated.byteLength;
      if (
        faces.length >= MAX_EMBEDDED_FONT_FACES ||
        totalBytes + additionalBytes > MAX_TOTAL_EMBEDDED_FONT_BYTES
      ) {
        continue;
      }
      const traitName =
        typeof font.postScriptName === "string"
          ? font.postScriptName
          : typeof font.familyName === "string"
            ? font.familyName
            : "";
      const traits = embeddedFontTraits(traitName);
      const fingerprint = `${postScriptName ?? ""}\0${familyName ?? ""}\0${validated.data.length}\0${validated.data.slice(0, 24)}`;
      face = {
        alias: `ilabel2-embedded-${faces.length}-${hashString(fingerprint)}`,
        data: validated.data,
        mimeType: validated.mimeType,
        cssFormat: validated.cssFormat,
        weight: traits.weight,
        italic: traits.italic,
      };
      faces.push(face);
      byData.set(validated.data, face);
      countedData.add(validated.data);
      totalBytes += additionalBytes;
    }
    if (postScriptName) byPostScriptName.set(postScriptName, face);
    addFamilyFace(familyName, face);
  }

  if (faces.length === 0) return NO_EMBEDDED_FONTS;
  const css = faces
    .map(
      (face) =>
        `@font-face{font-family:${cssString(face.alias)};src:url(data:${face.mimeType};base64,${face.data}) format(${cssString(face.cssFormat)});font-weight:${face.weight};font-style:${face.italic ? "italic" : "normal"};font-display:block}`,
    )
    .join("");
  return { css, byPostScriptName, byFamilyName };
}

function resolvedFontFamily(
  requestedName: string,
  bold: boolean,
  italic: boolean,
  embeddedFonts: PreparedEmbeddedFonts,
): string {
  const key = normalizedFontName(requestedName);
  if (!key) return requestedName || "sans-serif";
  const exactFace = embeddedFonts.byPostScriptName.get(key);
  if (exactFace) return exactFace.alias;
  const familyFaces = embeddedFonts.byFamilyName.get(key);
  if (!familyFaces || familyFaces.length === 0) return requestedName || "sans-serif";
  const requestedWeight = bold ? 700 : 400;
  return familyFaces.reduce((best, candidate) => {
    const bestScore =
      Math.abs(best.weight - requestedWeight) + (best.italic === italic ? 0 : 1_000);
    const candidateScore =
      Math.abs(candidate.weight - requestedWeight) +
      (candidate.italic === italic ? 0 : 1_000);
    return candidateScore < bestScore ? candidate : best;
  }).alias;
}

function embeddedFontDefinition(embeddedFonts: PreparedEmbeddedFonts): string[] {
  return embeddedFonts.css
    ? [`<style type="text/css">${embeddedFonts.css}</style>`]
    : [];
}

function normalizeOptions(
  options: SVGRenderOptions,
  defaultPrefix: string,
  inheritedNow?: Date,
): ResolvedRenderOptions {
  const padding = finite(options.codePaddingMM ?? DEFAULT_CODE_PADDING_MM);
  return {
    now: inheritedNow ?? options.now ?? new Date(),
    showGuides: options.showGuides ?? false,
    guideColor: options.guideColor ?? GUIDE,
    backgroundColor:
      options.backgroundColor === undefined ? WHITE : options.backgroundColor,
    idPrefix: xmlID(options.idPrefix ?? defaultPrefix),
    codePaddingMM: Math.max(0, padding),
  };
}

function channel(value: number): number {
  return Math.round(clamp(finite(value), 0, 1) * 255);
}

function hexadecimal(value: number): string {
  return value.toString(16).padStart(2, "0");
}

function colorHex(color: RGBAColor): string {
  return `#${hexadecimal(channel(color.red))}${hexadecimal(channel(color.green))}${hexadecimal(channel(color.blue))}`;
}

function colorAlpha(color: RGBAColor): number {
  return clamp(finite(color.alpha, 1), 0, 1);
}

function fillAttributes(color: RGBAColor): string {
  const alpha = colorAlpha(color);
  if (alpha <= 0) return 'fill="none"';
  const opacity = alpha < 1 ? ` fill-opacity="${number(alpha)}"` : "";
  return `fill="${colorHex(color)}"${opacity}`;
}

function strokeAttributes(color: RGBAColor, widthPoints: number): string {
  const widthMM = Math.max(0, finite(widthPoints)) / MM_TO_POINTS_RATIO;
  const alpha = colorAlpha(color);
  if (widthMM <= 0 || alpha <= 0) return 'stroke="none"';
  const opacity = alpha < 1 ? ` stroke-opacity="${number(alpha)}"` : "";
  return `stroke="${colorHex(color)}"${opacity} stroke-width="${number(widthMM)}" stroke-linejoin="round"`;
}

function previewGuideAttributes(
  color: RGBAColor,
  kind: "label" | "page-slot",
): string {
  const alpha = colorAlpha(color);
  const stroke = alpha <= 0
    ? 'stroke="none"'
    : `stroke="${colorHex(color)}"${alpha < 1 ? ` stroke-opacity="${number(alpha)}"` : ""}`;
  return `data-preview-guide="${kind}" fill="none" ${stroke} stroke-width="${number(PREVIEW_GUIDE_STROKE_PX)}" stroke-linejoin="round" vector-effect="non-scaling-stroke" shape-rendering="geometricPrecision" pointer-events="none"`;
}

function rectGeometry(frame: RectMM): RectMM {
  return {
    x: finite(frame.x),
    y: finite(frame.y),
    width: Math.max(0, finite(frame.width)),
    height: Math.max(0, finite(frame.height)),
  };
}

function insetRect(frame: RectMM, inset: number): RectMM {
  const safeInset = Math.min(
    Math.max(0, inset),
    frame.width / 2,
    frame.height / 2,
  );
  return {
    x: frame.x + safeInset,
    y: frame.y + safeInset,
    width: Math.max(0, frame.width - safeInset * 2),
    height: Math.max(0, frame.height - safeInset * 2),
  };
}

function roundedRect(
  frame: RectMM,
  radiusMM: number,
  attributes: string,
): string {
  const radius = clamp(
    finite(radiusMM),
    0,
    Math.min(frame.width, frame.height) / 2,
  );
  return `<rect x="${number(frame.x)}" y="${number(frame.y)}" width="${number(frame.width)}" height="${number(frame.height)}" rx="${number(radius)}" ry="${number(radius)}" ${attributes}/>`;
}

function shapeMarkup(
  shape: LabelShape,
  frame: RectMM,
  radiusMM: number,
  attributes: string,
): string {
  switch (shape) {
    case "circle":
      return `<ellipse cx="${number(frame.x + frame.width / 2)}" cy="${number(frame.y + frame.height / 2)}" rx="${number(frame.width / 2)}" ry="${number(frame.height / 2)}" ${attributes}/>`;
    case "capsule":
      return roundedRect(frame, Math.min(frame.width, frame.height) / 2, attributes);
    case "roundedRectangle":
      return roundedRect(frame, radiusMM, attributes);
    case "rectangle":
      return roundedRect(frame, 0, attributes);
  }
}

function rotationTransform(element: LabelElement): string {
  const angle = finite(element.rotation);
  if (Math.abs(angle) < 0.000001) return "";
  const frame = rectGeometry(element.frame);
  return ` transform="rotate(${number(angle)} ${number(frame.x + frame.width / 2)} ${number(frame.y + frame.height / 2)})"`;
}

function elementGroup(
  element: LabelElement,
  kind: string,
  content: string,
): string {
  const opacity = clamp(finite(element.opacity, 1), 0, 1);
  return `<g data-element-id="${escapeXML(element.id)}" data-element-type="${kind}" opacity="${number(opacity)}"${rotationTransform(element)}>${content}</g>`;
}

function isPayload(
  source: MergeContext | SlotRenderPayload,
): source is SlotRenderPayload {
  return (
    typeof source === "object" &&
    source !== null &&
    Array.isArray((source as SlotRenderPayload).elements) &&
    typeof (source as SlotRenderPayload).context === "object"
  );
}

function resolvedPayload(
  document: LabelDocument,
  source?: MergeContext | SlotRenderPayload,
): SlotRenderPayload {
  if (source && isPayload(source)) return source;
  if (source) {
    return {
      elements: document.elements,
      context: source,
      serialSettings: document.serial,
    };
  }
  return renderPayload(document, 0, 0);
}

function graphemes(value: string): string[] {
  if (typeof Intl.Segmenter === "function") {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(segmenter.segment(value), ({ segment }) => segment);
  }
  return Array.from(value);
}

function isWideGrapheme(value: string): boolean {
  const codePoint = value.codePointAt(0) ?? 0;
  return (
    codePoint >= 0x1100 &&
    (codePoint <= 0x11ff ||
      (codePoint >= 0x2e80 && codePoint <= 0xa4cf) ||
      (codePoint >= 0xac00 && codePoint <= 0xd7af) ||
      (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
      (codePoint >= 0xfe10 && codePoint <= 0xfe6f) ||
      (codePoint >= 0xff00 && codePoint <= 0xffef) ||
      codePoint >= 0x1f000)
  );
}

function graphemeAdvanceEM(value: string): number {
  if (value === "\t") return 1.32;
  if (/^\s$/u.test(value)) return 0.33;
  if (/^[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\ufe20-\ufe2f]+$/u.test(value)) {
    return 0;
  }
  if (isWideGrapheme(value)) return 1;
  if (/^[ilI.,'`|!:;]$/u.test(value)) return 0.28;
  if (/^[mwMW@#%&]$/u.test(value)) return 0.84;
  if (/^[A-Z0-9]$/u.test(value)) return 0.62;
  return 0.55;
}

function estimatedTextWidth(
  value: string,
  fontSizeMM: number,
  bold: boolean,
  italic: boolean,
  fontName = "Arial",
): number {
  if (typeof document !== "undefined") {
    if (textMeasurementContext === undefined) {
      textMeasurementContext = document.createElement("canvas").getContext("2d");
    }
    const context = textMeasurementContext;
    if (context) {
      const pixelsPerMM = 96 / 25.4;
      const family = fontName.replace(/["\\]/g, "");
      context.font = `${italic ? "italic " : ""}${bold ? "700" : "400"} ${fontSizeMM * pixelsPerMM}px "${family}"`;
      return context.measureText(value).width / pixelsPerMM;
    }
  }
  const traitScale = (bold ? 1.035 : 1) * (italic ? 1.015 : 1);
  return (
    graphemes(value).reduce(
      (total, character) => total + graphemeAdvanceEM(character),
      0,
    ) *
    fontSizeMM *
    traitScale
  );
}

function wrapText(
  value: string,
  availableWidth: (lineIndex: number) => number,
  measure: (candidate: string) => number,
): string[] {
  const output: string[] = [];
  const paragraphs = value.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");

  const pushLine = (line: string): void => {
    output.push(line.replace(/\s+$/u, ""));
  };

  for (const paragraph of paragraphs) {
    if (paragraph.length === 0) {
      output.push("");
      continue;
    }

    const tokens = paragraph.match(/\S+|\s+/gu) ?? [paragraph];
    let line = "";
    let pendingWhitespace = "";

    const appendLongToken = (token: string): void => {
      for (const character of graphemes(token)) {
        const width = Math.max(0.1, availableWidth(output.length));
        if (line.length > 0 && measure(`${line}${character}`) > width) {
          pushLine(line);
          line = "";
        }
        line += character;
      }
    };

    for (const token of tokens) {
      if (/^\s+$/u.test(token)) {
        if (line.length > 0) pendingWhitespace += token;
        continue;
      }

      const separator = line.length > 0 ? pendingWhitespace : "";
      const candidate = `${line}${separator}${token}`;
      const width = Math.max(0.1, availableWidth(output.length));
      if (measure(candidate) <= width) {
        line = candidate;
        pendingWhitespace = "";
        continue;
      }

      if (line.length > 0) {
        pushLine(line);
        line = "";
        pendingWhitespace = "";
      }

      if (measure(token) <= Math.max(0.1, availableWidth(output.length))) {
        line = token;
      } else {
        appendLongToken(token);
      }
    }

    if (line.length > 0 || pendingWhitespace.length > 0) {
      pushLine(`${line}${pendingWhitespace}`);
    }
  }

  return output.length > 0 ? output : [""];
}

function verticalize(value: string): string {
  return value
    .replaceAll("\r\n", "\n")
    .replaceAll("\r", "\n")
    .split("\n")
    .map((line) => graphemes(line).join("\n"))
    .join("\n\n");
}

function richRunKey(run: RTFStyleRun): string {
  return JSON.stringify({
    fontName: run.fontName,
    fontSize: run.fontSize,
    bold: run.bold,
    italic: run.italic,
    underline: run.underline,
    foreground: run.foreground,
  });
}

function appendRichRun(
  runs: RTFStyleRun[],
  start: number,
  length: number,
  style: Omit<RTFStyleRun, "start" | "length">,
): void {
  if (length <= 0) return;
  const next: RTFStyleRun = { ...style, start, length };
  const previous = runs.at(-1);
  if (
    previous &&
    previous.start + previous.length === start &&
    richRunKey(previous) === richRunKey(next)
  ) {
    previous.length += length;
  } else {
    runs.push(next);
  }
}

function verticalizeRichText(source: ResolvedRichText): ResolvedRichText {
  const outputRuns: RTFStyleRun[] = [];
  let output = "";
  let sourceOffset = 0;
  const lines = source.text.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  lines.forEach((line, lineIndex) => {
    const segments = typeof Intl.Segmenter === "function"
      ? [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(line)]
      : graphemes(line).map((segment, index) => ({ segment, index }));
    segments.forEach(({ segment, index }, segmentIndex) => {
      const style = runStyleAt(source.runs, sourceOffset + index);
      const start = output.length;
      output += segment;
      appendRichRun(outputRuns, start, segment.length, style);
      if (segmentIndex < segments.length - 1) {
        const breakStart = output.length;
        output += "\n";
        appendRichRun(outputRuns, breakStart, 1, style);
      }
    });
    sourceOffset += line.length;
    if (lineIndex < lines.length - 1) {
      const style = runStyleAt(source.runs, Math.max(0, sourceOffset - 1));
      const start = output.length;
      output += "\n\n";
      appendRichRun(outputRuns, start, 2, style);
      sourceOffset += 1;
    }
  });
  return {
    text: output,
    runs: outputRuns,
    sourceWasRichText: source.sourceWasRichText,
  };
}

function runFontSizeMM(run: RTFStyleRun, element: LabelElement): number {
  return Math.max(0.1, run.fontSize ?? element.fontSize) / MM_TO_POINTS_RATIO;
}

function measureRichRange(
  rich: ResolvedRichText,
  start: number,
  end: number,
  element: LabelElement,
): number {
  let width = 0;
  for (const run of rich.runs) {
    const intersectionStart = Math.max(start, run.start);
    const intersectionEnd = Math.min(end, run.start + run.length);
    if (intersectionEnd <= intersectionStart) continue;
    width += estimatedTextWidth(
      rich.text.slice(intersectionStart, intersectionEnd),
      runFontSizeMM(run, element),
      run.bold ?? element.isBold,
      run.italic ?? element.isItalic,
      run.fontName ?? element.fontName,
    );
  }
  return width;
}

interface WrappedRichLine {
  start: number;
  length: number;
  text: string;
}

function wrapRichText(
  rich: ResolvedRichText,
  element: LabelElement,
  availableWidth: (lineIndex: number) => number,
): WrappedRichLine[] {
  const output: WrappedRichLine[] = [];
  const push = (start: number, end: number): void => {
    while (end > start && /\s/u.test(rich.text[end - 1]!)) end -= 1;
    output.push({ start, length: end - start, text: rich.text.slice(start, end) });
  };

  const processParagraph = (paragraphStart: number, paragraphEnd: number): void => {
    if (paragraphStart === paragraphEnd) {
      output.push({ start: paragraphStart, length: 0, text: "" });
      return;
    }
    const paragraph = rich.text.slice(paragraphStart, paragraphEnd);
    const tokens = [...paragraph.matchAll(/\S+|\s+/gu)];
    let lineStart = -1;
    let lineEnd = -1;
    let pendingWhitespaceStart = -1;

    const appendLongToken = (start: number, end: number): void => {
      const token = rich.text.slice(start, end);
      const segments = typeof Intl.Segmenter === "function"
        ? [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(token)]
        : graphemes(token).map((segment, index) => ({ segment, index }));
      for (const { segment, index } of segments) {
        const segmentStart = start + index;
        const segmentEnd = segmentStart + segment.length;
        if (
          lineStart >= 0 &&
          measureRichRange(rich, lineStart, segmentEnd, element) >
            Math.max(0.1, availableWidth(output.length))
        ) {
          push(lineStart, lineEnd);
          lineStart = -1;
          lineEnd = -1;
        }
        if (lineStart < 0) lineStart = segmentStart;
        lineEnd = segmentEnd;
      }
    };

    for (const token of tokens) {
      const tokenStart = paragraphStart + token.index;
      const tokenEnd = tokenStart + token[0].length;
      if (/^\s+$/u.test(token[0])) {
        if (lineStart >= 0 && pendingWhitespaceStart < 0) {
          pendingWhitespaceStart = tokenStart;
        }
        continue;
      }
      const candidateStart = lineStart >= 0 ? lineStart : tokenStart;
      const candidateEnd = tokenEnd;
      if (
        measureRichRange(rich, candidateStart, candidateEnd, element) <=
        Math.max(0.1, availableWidth(output.length))
      ) {
        if (lineStart < 0) lineStart = tokenStart;
        lineEnd = tokenEnd;
        pendingWhitespaceStart = -1;
        continue;
      }
      if (lineStart >= 0) {
        push(lineStart, lineEnd);
        lineStart = -1;
        lineEnd = -1;
        pendingWhitespaceStart = -1;
      }
      if (
        measureRichRange(rich, tokenStart, tokenEnd, element) <=
        Math.max(0.1, availableWidth(output.length))
      ) {
        lineStart = tokenStart;
        lineEnd = tokenEnd;
      } else {
        appendLongToken(tokenStart, tokenEnd);
      }
    }
    if (lineStart >= 0) push(lineStart, lineEnd);
  };

  let paragraphStart = 0;
  for (let index = 0; index <= rich.text.length; index += 1) {
    if (index === rich.text.length || rich.text[index] === "\n") {
      processParagraph(paragraphStart, index);
      paragraphStart = index + 1;
    }
  }
  return output.length > 0 ? output : [{ start: 0, length: 0, text: "" }];
}

function maximumLineFontSizeMM(
  rich: ResolvedRichText,
  line: WrappedRichLine,
  element: LabelElement,
): number {
  let maximum = 0;
  const end = line.start + Math.max(1, line.length);
  for (const run of rich.runs) {
    if (run.start < end && run.start + run.length > line.start) {
      maximum = Math.max(maximum, runFontSizeMM(run, element));
    }
  }
  return maximum > 0
    ? maximum
    : Math.max(0.1, element.fontSize / MM_TO_POINTS_RATIO);
}

function textX(
  alignment: TextAlignModel,
  leading: number,
  center: number,
  trailing: number,
): number {
  switch (alignment) {
    case "leading":
      return leading;
    case "center":
      return center;
    case "trailing":
      return trailing;
  }
}

function textAnchor(alignment: TextAlignModel): string {
  switch (alignment) {
    case "leading":
      return "start";
    case "center":
      return "middle";
    case "trailing":
      return "end";
  }
}

function rectangularTextLines(
  rich: ResolvedRichText,
  element: LabelElement,
  frame: RectMM,
): TextLine[] {
  const left = frame.x + TEXT_ELEMENT_INSET_X_MM;
  const right = frame.x + frame.width - TEXT_ELEMENT_INSET_X_MM;
  const width = Math.max(0.1, right - left);
  const lines = wrapRichText(rich, element, () => width);
  const fontSizes = lines.map((line) => maximumLineFontSizeMM(rich, line, element));
  const lineHeights = fontSizes.map((fontSize) => fontSize * 1.2);
  const totalHeight = lineHeights.reduce((total, height) => total + height, 0);
  const top = Math.max(
    frame.y + TEXT_ELEMENT_INSET_Y_MM,
    frame.y + (frame.height - totalHeight) / 2,
  );
  const x = textX(
    element.textAlignment,
    left,
    frame.x + frame.width / 2,
    right,
  );

  let cursorY = top;
  return lines.map((line, index) => {
    const fontSizeMM = fontSizes[index]!;
    const lineHeightMM = lineHeights[index]!;
    const baselineOffset = (lineHeightMM - fontSizeMM) / 2 + fontSizeMM * 0.82;
    const result = {
      ...line,
      x,
      baselineY: cursorY + baselineOffset,
      availableWidth: width,
      fontSizeMM,
    };
    cursorY += lineHeightMM;
    return result;
  });
}

function ellipseChordWidth(
  centerY: number,
  center: number,
  radiusX: number,
  radiusY: number,
): number {
  if (radiusX <= 0 || radiusY <= 0) return 0.1;
  const normalizedY = (centerY - center) / radiusY;
  if (Math.abs(normalizedY) >= 1) return 0.1;
  return Math.max(0.1, 2 * radiusX * Math.sqrt(1 - normalizedY * normalizedY));
}

function ellipseBandChordWidth(
  top: number,
  bottom: number,
  center: number,
  radiusX: number,
  radiusY: number,
): number {
  // A glyph occupies the full line band, so its safe width is the narrower
  // chord at either band edge—not the wider chord through the line center.
  return Math.min(
    ellipseChordWidth(top, center, radiusX, radiusY),
    ellipseChordWidth(bottom, center, radiusX, radiusY),
  );
}

function circularTextLines(
  rich: ResolvedRichText,
  element: LabelElement,
  frame: RectMM,
): TextLine[] {
  const centerX = frame.x + frame.width / 2;
  const centerY = frame.y + frame.height / 2;
  const radiusX = Math.max(0.1, frame.width / 2 - TEXT_ELEMENT_INSET_X_MM);
  const radiusY = Math.max(0.1, frame.height / 2 - TEXT_ELEMENT_INSET_Y_MM);
  let lines = wrapRichText(rich, element, () => radiusX * 2);
  for (let iteration = 0; iteration < 8; iteration += 1) {
    const heights = lines.map((line) => maximumLineFontSizeMM(rich, line, element) * 1.2);
    const totalHeight = heights.reduce((total, height) => total + height, 0);
    const top = centerY - totalHeight / 2;
    const bands: Array<{ top: number; bottom: number }> = [];
    let cursor = top;
    heights.forEach((height) => {
      bands.push({ top: cursor, bottom: cursor + height });
      cursor += height;
    });
    const next = wrapRichText(rich, element, (lineIndex) =>
      ellipseBandChordWidth(
        bands[Math.min(lineIndex, Math.max(0, bands.length - 1))]?.top ?? centerY,
        bands[Math.min(lineIndex, Math.max(0, bands.length - 1))]?.bottom ?? centerY,
        centerY,
        radiusX,
        radiusY,
      ));
    if (
      next.length === lines.length &&
      next.every((line, index) =>
        line.start === lines[index]?.start && line.length === lines[index]?.length)
    ) {
      lines = next;
      break;
    }
    lines = next;
  }

  const fontSizes = lines.map((line) => maximumLineFontSizeMM(rich, line, element));
  const lineHeights = fontSizes.map((fontSize) => fontSize * 1.2);
  const totalHeight = lineHeights.reduce((total, height) => total + height, 0);
  const top = centerY - totalHeight / 2;
  let cursorY = top;
  return lines.map((line, index) => {
    const fontSizeMM = fontSizes[index]!;
    const lineHeightMM = lineHeights[index]!;
    const chord = ellipseBandChordWidth(
      cursorY,
      cursorY + lineHeightMM,
      centerY,
      radiusX,
      radiusY,
    );
    const baselineOffset = (lineHeightMM - fontSizeMM) / 2 + fontSizeMM * 0.82;
    const result = {
      ...line,
      x: textX(
        element.textAlignment,
        centerX - chord / 2,
        centerX,
        centerX + chord / 2,
      ),
      baselineY: cursorY + baselineOffset,
      availableWidth: chord,
      fontSizeMM,
    };
    cursorY += lineHeightMM;
    return result;
  });
}

function renderRichLine(
  line: TextLine,
  rich: ResolvedRichText,
  element: LabelElement,
  embeddedFonts: PreparedEmbeddedFonts,
): string {
  const end = line.start + line.length;
  const segments: string[] = [];
  for (const run of rich.runs) {
    const start = Math.max(line.start, run.start);
    const segmentEnd = Math.min(end, run.start + run.length);
    if (segmentEnd <= start) continue;
    const foreground = run.foreground ?? element.foreground;
    const opacity = colorAlpha(foreground) < 1
      ? ` fill-opacity="${number(colorAlpha(foreground))}"`
      : "";
    const bold = run.bold ?? element.isBold;
    const italic = run.italic ?? element.isItalic;
    const family = resolvedFontFamily(
      run.fontName ?? element.fontName,
      bold,
      italic,
      embeddedFonts,
    );
    segments.push(
      `<tspan font-family="${escapeXML(family)}" font-size="${number(runFontSizeMM(run, element))}" font-weight="${bold ? "700" : "400"}" font-style="${italic ? "italic" : "normal"}" text-decoration="${run.underline ?? element.isUnderline ? "underline" : "none"}" fill="${colorHex(foreground)}"${opacity}>${escapeXML(rich.text.slice(start, segmentEnd))}</tspan>`,
    );
  }
  const content = segments.length > 0 ? segments.join("") : escapeXML(line.text);
  return `<tspan x="${number(line.x)}" y="${number(line.baselineY)}" data-text-start="${line.start}" data-text-length="${line.length}" data-line-font-size="${number(line.fontSizeMM)}" data-available-width="${number(line.availableWidth)}">${content}</tspan>`;
}

function renderTextElement(
  element: LabelElement,
  environment: ElementRenderEnvironment,
  elementIndex: number,
): SVGFragment {
  const frame = rectGeometry(element.frame);
  if (frame.width <= 0 || frame.height <= 0) return { definitions: [], body: "" };

  const circular =
    environment.document.sheet.shape === "circle" &&
    element.usesCircularTextFlow === true;
  const surface = circular
    ? shapeMarkup(
        "circle",
        frame,
        0,
        `${fillAttributes(element.background)} ${strokeAttributes(element.stroke, element.strokeWidth)}`,
      )
    : roundedRect(
        frame,
        element.cornerRadiusMM,
        `${fillAttributes(element.background)} ${strokeAttributes(element.stroke, element.strokeWidth)}`,
      );

  let rich = resolveElementRichText(
    element,
    environment.context,
    environment.serialSettings,
    environment.options.now,
  );
  if (element.verticalTextLayout) rich = verticalizeRichText(rich);
  const fontSizeMM = Math.max(0.1, finite(element.fontSize, 12)) / MM_TO_POINTS_RATIO;
  const lines = circular
    ? circularTextLines(rich, element, frame)
    : rectangularTextLines(rich, element, frame);
  const foregroundAlpha = colorAlpha(element.foreground);
  const foregroundOpacity =
    foregroundAlpha < 1 ? ` fill-opacity="${number(foregroundAlpha)}"` : "";
  const fontStyle = element.isItalic ? ' font-style="italic"' : "";
  const decoration = element.isUnderline ? ' text-decoration="underline"' : "";
  const clipID = xmlID(
    `${environment.idPrefix}-text-${elementIndex}-${element.id}`,
  );
  const clipShape = circular
    ? shapeMarkup("circle", frame, 0, "")
    : roundedRect(frame, element.cornerRadiusMM, "");
  const tspans = lines
    .map((line) => renderRichLine(line, rich, element, environment.embeddedFonts))
    .join("");
  const layout = circular ? "circular-chord" : element.verticalTextLayout ? "vertical" : "rectangular";
  const fontFamily = resolvedFontFamily(
    element.fontName,
    element.isBold,
    element.isItalic,
    environment.embeddedFonts,
  );
  const text = `<text data-layout="${layout}" xml:space="preserve" text-anchor="${textAnchor(element.textAlignment)}" font-family="${escapeXML(fontFamily)}" font-size="${number(fontSizeMM)}" font-weight="${element.isBold ? "700" : "400"}"${fontStyle}${decoration} fill="${colorHex(element.foreground)}"${foregroundOpacity} clip-path="url(#${clipID})">${tspans}</text>`;

  return {
    definitions: [
      `<clipPath id="${clipID}" clipPathUnits="userSpaceOnUse">${clipShape}</clipPath>`,
    ],
    body: elementGroup(element, "text", `${surface}${text}`),
  };
}

function renderRectangleElement(element: LabelElement): SVGFragment {
  const frame = rectGeometry(element.frame);
  const body = roundedRect(
    frame,
    element.cornerRadiusMM,
    `${fillAttributes(element.background)} ${strokeAttributes(element.stroke, element.strokeWidth)}`,
  );
  return {
    definitions: [],
    body: elementGroup(element, "rectangle", body),
  };
}

function imageMIMEType(base64: string): string {
  const compact = base64.replace(/\s+/g, "");
  if (compact.startsWith("iVBORw0KGgo")) return "image/png";
  if (compact.startsWith("/9j/")) return "image/jpeg";
  if (compact.startsWith("R0lGOD")) return "image/gif";
  if (compact.startsWith("UklGR")) return "image/webp";
  if (compact.startsWith("Qk")) return "image/bmp";
  if (compact.startsWith("SUkq") || compact.startsWith("TU0AK")) return "image/tiff";
  if (compact.startsWith("PHN2Zy") || compact.startsWith("PD94bWwg")) return "image/svg+xml";
  if (compact.slice(4, 16).includes("ZnR5cGhlaWM")) return "image/heic";
  return "image/png";
}

function rasterDataURL(data: string): string | null {
  const trimmed = data.trim();
  if (trimmed.length === 0) return null;
  if (trimmed.startsWith("data:")) {
    return /^data:image\/(?:png|jpe?g|gif|webp|bmp|tiff|heic|svg\+xml);base64,[A-Za-z0-9+/=\s]+$/i.test(
      trimmed,
    )
      ? trimmed.replace(/\s+/g, "")
      : null;
  }
  const compact = trimmed.replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(compact)) return null;
  return `data:${imageMIMEType(compact)};base64,${compact}`;
}

function renderImageElement(
  element: LabelElement,
  environment: ElementRenderEnvironment,
  elementIndex: number,
): SVGFragment {
  const frame = rectGeometry(element.frame);
  const clipID = xmlID(`${environment.idPrefix}-image-${elementIndex}-${element.id}`);
  const definition = `<clipPath id="${clipID}" clipPathUnits="userSpaceOnUse">${roundedRect(frame, element.cornerRadiusMM, "")}</clipPath>`;
  const background = roundedRect(
    frame,
    element.cornerRadiusMM,
    `${fillAttributes(element.background)} stroke="none"`,
  );
  const outline = roundedRect(
    frame,
    element.cornerRadiusMM,
    `fill="none" ${strokeAttributes(element.stroke, element.strokeWidth)}`,
  );
  const href = element.imageData ? rasterDataURL(element.imageData) : null;
  const image = href
    ? `<image data-kind="image" x="${number(frame.x)}" y="${number(frame.y)}" width="${number(frame.width)}" height="${number(frame.height)}" href="${escapeXML(href)}" preserveAspectRatio="xMidYMid ${element.imageScaleMode === "fill" ? "slice" : "meet"}" clip-path="url(#${clipID})"/>`
    : "";
  return {
    definitions: [definition],
    body: elementGroup(element, "image", `${background}${image}${outline}`),
  };
}

function codeSurface(element: LabelElement, frame: RectMM): string {
  return roundedRect(
    frame,
    element.cornerRadiusMM,
    `${fillAttributes(element.background)} ${strokeAttributes(element.stroke, element.strokeWidth)}`,
  );
}

function codeContentRect(frame: RectMM, requestedPadding: number): RectMM {
  const maximumUsefulPadding = Math.min(frame.width, frame.height) * 0.22;
  return insetRect(frame, Math.min(requestedPadding, maximumUsefulPadding));
}

function renderQRCodeElement(
  element: LabelElement,
  environment: ElementRenderEnvironment,
): SVGFragment {
  const frame = rectGeometry(element.frame);
  const surface = codeSurface(element, frame);
  const payload = resolveTokens(
    element.content,
    environment.context,
    environment.serialSettings,
    environment.options.now,
  );

  try {
    const qr = QRCode.create(payload, { errorCorrectionLevel: "M" });
    const matrixSize = qr.modules.size;
    const content = codeContentRect(frame, environment.options.codePaddingMM);
    const side = Math.min(content.width, content.height);
    const totalModules = matrixSize + QR_QUIET_ZONE_MODULES * 2;
    const moduleSize = side / totalModules;
    const originX = content.x + (content.width - side) / 2 + QR_QUIET_ZONE_MODULES * moduleSize;
    const originY = content.y + (content.height - side) / 2 + QR_QUIET_ZONE_MODULES * moduleSize;
    const commands: string[] = [];
    for (let row = 0; row < matrixSize; row += 1) {
      for (let column = 0; column < matrixSize; column += 1) {
        if (!qr.modules.get(row, column)) continue;
        commands.push(
          `M${number(originX + column * moduleSize)} ${number(originY + row * moduleSize)}h${number(moduleSize)}v${number(moduleSize)}h-${number(moduleSize)}z`,
        );
      }
    }
    const alpha = colorAlpha(element.foreground);
    const opacity = alpha < 1 ? ` fill-opacity="${number(alpha)}"` : "";
    const modules = `<path data-kind="qr" data-modules="${matrixSize}" shape-rendering="crispEdges" fill="${colorHex(element.foreground)}"${opacity} d="${commands.join("")}"/>`;
    return {
      definitions: [],
      body: elementGroup(element, "qrCode", `${surface}${modules}`),
    };
  } catch {
    return {
      definitions: [],
      body: elementGroup(element, "qrCode", surface),
    };
  }
}

function extractGeneratedSVG(svg: string): { viewBox: string; body: string } | null {
  const root = svg.match(/<svg\b([^>]*)>([\s\S]*?)<\/svg>\s*$/i);
  if (!root) return null;
  const viewBox = root[1].match(/\bviewBox=(?:"([^"]+)"|'([^']+)')/i);
  const value = viewBox?.[1] ?? viewBox?.[2];
  if (!value || !/^[-+0-9.eE\s]+$/.test(value)) return null;
  return { viewBox: value.trim().replace(/\s+/g, " "), body: root[2] };
}

function renderCode128Element(
  element: LabelElement,
  environment: ElementRenderEnvironment,
): SVGFragment {
  const frame = rectGeometry(element.frame);
  const surface = codeSurface(element, frame);
  const payload = resolveTokens(
    element.content,
    environment.context,
    environment.serialSettings,
    environment.options.now,
  );
  if (payload.length === 0) {
    return { definitions: [], body: elementGroup(element, "code128", surface) };
  }

  try {
    const generated = bwipSVG.toSVG({
      bcid: "code128",
      text: payload,
      scale: 2,
      height: Math.max(1, frame.height),
      includetext: false,
      paddingwidth: 0,
      paddingheight: 0,
      barcolor: colorHex(element.foreground).slice(1),
    });
    const parsed = extractGeneratedSVG(generated);
    if (!parsed) throw new Error("bwip-js returned an invalid SVG");
    const content = codeContentRect(frame, environment.options.codePaddingMM);
    const alpha = colorAlpha(element.foreground);
    const opacity = alpha < 1 ? ` opacity="${number(alpha)}"` : "";
    const barcode = `<svg data-kind="code128" x="${number(content.x)}" y="${number(content.y)}" width="${number(content.width)}" height="${number(content.height)}" viewBox="${parsed.viewBox}" preserveAspectRatio="xMidYMid meet" overflow="hidden"${opacity}>${parsed.body}</svg>`;
    return {
      definitions: [],
      body: elementGroup(element, "code128", `${surface}${barcode}`),
    };
  } catch {
    return {
      definitions: [],
      body: elementGroup(element, "code128", surface),
    };
  }
}

function renderElement(
  element: LabelElement,
  environment: ElementRenderEnvironment,
  elementIndex: number,
): SVGFragment {
  switch (element.type) {
    case "text":
      return renderTextElement(element, environment, elementIndex);
    case "rectangle":
      return renderRectangleElement(element);
    case "image":
      return renderImageElement(element, environment, elementIndex);
    case "qrCode":
      return renderQRCodeElement(element, environment);
    case "code128":
      return renderCode128Element(element, environment);
  }
}

function renderLabelFragment(
  document: LabelDocument,
  payload: SlotRenderPayload,
  options: ResolvedRenderOptions,
  idPrefix: string,
  embeddedFonts: PreparedEmbeddedFonts,
): SVGFragment {
  const frame: RectMM = {
    x: 0,
    y: 0,
    width: Math.max(0, finite(document.sheet.labelWidthMM)),
    height: Math.max(0, finite(document.sheet.labelHeightMM)),
  };
  const labelClipID = xmlID(`${idPrefix}-label-clip`);
  const definitions = [
    `<clipPath id="${labelClipID}" clipPathUnits="userSpaceOnUse">${shapeMarkup(document.sheet.shape, frame, document.sheet.cornerRadiusMM, "")}</clipPath>`,
  ];
  const bodies: string[] = [];
  const environment: ElementRenderEnvironment = {
    document,
    context: payload.context,
    serialSettings: payload.serialSettings,
    options,
    idPrefix,
    embeddedFonts,
  };

  payload.elements.forEach((element, index) => {
    const rendered = renderElement(element, environment, index);
    definitions.push(...rendered.definitions);
    bodies.push(rendered.body);
  });

  return {
    definitions,
    body: `<g clip-path="url(#${labelClipID})">${bodies.join("")}</g>`,
  };
}

function renderDefinitions(definitions: readonly string[]): string {
  return definitions.length > 0 ? `<defs>${definitions.join("")}</defs>` : "";
}

function renderBackground(
  width: number,
  height: number,
  background: RGBAColor | null,
): string {
  if (background === null || colorAlpha(background) <= 0) return "";
  return `<rect width="${number(width)}" height="${number(height)}" ${fillAttributes(background)}/>`;
}

function svgRoot(
  surface: "label" | "page",
  width: number,
  height: number,
  title: string,
  definitions: readonly string[],
  body: string,
): string {
  return `<svg xmlns="${SVG_NAMESPACE}" width="${millimeters(width)}" height="${millimeters(height)}" viewBox="0 0 ${number(width)} ${number(height)}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="${escapeXML(title)}" data-render-surface="${surface}"><title>${escapeXML(title)}</title>${renderDefinitions(definitions)}${body}</svg>`;
}

/**
 * Render one label using the same element tree that `renderPageSVG` embeds.
 * A `SlotRenderPayload` preserves captured queue artwork; a bare context uses
 * the document's currently edited elements and serial settings.
 */
export function renderLabelSVG(
  document: LabelDocument,
  contextOrPayload?: MergeContext | SlotRenderPayload,
  options: SVGRenderOptions = {},
): string {
  const resolved = normalizeOptions(options, "ilabel-label");
  const embeddedFonts = prepareEmbeddedFonts(document.embeddedFonts);
  const payload = resolvedPayload(document, contextOrPayload);
  const width = Math.max(0, finite(document.sheet.labelWidthMM));
  const height = Math.max(0, finite(document.sheet.labelHeightMM));
  const fragment = renderLabelFragment(
    document,
    payload,
    resolved,
    `${resolved.idPrefix}-content`,
    embeddedFonts,
  );
  const guide = resolved.showGuides
    ? shapeMarkup(
        document.sheet.shape,
        { x: 0, y: 0, width, height },
        document.sheet.cornerRadiusMM,
        previewGuideAttributes(resolved.guideColor, "label"),
      )
    : "";
  const body = `${renderBackground(width, height, resolved.backgroundColor)}${fragment.body}${guide}`;
  return svgRoot(
    "label",
    width,
    height,
    `${document.title} label`,
    [...embeddedFontDefinition(embeddedFonts), ...fragment.definitions],
    body,
  );
}

function slotFrame(document: LabelDocument, column: number, row: number): RectMM {
  const sheet = document.sheet;
  return {
    x: finite(sheet.marginLeftMM) +
      column * (finite(sheet.labelWidthMM) + finite(sheet.horizontalGapMM)),
    y: finite(sheet.marginTopMM) +
      row * (finite(sheet.labelHeightMM) + finite(sheet.verticalGapMM)),
    width: Math.max(0, finite(sheet.labelWidthMM)),
    height: Math.max(0, finite(sheet.labelHeightMM)),
  };
}

function checkedGridCount(value: number, name: string): number {
  const count = Math.max(1, Math.trunc(finite(value, 1)));
  if (count > MAX_RENDERED_SLOTS) {
    throw new RangeError(`${name} exceeds the SVG renderer limit`);
  }
  return count;
}

function renderPageSVGWithPreparedFonts(
  document: LabelDocument,
  pageIndex: number,
  options: SVGRenderOptions,
  embeddedFonts: PreparedEmbeddedFonts,
  includeEmbeddedFontDefinition: boolean,
): string {
  if (!Number.isInteger(pageIndex) || pageIndex < 0) {
    throw new RangeError("pageIndex must be a non-negative integer");
  }
  const totalPages = pageCount(document);
  const allowsTrailingPreviewPage = options.allowEmptyPage === true && pageIndex === totalPages;
  if (pageIndex >= totalPages && !allowsTrailingPreviewPage) {
    throw new RangeError(`pageIndex ${pageIndex} is outside 0..${Math.max(0, totalPages - 1)}`);
  }

  const resolved = normalizeOptions(options, `ilabel-page-${pageIndex}`);
  const width = Math.max(0, finite(document.sheet.pageWidthMM));
  const height = Math.max(0, finite(document.sheet.pageHeightMM));
  const columns = checkedGridCount(document.sheet.columns, "columns");
  const rows = checkedGridCount(document.sheet.rows, "rows");
  if (columns * rows > MAX_RENDERED_SLOTS) {
    throw new RangeError("sheet slot count exceeds the SVG renderer limit");
  }

  const definitions: string[] = includeEmbeddedFontDefinition
    ? embeddedFontDefinition(embeddedFonts)
    : [];
  const bodies: string[] = [renderBackground(width, height, resolved.backgroundColor)];
  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      const slotIndex = row * columns + column;
      const slot = slotFrame(document, column, row);
      const payload = renderPayload(document, slotIndex, pageIndex);
      if (payload.context.isActive) {
        const prefix = `${resolved.idPrefix}-slot-${slotIndex}`;
        const fragment = renderLabelFragment(
          document,
          payload,
          resolved,
          prefix,
          embeddedFonts,
        );
        definitions.push(...fragment.definitions);
        bodies.push(
          `<g data-slot-index="${slotIndex}" transform="translate(${number(slot.x)} ${number(slot.y)})">${fragment.body}</g>`,
        );
      }

      if (resolved.showGuides) {
        bodies.push(
          shapeMarkup(
            document.sheet.shape,
            slot,
            document.sheet.cornerRadiusMM,
            previewGuideAttributes(resolved.guideColor, "page-slot"),
          ),
        );
      }
    }
  }

  return svgRoot(
    "page",
    width,
    height,
    `${document.title} page ${pageIndex + 1}`,
    definitions,
    bodies.join(""),
  );
}

/** Render a physical page in millimetre coordinates for preview, PDF, or print. */
export function renderPageSVG(
  document: LabelDocument,
  pageIndex: number,
  options: SVGRenderOptions = {},
): string {
  return renderPageSVGWithPreparedFonts(
    document,
    pageIndex,
    options,
    prepareEmbeddedFonts(document.embeddedFonts),
    true,
  );
}

/**
 * Generate a self-contained print document. Omit `pageIndices` to include all
 * pages; pass `[currentPageIndex]` for the current-page action.
 */
export function renderPrintHTML(
  document: LabelDocument,
  pageIndices: readonly number[] = Array.from(
    { length: pageCount(document) },
    (_, index) => index,
  ),
  options: PrintHTMLOptions = {},
): string {
  const totalPages = pageCount(document);
  const now = options.now ?? new Date();
  const width = Math.max(0, finite(document.sheet.pageWidthMM));
  const height = Math.max(0, finite(document.sheet.pageHeightMM));
  const title = options.title ?? document.title;
  const embeddedFonts = prepareEmbeddedFonts(document.embeddedFonts);
  const pages = pageIndices.map((pageIndex, ordinal) => {
    if (!Number.isInteger(pageIndex) || pageIndex < 0 || pageIndex >= totalPages) {
      throw new RangeError(`Invalid print page index: ${pageIndex}`);
    }
    const svg = renderPageSVGWithPreparedFonts(
      document,
      pageIndex,
      {
        ...options,
        now,
        showGuides: false,
        idPrefix: `${options.idPrefix ?? "ilabel"}-print-${ordinal}-page-${pageIndex}`,
      },
      embeddedFonts,
      false,
    );
    return `<section class="ilabel-print-page" data-page-index="${pageIndex}">${svg}</section>`;
  });
  const autoPrint = options.autoPrint
    ? '<script>addEventListener("load",()=>{requestAnimationFrame(()=>print())})</script>'
    : "";

  return `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light"><title>${escapeXML(title)}</title><style>${embeddedFonts.css}@page{size:${millimeters(width)} ${millimeters(height)};margin:0}*{box-sizing:border-box}html,body{margin:0;padding:0;background:#fff}.ilabel-print-page{width:${millimeters(width)};height:${millimeters(height)};overflow:hidden;break-after:page;page-break-after:always}.ilabel-print-page:last-child{break-after:auto;page-break-after:auto}.ilabel-print-page>svg{display:block;width:100%;height:100%;print-color-adjust:exact;-webkit-print-color-adjust:exact}@media screen{body{display:grid;gap:12px;justify-content:start}.ilabel-print-page{box-shadow:0 1px 8px #0003}}</style></head><body>${pages.join("")}${autoPrint}</body></html>`;
}

/** Encode Unicode SVG safely without relying on Node-only Buffer APIs. */
export function svgToStandaloneDataURL(svg: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}
