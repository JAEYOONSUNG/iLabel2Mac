import type { RGBAColor } from "../types";

/**
 * One attributed range in an RTF document. `start` and `length` deliberately
 * use UTF-16 code units, matching both JavaScript string indices and
 * Foundation's `NSRange` representation of an `NSAttributedString`.
 */
export interface RTFStyleRun {
  start: number;
  length: number;
  /** Unicode-code-point range, supplied by the parser for cursor/UI use. */
  characterStart?: number;
  characterLength?: number;
  fontName?: string;
  /** Point size (RTF stores this as half-points). */
  fontSize?: number;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  foreground?: RGBAColor;
}

export interface RTFParseResult {
  text: string;
  runs: RTFStyleRun[];
  /** False means `text` is the caller-provided safe fallback. */
  isValid: boolean;
}

type Destination =
  | "body"
  | "fonttbl"
  | "colortbl"
  | "expandedcolortbl"
  | "skip";

interface ParserStyle {
  fontIndex?: number;
  fontSize?: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  colorIndex?: number;
}

interface ParserState extends ParserStyle {
  destination: Destination;
  unicodeFallbackLength: number;
  fontDefinitionIndex?: number;
  ignorableDestination: boolean;
}

interface InternalRun {
  start: number;
  length: number;
  style: ParserStyle;
}

interface FontDefinition {
  name: string;
  charset?: number;
  codePage?: number;
}

interface ColorBuilder {
  red?: number;
  green?: number;
  blue?: number;
  alpha?: number;
}

interface ExpandedColorBuilder {
  space?: "rgb" | "gray";
  components: number[];
}

type Token =
  | { kind: "open" }
  | { kind: "close" }
  | { kind: "control"; word: string; parameter?: number }
  | { kind: "symbol"; symbol: string }
  | { kind: "hex"; value: number }
  | { kind: "binary" }
  | { kind: "text"; value: string };

const MAX_RTF_SOURCE_LENGTH = 16 * 1024 * 1024;
const MAX_GROUP_DEPTH = 512;
const DEFAULT_ANSI_CODE_PAGE = 1252;

const SKIPPED_DESTINATIONS = new Set([
  "annotation",
  "atnauthor",
  "atnid",
  "author",
  "background",
  "category",
  "comment",
  "company",
  "creatim",
  "datafield",
  "doccomm",
  "docvar",
  "filetbl",
  "fldinst",
  "footer",
  "footerf",
  "footerl",
  "footerr",
  "footnote",
  "generator",
  "header",
  "headerf",
  "headerl",
  "headerr",
  "info",
  "keywords",
  "listoverridetable",
  "listtable",
  "manager",
  "nonshppict",
  "object",
  "operator",
  "pict",
  "printim",
  "private",
  "revtim",
  "shppict",
  "stylesheet",
  "subject",
  "template",
  "title",
  "xmlnstbl",
]);

function fallbackResult(fallbackText: string): RTFParseResult {
  return { text: fallbackText, runs: [], isValid: false };
}

function finiteInteger(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value)) return undefined;
  return Math.trunc(value);
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}

function cloneStyle(state: ParserStyle): ParserStyle {
  return {
    fontIndex: state.fontIndex,
    fontSize: state.fontSize,
    bold: state.bold,
    italic: state.italic,
    underline: state.underline,
    colorIndex: state.colorIndex,
  };
}

function sameParserStyle(left: ParserStyle, right: ParserStyle): boolean {
  return (
    left.fontIndex === right.fontIndex &&
    left.fontSize === right.fontSize &&
    left.bold === right.bold &&
    left.italic === right.italic &&
    left.underline === right.underline &&
    left.colorIndex === right.colorIndex
  );
}

