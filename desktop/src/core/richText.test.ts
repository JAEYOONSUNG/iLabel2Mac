import { describe, expect, it } from "vitest";

import { makeElement } from "../defaults";
import type { MergeContext } from "../types";
import { elementRichText, resolveElementRichText } from "./richText";
import { serializeBase64RTF } from "./rtf";

const CONTEXT: MergeContext = {
  row: {},
  serialValue: 7,
  rowNumber: 1,
  pageNumber: 1,
  slotNumber: 1,
  isActive: true,
};

describe("element rich text", () => {
  it("keeps deliberate multi-color selection runs", () => {
    const element = makeElement("text");
    element.content = "ABC";
    element.richTextRTF = serializeBase64RTF(element.content, [
      { start: 0, length: 1, fontName: "Arial", fontSize: 10, foreground: { red: 1, green: 0, blue: 0, alpha: 1 } },
      { start: 1, length: 2, fontName: "Courier", fontSize: 16, bold: true, foreground: { red: 0, green: 0, blue: 1, alpha: 1 } },
    ]);

    const result = elementRichText(element);
    expect(result.sourceWasRichText).toBe(true);
    expect(result.runs).toMatchObject([
      { start: 0, length: 1, fontName: "Arial", foreground: { red: 1, green: 0, blue: 0, alpha: 1 } },
      { start: 1, length: 2, fontName: "Courier", fontSize: 16, bold: true, foreground: { red: 0, green: 0, blue: 1, alpha: 1 } },
    ]);
  });

  it("lets the element color override a single legacy run color", () => {
    const element = makeElement("text");
    element.content = "ABC";
    element.foreground = { red: 0.2, green: 0.7, blue: 0.1, alpha: 1 };
    element.richTextRTF = serializeBase64RTF(element.content, [
      { start: 0, length: 3, fontName: "Arial", foreground: { red: 1, green: 0, blue: 0, alpha: 1 } },
    ]);
    expect(elementRichText(element).runs[0]?.foreground).toEqual(element.foreground);
  });

  it("copies token-start styling to the resolved replacement", () => {
    const element = makeElement("text");
    element.content = "A{{serial}}B";
    element.richTextRTF = serializeBase64RTF(element.content, [
      { start: 0, length: 1, fontName: "Arial", fontSize: 10 },
      { start: 1, length: 10, fontName: "Courier", fontSize: 18, bold: true },
      { start: 11, length: 1, fontName: "Arial", fontSize: 10 },
    ]);
    const result = resolveElementRichText(element, CONTEXT, {
      mode: "rangedSets",
      start: 1,
      step: 1,
      end: 10,
      repeatSets: 1,
      digits: 2,
      prefix: "(",
      suffix: ")",
    }, new Date(2026, 7, 22));

    expect(result.text).toBe("A(07)B");
    expect(result.runs).toMatchObject([
      { start: 0, length: 1, fontName: "Arial" },
      { start: 1, length: 4, fontName: "Courier", fontSize: 18, bold: true },
      { start: 5, length: 1, fontName: "Arial" },
    ]);
  });
});
