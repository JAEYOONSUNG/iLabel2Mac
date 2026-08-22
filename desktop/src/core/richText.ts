import type {
  LabelElement,
  MergeContext,
  RGBAColor,
  SerialSettings,
} from "../types";
import { resolveTokens } from "./merge";
import {
  parseBase64RTF,
  type RTFStyleRun,
} from "./rtf";

export interface ResolvedRichText {
  text: string;
  runs: RTFStyleRun[];
  sourceWasRichText: boolean;
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}

function colorKey(color: RGBAColor | undefined): string {
  if (!color) return "";
  return [color.red, color.green, color.blue, color.alpha]
    .map((value) => Math.round(value * 1000))
    .join(":");
}

function styleKey(run: RTFStyleRun): string {
  return JSON.stringify({
    fontName: run.fontName,
    fontSize: run.fontSize,
    bold: run.bold,
    italic: run.italic,
    underline: run.underline,
    foreground: run.foreground && colorKey(run.foreground),
  });
}

function elementStyle(element: LabelElement): Omit<RTFStyleRun, "start" | "length"> {
  return {
    fontName: element.fontName || "Arial",
    fontSize: Math.max(0.1, element.fontSize),
    bold: element.isBold,
    italic: element.isItalic,
    underline: element.isUnderline,
    foreground: { ...element.foreground },
  };
}

function appendRun(
  output: RTFStyleRun[],
  start: number,
  length: number,
  style: Omit<RTFStyleRun, "start" | "length" | "characterStart" | "characterLength">,
): void {
  if (length <= 0) return;
  const run: RTFStyleRun = { ...style, start, length };
  const previous = output.at(-1);
  if (
    previous &&
    previous.start + previous.length === start &&
    styleKey(previous) === styleKey(run)
  ) {
    previous.length += length;
  } else {
    output.push(run);
  }
}

/**
 * Returns complete, gap-free UTF-16 runs using the same precedence as the
 * native AppKit renderer. A single RTF color remains element-wide, while a
 * deliberately multi-color RTF keeps each selection color.
 */
export function elementRichText(element: LabelElement): ResolvedRichText {
  const fallback = elementStyle(element);
  const parsed = parseBase64RTF(element.richTextRTF, element.content);
  if (!parsed.isValid || parsed.text !== element.content || parsed.runs.length === 0) {
    return {
      text: element.content,
      runs: element.content.length > 0
        ? [{ start: 0, length: element.content.length, ...fallback }]
        : [],
      sourceWasRichText: false,
    };
  }

  const distinctColors = new Set(
    parsed.runs
      .map((run) => colorKey(run.foreground))
      .filter(Boolean),
  );
  const keepSelectionColors = distinctColors.size > 1;
  const sorted = [...parsed.runs].sort((left, right) => left.start - right.start);
  const runs: RTFStyleRun[] = [];
  let cursor = 0;
  for (const candidate of sorted) {
    const start = clamp(Math.trunc(candidate.start), 0, element.content.length);
    const end = clamp(
      Math.trunc(candidate.start + candidate.length),
      start,
      element.content.length,
    );
    if (start > cursor) appendRun(runs, cursor, start - cursor, fallback);
    const normalizedStart = Math.max(start, cursor);
    if (end > normalizedStart) {
      appendRun(runs, normalizedStart, end - normalizedStart, {
        fontName: candidate.fontName || fallback.fontName,
        fontSize: Math.max(0.1, candidate.fontSize ?? fallback.fontSize ?? 12),
        bold: candidate.bold ?? fallback.bold,
        italic: candidate.italic ?? fallback.italic,
        underline: candidate.underline ?? fallback.underline,
        foreground: keepSelectionColors
          ? { ...(candidate.foreground ?? fallback.foreground!) }
          : { ...element.foreground },
      });
      cursor = end;
    }
  }
  if (cursor < element.content.length) {
    appendRun(runs, cursor, element.content.length - cursor, fallback);
  }
  return { text: element.content, runs, sourceWasRichText: true };
}

function runAt(runs: readonly RTFStyleRun[], index: number): RTFStyleRun | undefined {
  return runs.find((run) => index >= run.start && index < run.start + run.length)
    ?? runs.at(-1);
}

/** Resolve merge tokens while copying the token's first run to its value. */
export function resolveElementRichText(
  element: LabelElement,
  context: MergeContext,
  serialSettings: SerialSettings,
  now = new Date(),
): ResolvedRichText {
  const source = elementRichText(element);
  const pattern = /\{\{\s*([^}]+?)\s*\}\}/g;
  const runs: RTFStyleRun[] = [];
  let text = "";
  let cursor = 0;

  const appendSourceRange = (start: number, end: number): void => {
    if (end <= start) return;
    const outputStart = text.length;
    text += source.text.slice(start, end);
    for (const run of source.runs) {
      const intersectionStart = Math.max(start, run.start);
      const intersectionEnd = Math.min(end, run.start + run.length);
      if (intersectionEnd <= intersectionStart) continue;
      appendRun(
        runs,
        outputStart + intersectionStart - start,
        intersectionEnd - intersectionStart,
        run,
      );
    }
  };

  for (const match of source.text.matchAll(pattern)) {
    const start = match.index;
    const end = start + match[0].length;
    appendSourceRange(cursor, start);
    const replacement = resolveTokens(
      match[0],
      context,
      serialSettings,
      now,
    );
    const style = runAt(source.runs, start) ?? elementStyle(element);
    const outputStart = text.length;
    text += replacement;
    appendRun(runs, outputStart, replacement.length, style);
    cursor = end;
  }
  appendSourceRange(cursor, source.text.length);
  return { text, runs, sourceWasRichText: source.sourceWasRichText };
}

export function runStyleAt(
  runs: readonly RTFStyleRun[],
  index: number,
): Omit<RTFStyleRun, "start" | "length" | "characterStart" | "characterLength"> {
  const run = runAt(runs, index);
  return run ? {
    fontName: run.fontName,
    fontSize: run.fontSize,
    bold: run.bold,
    italic: run.italic,
    underline: run.underline,
    foreground: run.foreground && { ...run.foreground },
  } : {};
}
