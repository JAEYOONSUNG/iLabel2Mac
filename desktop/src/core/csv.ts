import type { DataTable } from "../types";

export type CSVParseErrorCode = "unreadableText" | "emptyFile";

export class CSVParseError extends Error {
  readonly code: CSVParseErrorCode;

  constructor(code: CSVParseErrorCode, message?: string) {
    super(
      message ??
        (code === "emptyFile"
          ? "The selected CSV file is empty."
          : "The selected file could not be decoded as text."),
    );
    this.name = "CSVParseError";
    this.code = code;
  }
}

const DELIMITER_CANDIDATES = [",", "\t", ";", "|"] as const;

export function detectCSVDelimiter(text: string): string {
  const firstLine = text.split(/\r?\n/, 1)[0] ?? text;
  let best: string = DELIMITER_CANDIDATES[0];
  let bestCount = -1;
  for (const candidate of DELIMITER_CANDIDATES) {
    let count = 0;
    for (const character of firstLine) {
      if (character === candidate) count += 1;
    }
    if (count > bestCount) {
      best = candidate;
      bestCount = count;
    }
  }
  return best;
}

export function tokenizeCSV(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let currentRow: string[] = [];
  let currentField = "";
  let inQuotes = false;

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (inQuotes) {
      if (character === '"') {
        if (text[index + 1] === '"') {
          currentField += '"';
          index += 1;
        } else {
          inQuotes = false;
        }
      } else {
        currentField += character;
      }
      continue;
    }

    if (character === '"') {
      inQuotes = true;
    } else if (character === delimiter) {
      currentRow.push(currentField);
      currentField = "";
    } else if (character === "\n") {
      currentRow.push(currentField);
      rows.push(currentRow);
      currentRow = [];
      currentField = "";
    } else if (character !== "\r") {
      currentField += character;
    }
  }

  currentRow.push(currentField);
  rows.push(currentRow);
  return rows;
}

/**
 * Parse CSV/TSV/semicolon/pipe-delimited text using the same delimiter and
 * quoting behavior as CSVParser.swift.
 */
export function parseCSV(text: string): DataTable {
  if (typeof text !== "string") {
    throw new CSVParseError("unreadableText");
  }

  // `String.trim()` also removes a leading UTF-8 BOM, which is desirable for
  // spreadsheet CSV exports and otherwise matches Swift's whole-file trim.
  const trimmed = text.trim();
  if (trimmed.length === 0) throw new CSVParseError("emptyFile");

  const delimiter = detectCSVDelimiter(trimmed);
  const rows = tokenizeCSV(trimmed, delimiter).filter(
    (row) => !row.every((value) => value.trim().length === 0),
  );
  const headerRow = rows[0];
  if (!headerRow) throw new CSVParseError("emptyFile");

  const headers = headerRow.map((value, index) => {
    const candidate = value.trim();
    return candidate.length === 0 ? `Column${index + 1}` : candidate;
  });

  const bodyRows = rows.slice(1).map((row) => {
    const mapped: Record<string, string> = {};
    headers.forEach((header, index) => {
      mapped[header] = row[index] ?? "";
    });
    return mapped;
  });

  return { headers, rows: bodyRows };
}
