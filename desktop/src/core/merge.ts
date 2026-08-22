import type { MergeContext, SerialSettings } from "../types";

export function serialCountPerSet(settings: SerialSettings): number {
  if (settings.step <= 0 || settings.end < settings.start) return 0;
  return Math.floor((settings.end - settings.start) / settings.step) + 1;
}

export function serialTotalGeneratedCount(settings: SerialSettings): number {
  if (settings.mode !== "rangedSets") return 0;
  const total = serialCountPerSet(settings) * Math.max(settings.repeatSets, 1);
  return Number.isSafeInteger(total) && total >= 0 ? total : Number.MAX_SAFE_INTEGER;
}

export function generatedSerialValue(
  settings: SerialSettings,
  index: number,
): number | null {
  if (settings.mode !== "rangedSets") return null;
  const countPerSet = serialCountPerSet(settings);
  const total = serialTotalGeneratedCount(settings);
  if (countPerSet <= 0 || index < 0 || index >= total) return null;
  return settings.start + (index % countPerSet) * settings.step;
}

export function formatSerialValue(settings: SerialSettings, value: number): string {
  const digits = Math.max(Math.trunc(settings.digits), 1);
  const integer = Math.trunc(value);
  const sign = integer < 0 ? "-" : "";
  // Swift's `%0Nd` includes the sign in the requested width.
  const magnitudeWidth = Math.max(0, digits - sign.length);
  const raw = `${sign}${Math.abs(integer).toString().padStart(magnitudeWidth, "0")}`;
  return `${settings.prefix}${raw}${settings.suffix}`;
}

function pad2(value: number): string {
  return value.toString().padStart(2, "0");
}

export function formatMergeDate(date: Date): string {
  return `${date.getFullYear()}.${pad2(date.getMonth() + 1)}.${pad2(date.getDate())}`;
}

export function formatMergeTime(date: Date): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/** Resolve the same case-insensitive `{{token}}` syntax as MergeRenderer.swift. */
export function resolveTokens(
  template: string,
  context: MergeContext,
  serialSettings: SerialSettings,
  now: Date = new Date(),
): string {
  const loweredRow = new Map<string, string>();
  for (const [key, value] of Object.entries(context.row)) {
    loweredRow.set(key.toLowerCase(), value);
  }

  return template.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, captured: string) => {
    const token = captured.trim().toLowerCase();
    switch (token) {
      case "serial":
        return context.serialValue === null
          ? ""
          : formatSerialValue(serialSettings, context.serialValue);
      case "serial_raw":
        return context.serialValue === null ? "" : String(context.serialValue);
      case "row":
        return context.isActive ? String(context.rowNumber) : "";
      case "page":
        return String(context.pageNumber);
      case "slot":
        return String(context.slotNumber);
      case "date":
        return formatMergeDate(now);
      case "time":
        return formatMergeTime(now);
      default:
        return loweredRow.get(token) ?? "";
    }
  });
}