function tokenize(source: string): Token[] | undefined {
  const tokens: Token[] = [];
  let index = 0;

  while (index < source.length) {
    const character = source[index]!;
    if (character === "{") {
      tokens.push({ kind: "open" });
      index += 1;
      continue;
    }
    if (character === "}") {
      tokens.push({ kind: "close" });
      index += 1;
      continue;
    }
    if (character !== "\\") {
      const start = index;
      while (
        index < source.length &&
        source[index] !== "{" &&
        source[index] !== "}" &&
        source[index] !== "\\"
      ) {
        index += 1;
      }
      tokens.push({ kind: "text", value: source.slice(start, index) });
      continue;
    }

    index += 1;
    if (index >= source.length) return undefined;
    const next = source[index]!;

    if (next === "\r" || next === "\n") {
      if (next === "\r" && source[index + 1] === "\n") index += 1;
      index += 1;
      tokens.push({ kind: "symbol", symbol: "\n" });
      continue;
    }

    if (next === "'") {
      const hexadecimal = source.slice(index + 1, index + 3);
      if (!/^[0-9A-Fa-f]{2}$/.test(hexadecimal)) return undefined;
      tokens.push({ kind: "hex", value: Number.parseInt(hexadecimal, 16) });
      index += 3;
      continue;
    }

    if (!/[A-Za-z]/.test(next)) {
      tokens.push({ kind: "symbol", symbol: next });
      index += 1;
      continue;
    }

    const wordStart = index;
    while (index < source.length && /[A-Za-z]/.test(source[index]!)) index += 1;
    const word = source.slice(wordStart, index).toLowerCase();
    const parameterStart = index;
    if (source[index] === "-") index += 1;
    const digitStart = index;
    while (index < source.length && /[0-9]/.test(source[index]!)) index += 1;
    let parameter: number | undefined;
    if (index > digitStart) {
      parameter = Number.parseInt(source.slice(parameterStart, index), 10);
      if (!Number.isSafeInteger(parameter)) return undefined;
    } else if (source[parameterStart] === "-") {
      // A sign without a numeric parameter is malformed RTF.
      return undefined;
    }
    if (source[index] === " ") index += 1;
    tokens.push({ kind: "control", word, parameter });

    if (word === "bin" && parameter !== undefined) {
      if (parameter < 0 || index + parameter > source.length) return undefined;
      index += parameter;
      tokens.push({ kind: "binary" });
    }
  }

  return tokens;
}

function charsetEncoding(charset: number | undefined): string | undefined {
  switch (charset) {
    case 0:
      return "windows-1252";
    case 77:
      return "macintosh";
    case 128:
      return "shift_jis";
    case 129:
      return "euc-kr";
    case 134:
      return "gbk";
    case 136:
      return "big5";
    case 161:
      return "windows-1253";
    case 162:
      return "windows-1254";
    case 163:
      return "windows-1258";
    case 177:
      return "windows-1255";
    case 178:
      return "windows-1256";
    case 186:
      return "windows-1257";
    case 204:
      return "windows-1251";
    case 222:
      return "windows-874";
    case 238:
      return "windows-1250";
    default:
      return undefined;
  }
}

function codePageEncoding(codePage: number | undefined): string {
  switch (codePage) {
    case 65001:
      return "utf-8";
    case 932:
      return "shift_jis";
    case 936:
      return "gbk";
    case 949:
      return "euc-kr";
    case 950:
      return "big5";
    case 10000:
      return "macintosh";
    default:
      return `windows-${codePage ?? DEFAULT_ANSI_CODE_PAGE}`;
  }
}

function decodeBytes(bytes: readonly number[], encoding: string): string {
  if (bytes.length === 0) return "";
  try {
    return new TextDecoder(encoding, { fatal: false }).decode(Uint8Array.from(bytes));
  } catch {
    // WHATWG implementations are required to provide windows-1252. It is a
    // safe final fallback for an unknown legacy RTF code page.
    try {
      return new TextDecoder("windows-1252", { fatal: false }).decode(
        Uint8Array.from(bytes),
      );
    } catch {
      return String.fromCharCode(...bytes);
    }
  }
}

function normalizedColor(color: RGBAColor): RGBAColor {
  return {
    red: clamp(Number.isFinite(color.red) ? color.red : 0, 0, 1),
    green: clamp(Number.isFinite(color.green) ? color.green : 0, 0, 1),
    blue: clamp(Number.isFinite(color.blue) ? color.blue : 0, 0, 1),
    alpha: clamp(Number.isFinite(color.alpha) ? color.alpha : 1, 0, 1),
  };
}

function colorsEqual(left: RGBAColor | undefined, right: RGBAColor | undefined): boolean {
  if (left === undefined || right === undefined) return left === right;
  return (
    left.red === right.red &&
    left.green === right.green &&
    left.blue === right.blue &&
    left.alpha === right.alpha
  );
}

function buildCharacterOffsets(text: string): number[] {
  const offsets = new Array<number>(text.length + 1);
  let characterIndex = 0;
  let utf16Index = 0;
  while (utf16Index < text.length) {
    offsets[utf16Index] = characterIndex;
    const first = text.charCodeAt(utf16Index);
    if (
      first >= 0xd800 &&
      first <= 0xdbff &&
      utf16Index + 1 < text.length &&
      text.charCodeAt(utf16Index + 1) >= 0xdc00 &&
      text.charCodeAt(utf16Index + 1) <= 0xdfff
    ) {
      offsets[utf16Index + 1] = characterIndex;
      utf16Index += 2;
    } else {
      utf16Index += 1;
    }
    characterIndex += 1;
  }
  offsets[text.length] = characterIndex;
  return offsets;
}

function parseInternal(
  source: string,
  fallbackText: string,
  byteSource: boolean,
): RTFParseResult {
  if (
    source.length === 0 ||
    source.length > MAX_RTF_SOURCE_LENGTH ||
    !/^\ufeff?\s*\{\\rtf(?:-?\d+)?(?:[\\\s{}]|$)/i.test(source)
  ) {
    return fallbackResult(fallbackText);
  }

  const tokens = tokenize(source);
  if (!tokens) return fallbackResult(fallbackText);

  let state: ParserState = {
    destination: "body",
    unicodeFallbackLength: 1,
    bold: false,
    italic: false,
    underline: false,
    ignorableDestination: false,
  };
  const stack: ParserState[] = [];
  const internalRuns: InternalRun[] = [];
  const output: string[] = [];
  const fonts = new Map<number, FontDefinition>();
  const standardColors: Array<RGBAColor | undefined> = [];
  const expandedColors: Array<RGBAColor | undefined> = [];
  let standardColor: ColorBuilder = {};
  let expandedColor: ExpandedColorBuilder = { components: [] };
  let ansiCodePage = DEFAULT_ANSI_CODE_PAGE;
  let defaultFontIndex: number | undefined;
  let outputLength = 0;
  let unicodeFallbackRemaining = 0;
  let rootOpened = false;
  let rootClosed = false;
  let malformed = false;
  let pendingHexBytes: number[] = [];
  let pendingHexState: ParserState | undefined;

  const currentFontDefinition = (forState: ParserState): FontDefinition | undefined => {
    if (forState.destination === "fonttbl" && forState.fontDefinitionIndex !== undefined) {
      return fonts.get(forState.fontDefinitionIndex);
    }
    const fontIndex = forState.fontIndex ?? defaultFontIndex;
    return fontIndex === undefined ? undefined : fonts.get(fontIndex);
  };

  const encodingForState = (forState: ParserState): string => {
    const font = currentFontDefinition(forState);
    return (
      charsetEncoding(font?.charset) ??
      codePageEncoding(font?.codePage ?? ansiCodePage)
    );
  };

  const appendBodyText = (value: string, styleState: ParserState): void => {
    if (value.length === 0) return;
    const style = cloneStyle(styleState);
    const previous = internalRuns.at(-1);
    if (
      previous &&
      previous.start + previous.length === outputLength &&
      sameParserStyle(previous.style, style)
    ) {
      previous.length += value.length;
    } else {
      internalRuns.push({ start: outputLength, length: value.length, style });
    }
    output.push(value);
    outputLength += value.length;
  };

  const appendFontNameText = (value: string, styleState: ParserState): void => {
    const index = styleState.fontDefinitionIndex;
    if (index === undefined || value.length === 0) return;
    const definition = fonts.get(index) ?? { name: "" };
    const terminator = value.indexOf(";");
    const namePart = terminator < 0 ? value : value.slice(0, terminator);
    definition.name += namePart;
    fonts.set(index, definition);
  };

  const finishStandardColor = (): void => {
    const hasComponents =
      standardColor.red !== undefined ||
      standardColor.green !== undefined ||
      standardColor.blue !== undefined ||
      standardColor.alpha !== undefined;
    standardColors.push(
      hasComponents
        ? {
            red: clamp(standardColor.red ?? 0, 0, 255) / 255,
            green: clamp(standardColor.green ?? 0, 0, 255) / 255,
            blue: clamp(standardColor.blue ?? 0, 0, 255) / 255,
            alpha: clamp(standardColor.alpha ?? 255, 0, 255) / 255,
          }
        : undefined,
    );
    standardColor = {};
  };

  const finishExpandedColor = (): void => {
    const components = expandedColor.components;
    if (components.length === 0) {
      expandedColors.push(undefined);
    } else if (expandedColor.space === "gray") {
      const gray = clamp(components[0] ?? 0, 0, 100_000) / 100_000;
      expandedColors.push({
        red: gray,
        green: gray,
        blue: gray,
        alpha: clamp(components[1] ?? 100_000, 0, 100_000) / 100_000,
      });
    } else {
      expandedColors.push({
        red: clamp(components[0] ?? 0, 0, 100_000) / 100_000,
        green: clamp(components[1] ?? 0, 0, 100_000) / 100_000,
        blue: clamp(components[2] ?? 0, 0, 100_000) / 100_000,
        alpha: clamp(components[3] ?? 100_000, 0, 100_000) / 100_000,
      });
    }
    expandedColor = { components: [] };
  };

  const appendDestinationText = (value: string, styleState: ParserState): void => {
    if (styleState.destination === "body") {
      appendBodyText(value, styleState);
      return;
    }
    if (styleState.destination === "fonttbl") {
      appendFontNameText(value, styleState);
      return;
    }
    if (styleState.destination === "colortbl") {
      for (const character of value) if (character === ";") finishStandardColor();
      return;
    }
    if (styleState.destination === "expandedcolortbl") {
      for (const character of value) if (character === ";") finishExpandedColor();
    }
  };

  const flushPendingHex = (): void => {
    if (pendingHexBytes.length === 0 || !pendingHexState) return;
    appendDestinationText(
      decodeBytes(pendingHexBytes, encodingForState(pendingHexState)),
      pendingHexState,
    );
    pendingHexBytes = [];
    pendingHexState = undefined;
  };

  const meaningfulText = (value: string): string => value.replace(/[\r\n]/g, "");

  const consumeFallbackFromText = (value: string): string => {
    if (unicodeFallbackRemaining <= 0 || value.length === 0) return value;
    let index = 0;
    while (index < value.length && unicodeFallbackRemaining > 0) {
      const codePoint = value.codePointAt(index);
      index += codePoint !== undefined && codePoint > 0xffff ? 2 : 1;
      unicodeFallbackRemaining -= 1;
    }
    return value.slice(index);
  };

  const appendControlCharacter = (value: string): void => {
    if (unicodeFallbackRemaining > 0) {
      unicodeFallbackRemaining -= 1;
      return;
    }
    appendDestinationText(value, state);
  };

  const handleDestinationControl = (word: string): boolean => {
    if (word === "fonttbl") {
      state.destination = "fonttbl";
      state.ignorableDestination = false;
      return true;
    }
    if (word === "colortbl") {
      state.destination = "colortbl";
      state.ignorableDestination = false;
      return true;
    }
    if (word === "expandedcolortbl") {
      state.destination = "expandedcolortbl";
      state.ignorableDestination = false;
      return true;
    }
    if (SKIPPED_DESTINATIONS.has(word)) {
      state.destination = "skip";
      state.ignorableDestination = false;
      return true;
    }
    if (state.ignorableDestination) {
      state.destination = "skip";
      state.ignorableDestination = false;
      return true;
    }
    return false;
  };

  for (const token of tokens) {
    if (malformed) break;

    if (token.kind === "hex") {
      if (unicodeFallbackRemaining > 0) {
        unicodeFallbackRemaining -= 1;
      } else if (state.destination !== "skip") {
        if (pendingHexBytes.length === 0) pendingHexState = { ...state };
        pendingHexBytes.push(token.value);
      }
      continue;
    }

    flushPendingHex();

    if (token.kind === "open") {
      if (rootClosed || stack.length >= MAX_GROUP_DEPTH) {
        malformed = true;
        break;
      }
      stack.push(state);
      state = { ...state, ignorableDestination: false };
      rootOpened = true;
      continue;
    }

    if (token.kind === "close") {
      if (stack.length === 0) {
        malformed = true;
        break;
      }
      state = stack.pop()!;
      if (stack.length === 0) rootClosed = true;
      continue;
    }

    if (!rootOpened || rootClosed) {
      if (token.kind === "text" && /^\ufeff?\s*$/.test(token.value)) continue;
      malformed = true;
      break;
    }

    if (token.kind === "binary") continue;

    if (token.kind === "text") {
      if (state.destination === "skip") continue;
      const withoutFormattingNewlines = meaningfulText(token.value);
      const withoutUnicodeFallback = consumeFallbackFromText(withoutFormattingNewlines);
      const decoded =
        byteSource && /[\u0080-\u00ff]/.test(withoutUnicodeFallback)
          ? decodeBytes(
              [...withoutUnicodeFallback].map((character) => character.charCodeAt(0)),
              encodingForState(state),
            )
          : withoutUnicodeFallback;
      appendDestinationText(decoded, state);
      continue;
    }

    if (token.kind === "symbol") {
      if (token.symbol === "*") {
        state.ignorableDestination = true;
        continue;
      }
      if (state.destination === "skip") continue;
      switch (token.symbol) {
        case "\\":
        case "{":
        case "}":
          appendControlCharacter(token.symbol);
          break;
        case "~":
          appendControlCharacter("\u00a0");
          break;
        case "-":
          appendControlCharacter("\u00ad");
          break;
        case "_":
          appendControlCharacter("\u2011");
          break;
        case "\n":
          appendControlCharacter("\n");
          break;
        default:
          // Unknown control symbols carry no printable text.
          break;
      }
      continue;
    }

    const parameter = finiteInteger(token.parameter);
    if (handleDestinationControl(token.word)) continue;
    if (state.destination === "skip") continue;

    if (token.word === "ansicpg" && parameter !== undefined && parameter > 0) {
      ansiCodePage = parameter;
      continue;
    }
    if (token.word === "deff" && parameter !== undefined && parameter >= 0) {
      defaultFontIndex = parameter;
      continue;
    }

    if (state.destination === "fonttbl") {
      if (token.word === "f" && parameter !== undefined && parameter >= 0) {
        state.fontDefinitionIndex = parameter;
        if (!fonts.has(parameter)) fonts.set(parameter, { name: "" });
      } else if (
        token.word === "fcharset" &&
        parameter !== undefined &&
        state.fontDefinitionIndex !== undefined
      ) {
        const definition = fonts.get(state.fontDefinitionIndex) ?? { name: "" };
        definition.charset = parameter;
        fonts.set(state.fontDefinitionIndex, definition);
      } else if (
        token.word === "cpg" &&
        parameter !== undefined &&
        parameter > 0 &&
        state.fontDefinitionIndex !== undefined
      ) {
        const definition = fonts.get(state.fontDefinitionIndex) ?? { name: "" };
        definition.codePage = parameter;
        fonts.set(state.fontDefinitionIndex, definition);
      } else if (token.word === "uc" && parameter !== undefined && parameter >= 0) {
        state.unicodeFallbackLength = Math.min(parameter, 32);
      } else if (token.word === "u" && parameter !== undefined) {
        const codeUnit = ((parameter % 65_536) + 65_536) % 65_536;
        appendDestinationText(String.fromCharCode(codeUnit), state);
        unicodeFallbackRemaining = state.unicodeFallbackLength;
      }
      continue;
    }

    if (state.destination === "colortbl") {
      if (parameter !== undefined) {
        if (token.word === "red") standardColor.red = parameter;
        else if (token.word === "green") standardColor.green = parameter;
        else if (token.word === "blue") standardColor.blue = parameter;
        else if (token.word === "alpha") standardColor.alpha = parameter;
      }
      continue;
    }

    if (state.destination === "expandedcolortbl") {
      if (token.word === "cssrgb" || token.word === "csgenericrgb") {
        expandedColor.space = "rgb";
      } else if (token.word === "csgray") {
        expandedColor.space = "gray";
      } else if (token.word === "c" && parameter !== undefined) {
        expandedColor.components.push(parameter);
      }
      continue;
    }

    switch (token.word) {
      case "f":
        if (parameter !== undefined && parameter >= 0) state.fontIndex = parameter;
        break;
      case "fs":
        if (parameter !== undefined && parameter > 0) state.fontSize = parameter / 2;
        break;
      case "b":
        state.bold = parameter !== 0;
        break;
      case "i":
        state.italic = parameter !== 0;
        break;
      case "ul":
        state.underline = parameter !== 0;
        break;
      case "ulnone":
        state.underline = false;
        break;
      case "cf":
        state.colorIndex = parameter !== undefined && parameter > 0 ? parameter : undefined;
        break;
      case "plain":
        state.fontIndex = defaultFontIndex;
        state.fontSize = undefined;
        state.bold = false;
        state.italic = false;
        state.underline = false;
        state.colorIndex = undefined;
        break;
      case "uc":
        if (parameter !== undefined && parameter >= 0) {
          state.unicodeFallbackLength = Math.min(parameter, 32);
        }
        break;
      case "u":
        if (parameter !== undefined) {
          const codeUnit = ((parameter % 65_536) + 65_536) % 65_536;
          appendDestinationText(String.fromCharCode(codeUnit), state);
          unicodeFallbackRemaining = state.unicodeFallbackLength;
        }
        break;
      case "par":
      case "line":
        appendControlCharacter("\n");
        break;
      case "tab":
        appendControlCharacter("\t");
        break;
      case "emdash":
        appendControlCharacter("\u2014");
        break;
      case "endash":
        appendControlCharacter("\u2013");
        break;
      case "bullet":
        appendControlCharacter("\u2022");
        break;
      case "lquote":
        appendControlCharacter("\u2018");
        break;
      case "rquote":
        appendControlCharacter("\u2019");
        break;
      case "ldblquote":
        appendControlCharacter("\u201c");
        break;
      case "rdblquote":
        appendControlCharacter("\u201d");
        break;
      default:
        break;
    }
  }

  flushPendingHex();
  if (malformed || !rootOpened || !rootClosed || stack.length !== 0) {
    return fallbackResult(fallbackText);
  }

  const text = output.join("");
  if (text.length !== outputLength) return fallbackResult(fallbackText);

  const colors = standardColors.map(
    (standard, index) => expandedColors[index] ?? standard,
  );
  for (let index = standardColors.length; index < expandedColors.length; index += 1) {
    colors[index] = expandedColors[index];
  }
  const characterOffsets = buildCharacterOffsets(text);
  const runs: RTFStyleRun[] = internalRuns.map((run) => {
    const fontIndex = run.style.fontIndex ?? defaultFontIndex;
    const fontName =
      fontIndex === undefined ? undefined : fonts.get(fontIndex)?.name.trim() || undefined;
    const foreground =
      run.style.colorIndex === undefined ? undefined : colors[run.style.colorIndex];
    return {
      start: run.start,
      length: run.length,
      characterStart: characterOffsets[run.start] ?? 0,
      characterLength:
        (characterOffsets[run.start + run.length] ?? characterOffsets.at(-1) ?? 0) -
        (characterOffsets[run.start] ?? 0),
      ...(fontName ? { fontName } : {}),
      ...(run.style.fontSize !== undefined ? { fontSize: run.style.fontSize } : {}),
      bold: run.style.bold,
      italic: run.style.italic,
      underline: run.style.underline,
      ...(foreground ? { foreground: normalizedColor(foreground) } : {}),
    };
  });

  return { text, runs, isValid: true };
}

/** Parses an RTF source string without ever throwing on malformed input. */
export function parseRTF(rtf: string, fallbackText = ""): RTFParseResult {
  try {
    return parseInternal(String(rtf), fallbackText, false);
  } catch {
    return fallbackResult(fallbackText);
  }
}

/** Parses Swift `Data`'s standard base64 JSON representation of RTF bytes. */
export function parseBase64RTF(
  base64RTF: string | null | undefined,
  fallbackText = "",
): RTFParseResult {
  if (typeof base64RTF !== "string") return fallbackResult(fallbackText);
  try {
    const compact = base64RTF.replace(/\s+/g, "");
    if (
      compact.length === 0 ||
      compact.length > Math.ceil((MAX_RTF_SOURCE_LENGTH * 4) / 3) + 4 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(compact) ||
      compact.slice(0, -2).includes("=") ||
      compact.length % 4 === 1
    ) {
      return fallbackResult(fallbackText);
    }
    const padded = compact.padEnd(compact.length + ((4 - (compact.length % 4)) % 4), "=");
    const binary = atob(padded);
    if (binary.length > MAX_RTF_SOURCE_LENGTH) return fallbackResult(fallbackText);
    return parseInternal(binary, fallbackText, true);
  } catch {
    return fallbackResult(fallbackText);
  }
}

interface SerializableStyle {
  fontName?: string;
  fontSize?: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  foreground?: RGBAColor;
}

interface SerializableSegment {
  start: number;
  end: number;
  style: SerializableStyle;
}

function sameSerializableStyle(left: SerializableStyle, right: SerializableStyle): boolean {
  return (
    left.fontName === right.fontName &&
    left.fontSize === right.fontSize &&
    left.bold === right.bold &&
    left.italic === right.italic &&
    left.underline === right.underline &&
    colorsEqual(left.foreground, right.foreground)
  );
}

function normalizeRunStyle(run: RTFStyleRun): SerializableStyle {
  const name = typeof run.fontName === "string" ? run.fontName.trim() : "";
  const size =
    typeof run.fontSize === "number" && Number.isFinite(run.fontSize) && run.fontSize > 0
      ? run.fontSize
      : undefined;
  return {
    ...(name ? { fontName: name } : {}),
    ...(size !== undefined ? { fontSize: size } : {}),
    bold: run.bold === true,
    italic: run.italic === true,
    underline: run.underline === true,
    ...(run.foreground ? { foreground: normalizedColor(run.foreground) } : {}),
  };
}

function safeUTF16Boundary(text: string, index: number, towardEnd: boolean): number {
  const bounded = clamp(Math.trunc(index), 0, text.length);
  if (bounded <= 0 || bounded >= text.length) return bounded;
  const before = text.charCodeAt(bounded - 1);
  const after = text.charCodeAt(bounded);
  if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) {
    return towardEnd ? bounded + 1 : bounded - 1;
  }
  return bounded;
}

function serializableSegments(
  text: string,
  runs: readonly RTFStyleRun[],
): SerializableSegment[] {
  const normalizedRuns = runs
    .map((run, order) => {
      const rawStart = Number.isFinite(run.start) ? run.start : 0;
      const rawLength = Number.isFinite(run.length) ? run.length : 0;
      const start = safeUTF16Boundary(text, rawStart, false);
      const end = safeUTF16Boundary(text, rawStart + Math.max(0, rawLength), true);
      return { start, end, order, style: normalizeRunStyle(run) };
    })
    .filter((run) => run.end > run.start);

  const boundaries = new Set<number>([0, text.length]);
  for (const run of normalizedRuns) {
    boundaries.add(run.start);
    boundaries.add(run.end);
  }
  const sorted = [...boundaries].sort((left, right) => left - right);
  const segments: SerializableSegment[] = [];

  for (let index = 0; index + 1 < sorted.length; index += 1) {
    const start = sorted[index]!;
    const end = sorted[index + 1]!;
    if (end <= start) continue;
    const style: SerializableStyle = {
      bold: false,
      italic: false,
      underline: false,
    };
    for (const run of normalizedRuns) {
      if (run.start > start || run.end < end) continue;
      if (run.style.fontName !== undefined) style.fontName = run.style.fontName;
      if (run.style.fontSize !== undefined) style.fontSize = run.style.fontSize;
      style.bold = run.style.bold;
      style.italic = run.style.italic;
      style.underline = run.style.underline;
      if (run.style.foreground !== undefined) style.foreground = run.style.foreground;
    }
    const previous = segments.at(-1);
    if (previous && previous.end === start && sameSerializableStyle(previous.style, style)) {
      previous.end = end;
    } else {
      segments.push({ start, end, style });
    }
  }

  return segments;
}

function encodeRTFText(value: string): string {
  let encoded = "";
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    const character = value[index]!;
    if (character === "\\" || character === "{" || character === "}") {
      encoded += `\\${character}`;
    } else if (character === "\r") {
      if (value[index + 1] === "\n") index += 1;
      encoded += "\\line ";
    } else if (character === "\n") {
      encoded += "\\line ";
    } else if (character === "\t") {
      encoded += "\\tab ";
    } else if (codeUnit >= 0x20 && codeUnit <= 0x7e) {
      encoded += character;
    } else {
      const signed = codeUnit > 0x7fff ? codeUnit - 0x10000 : codeUnit;
      encoded += `\\u${signed} `;
    }
  }
  return encoded;
}

function fontTableName(value: string): string {
  // A semicolon terminates an RTF font-table entry and is not a legal part of
  // the table name itself. Removing it is safer than producing corrupt RTF.
  return encodeRTFText(value.replaceAll(";", ""));
}

/** Serializes UTF-16 style ranges to portable, Cocoa-readable RTF text. */
export function serializeRTF(text: string, runs: readonly RTFStyleRun[]): string {
  const safeText = String(text);
  const segments = serializableSegments(safeText, runs);
  const fontNames: string[] = [];
  const fontIndices = new Map<string, number>();
  const colors: RGBAColor[] = [];
  const colorIndices = new Map<string, number>();

  for (const segment of segments) {
    const fontName = segment.style.fontName;
    if (fontName) {
      const key = fontName.toLocaleLowerCase("en-US");
      if (!fontIndices.has(key)) {
        fontIndices.set(key, fontNames.length);
        fontNames.push(fontName);
      }
    }
    const foreground = segment.style.foreground;
    if (foreground) {
      const color = normalizedColor(foreground);
      const key = [color.red, color.green, color.blue, color.alpha]
        .map((component) => Math.round(component * 100_000))
        .join(":");
      if (!colorIndices.has(key)) {
        colorIndices.set(key, colors.length + 1);
        colors.push(color);
      }
    }
  }

  let rtf = "{\\rtf1\\ansi\\ansicpg1252\\uc0";
  if (fontNames.length > 0) {
    rtf += "{\\fonttbl";
    for (let index = 0; index < fontNames.length; index += 1) {
      rtf += `{\\f${index}\\fnil\\fcharset0 ${fontTableName(fontNames[index]!)};}`;
    }
    rtf += "}";
  }
  if (colors.length > 0) {
    rtf += "{\\colortbl;";
    for (const color of colors) {
      rtf += `\\red${Math.round(color.red * 255)}\\green${Math.round(color.green * 255)}\\blue${Math.round(color.blue * 255)};`;
    }
    rtf += "}";
    rtf += "{\\*\\expandedcolortbl;";
    for (const color of colors) {
      rtf += `\\csgenericrgb\\c${Math.round(color.red * 100_000)}\\c${Math.round(color.green * 100_000)}\\c${Math.round(color.blue * 100_000)}\\c${Math.round(color.alpha * 100_000)};`;
    }
    rtf += "}";
  }

  for (const segment of segments) {
    const controls: string[] = [];
    if (segment.style.fontName) {
      controls.push(`\\f${fontIndices.get(segment.style.fontName.toLocaleLowerCase("en-US"))!}`);
    }
    if (segment.style.fontSize !== undefined) {
      controls.push(`\\fs${Math.max(1, Math.round(segment.style.fontSize * 2))}`);
    }
    if (segment.style.bold) controls.push("\\b");
    if (segment.style.italic) controls.push("\\i");
    if (segment.style.underline) controls.push("\\ul");
    if (segment.style.foreground) {
      const color = normalizedColor(segment.style.foreground);
      const key = [color.red, color.green, color.blue, color.alpha]
        .map((component) => Math.round(component * 100_000))
        .join(":");
      controls.push(`\\cf${colorIndices.get(key)!}`);
    }
    rtf += `{${controls.join("")}${controls.length > 0 ? " " : ""}${encodeRTFText(
      safeText.slice(segment.start, segment.end),
    )}}`;
  }
  rtf += "}";
  return rtf;
}

/** Serializes RTF and encodes it like Swift `Data` in project JSON. */
export function serializeBase64RTF(
  text: string,
  runs: readonly RTFStyleRun[],
): string {
  return btoa(serializeRTF(text, runs));
}
