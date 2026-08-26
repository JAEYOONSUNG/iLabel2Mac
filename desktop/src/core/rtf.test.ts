import { describe, expect, it } from "vitest";

import type { RTFStyleRun } from "./rtf";
import {
  parseBase64RTF,
  parseRTF,
  serializeBase64RTF,
  serializeRTF,
} from "./rtf";

// Produced by `NSAttributedString.rtf(from:documentAttributes:)` on macOS.
// It deliberately combines Cocoa's expanded color table, cp949, Unicode,
// PostScript font names, and selection-level traits.
const COCOA_RTF_BASE64 =
  "e1xydGYxXGFuc2lcYW5zaWNwZzk0OVxjb2NvYXJ0ZjI4NzAKXGNvY29hdGV4dHNjYWxpbmcwXGNvY29hcGxhdGZvcm0we1xmb250dGJsXGYwXGZzd2lzc1xmY2hhcnNldDAgQXJpYWxNVDtcZjFcZnN3aXNzXGZjaGFyc2V0MCBBcmlhbC1Cb2xkSXRhbGljTVQ7fQp7XGNvbG9ydGJsO1xyZWQyNTVcZ3JlZW4yNTVcYmx1ZTI1NTtccmVkMFxncmVlbjBcYmx1ZTA7XHJlZDIwNFxncmVlbjI2XGJsdWU1MTt9CntcKlxleHBhbmRlZGNvbG9ydGJsOztcY3NncmF5XGMwO1xjc2dlbmVyaWNyZ2JcYzgwMDAwXGMxMDAwMFxjMjAwMDA7fQpccGFyZFx0eDU2MFx0eDExMjBcdHgxNjgwXHR4MjI0MFx0eDI4MDBcdHgzMzYwXHR4MzkyMFx0eDQ0ODBcdHg1MDQwXHR4NTYwMFx0eDYxNjBcdHg2NzIwXHBhcmRpcm5hdHVyYWxccGFydGlnaHRlbmZhY3RvcjAKClxmMFxmczI0IFxjZjIgSGVsbG8gXHVjMFx1NTQ2MjAgXHU0NDU0NCAgClxmMVxpXGJcZnMzNiBcY2YzIFx1bCBcdWxjMyBCb2xkIFJlZH0=";

describe("parseBase64RTF", () => {
  it("decodes real Cocoa RTF with selection-level fonts, traits, and colors", () => {
    const parsed = parseBase64RTF(COCOA_RTF_BASE64, "fallback");

    expect(parsed.isValid).toBe(true);
    expect(parsed.text).toBe("Hello 한글 Bold Red");
    expect(parsed.runs).toEqual([
      {
        start: 0,
        length: 9,
        characterStart: 0,
        characterLength: 9,
        fontName: "ArialMT",
        fontSize: 12,
        bold: false,
        italic: false,
        underline: false,
        foreground: { red: 0, green: 0, blue: 0, alpha: 1 },
      },
      {
        start: 9,
        length: 8,
        characterStart: 9,
        characterLength: 8,
        fontName: "Arial-BoldItalicMT",
        fontSize: 18,
        bold: true,
        italic: true,
        underline: true,
        foreground: { red: 0.8, green: 0.1, blue: 0.2, alpha: 1 },
      },
    ]);
  });

  it("falls back without throwing for invalid base64 and corrupt RTF", () => {
    expect(parseBase64RTF("not base64!", "safe")).toEqual({
      text: "safe",
      runs: [],
      isValid: false,
    });
    expect(parseBase64RTF(btoa("{\\rtf1 broken"), "safe")).toEqual({
      text: "safe",
      runs: [],
      isValid: false,
    });
    expect(parseBase64RTF(undefined, "safe").text).toBe("safe");
  });
});

describe("parseRTF", () => {
  it("inherits and restores formatting at group boundaries", () => {
    const rtf = String.raw`{\rtf1\ansi{\fonttbl{\f0\fnil Arial;}{\f1\fmodern Courier New;}}\f0\fs20 A{\f1\b\i\ul\fs30 B}\cf0 C}`;
    const parsed = parseRTF(rtf);

    expect(parsed.text).toBe("ABC");
    expect(parsed.runs).toMatchObject([
      {
        start: 0,
        length: 1,
        fontName: "Arial",
        fontSize: 10,
        bold: false,
        italic: false,
        underline: false,
      },
      {
        start: 1,
        length: 1,
        fontName: "Courier New",
        fontSize: 15,
        bold: true,
        italic: true,
        underline: true,
      },
      {
        start: 2,
        length: 1,
        fontName: "Arial",
        fontSize: 10,
        bold: false,
        italic: false,
        underline: false,
      },
    ]);
  });

  it("decodes consecutive hex bytes with each font's charset", () => {
    const rtf = String.raw`{\rtf1\ansi\ansicpg949{\fonttbl{\f0\fnil\fcharset129 AppleSDGothicNeo-Regular;}{\f1\fnil\fcharset0 CourierNewPSMT;}}\f0\fs24 \'b0\'a1 {\f1 caf\'e9 \{x\}\\}\par done}`;
    const parsed = parseRTF(rtf);

    expect(parsed.isValid).toBe(true);
    expect(parsed.text).toBe("가 café {x}\\\ndone");
    expect(parsed.runs[0]).toMatchObject({
      fontName: "AppleSDGothicNeo-Regular",
      fontSize: 12,
    });
    expect(parsed.runs[1]).toMatchObject({ fontName: "CourierNewPSMT" });
  });

  it("handles signed Unicode, fallback bytes, surrogate pairs, and character ranges", () => {
    const parsed = parseRTF(
      String.raw`{\rtf1\ansi\uc1 \u-10179?\u-8704? A{\uc0\u233} \u8211x}`,
    );

    expect(parsed.text).toBe("😀 Aé –");
    expect(parsed.runs).toHaveLength(1);
    expect(parsed.runs[0]).toMatchObject({
      start: 0,
      length: 7,
      characterStart: 0,
      characterLength: 6,
    });
  });

  it("supports paragraph/line controls, escaped syntax, and underline reset", () => {
    const parsed = parseRTF(
      String.raw`{\rtf1\ansi Start\par second\line \ul under\ulnone  \{literal\} \\ end}`,
    );

    expect(parsed.text).toBe("Start\nsecond\nunder {literal} \\ end");
    expect(parsed.runs.some((run) => run.underline)).toBe(true);
    expect(parsed.runs.at(-1)?.underline).toBe(false);
  });

  it("ignores metadata and unknown starred destinations", () => {
    const parsed = parseRTF(
      String.raw`{\rtf1{\info{\title Not body}}{\*\generator Hidden;}{\*\unknown Secret}Visible}`,
    );
    expect(parsed.text).toBe("Visible");
  });

  it("uses the supplied fallback for non-RTF and structurally invalid sources", () => {
    for (const source of ["plain text", "{\\rtf1 unclosed", "{\\rtf1 ok}}", "\\rtf1"]) {
      expect(() => parseRTF(source, "original")).not.toThrow();
      expect(parseRTF(source, "original")).toEqual({
        text: "original",
        runs: [],
        isValid: false,
      });
    }
  });
});

describe("RTF serialization", () => {
  it("round-trips UTF-16 ranges, Unicode, newlines, escaped syntax, and alpha", () => {
    const text = "A😀 {x}\\\n한B";
    const runs: RTFStyleRun[] = [
      {
        start: 0,
        length: 1,
        fontName: "Arial",
        fontSize: 12,
        foreground: { red: 0, green: 0, blue: 0, alpha: 1 },
      },
      {
        start: 1,
        length: 2,
        fontName: "Arial",
        fontSize: 12,
        bold: true,
        foreground: { red: 0.8, green: 0.1, blue: 0.2, alpha: 0.5 },
      },
      {
        start: 3,
        length: text.length - 3,
        fontName: "Courier New",
        fontSize: 16,
        italic: true,
        underline: true,
        foreground: { red: 0.1, green: 0.2, blue: 0.9, alpha: 1 },
      },
    ];

    const serialized = serializeRTF(text, runs);
    const reparsed = parseRTF(serialized);

    expect(serialized).toContain("\\uc0");
    expect(serialized).toContain("\\u-10179 \\u-8704 ");
    expect(serialized).toContain("\\line ");
    expect(serialized).toContain("\\{x\\}\\\\");
    expect(serialized.match(/\\f\d+\\fnil/g)).toHaveLength(2);
    expect(serialized.match(/\\red\d+/g)).toHaveLength(4); // reserved white + 3 colors
    expect(reparsed.text).toBe(text);
    expect(reparsed.runs).toHaveLength(3);
    expect(reparsed.runs[0]).toMatchObject({
      start: 0,
      length: 1,
      fontName: "Arial",
      fontSize: 12,
      bold: false,
    });
    expect(reparsed.runs[1]).toMatchObject({
      start: 1,
      length: 2,
      characterStart: 1,
      characterLength: 1,
      fontName: "Arial",
      bold: true,
      foreground: { red: 0.8, green: 0.1, blue: 0.2, alpha: 0.5 },
    });
    expect(reparsed.runs[2]).toMatchObject({
      start: 3,
      length: text.length - 3,
      fontName: "Courier New",
      fontSize: 16,
      italic: true,
      underline: true,
    });
  });

  it("deduplicates equivalent font and color table entries", () => {
    const red = { red: 1, green: 0, blue: 0, alpha: 0.75 };
    const blue = { red: 0, green: 0, blue: 1, alpha: 1 };
    const rtf = serializeRTF("ABCD", [
      { start: 0, length: 1, fontName: "Arial", foreground: red },
      { start: 1, length: 1, fontName: "Courier", foreground: blue },
      { start: 2, length: 1, fontName: "arial", foreground: red },
      { start: 3, length: 1, fontName: "Courier", foreground: blue },
    ]);

    expect(rtf.match(/\\f\d+\\fnil/g)).toHaveLength(2);
    expect(rtf.match(/\\red\d+/g)).toHaveLength(3); // reserved white + 2 colors
    expect(parseRTF(rtf).text).toBe("ABCD");
  });

  it("round-trips its base64 form and clamps broken ranges safely", () => {
    const text = "😀 label";
    const encoded = serializeBase64RTF(text, [
      {
        start: 1, // Deliberately bisects the surrogate pair; serializer expands it.
        length: 999,
        fontName: "나눔고딕",
        bold: true,
      },
    ]);
    const parsed = parseBase64RTF(encoded);

    expect(parsed.isValid).toBe(true);
    expect(parsed.text).toBe(text);
    expect(parsed.runs[0]).toMatchObject({
      start: 0,
      length: text.length,
      characterLength: 7,
      fontName: "나눔고딕",
      bold: true,
    });
  });
});

describe("RTF background colors", () => {
  it("round-trips a selection highlight through serialize and parse", () => {
    const yellow = { red: 1, green: 0.84, blue: 0.2, alpha: 1 };
    const rtf = serializeRTF("AB", [
      { start: 0, length: 1, bold: false, italic: false, underline: false },
      { start: 1, length: 1, bold: false, italic: false, underline: false, background: yellow },
    ]);
    expect(rtf).toContain("\\cb2");
    const parsed = parseRTF(rtf);
    expect(parsed.isValid).toBe(true);
    expect(parsed.runs.find((run) => run.start === 0)?.background).toBeUndefined();
    const highlighted = parsed.runs.find((run) => run.start === 1)?.background;
    expect(highlighted?.red).toBeCloseTo(1, 2);
    expect(highlighted?.green).toBeCloseTo(0.84, 2);
  });

  it("reads Cocoa's \\cb runs and treats its white slot 1 as no highlight", () => {
    const cocoa = "{\\rtf1\\ansi\\ansicpg949\\cocoartf2870\n" +
      "{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n" +
      "{\\colortbl;\\red255\\green255\\blue255;\\red255\\green255\\blue11;}\n" +
      "\\pard\\pardirnatural\\partightenfactor0\n" +
      "\\f0\\fs24 \\cf0 \\cb2 A\\cb1 B}";
    const parsed = parseRTF(cocoa);
    expect(parsed.isValid).toBe(true);
    expect(parsed.text).toBe("AB");
    const first = parsed.runs.find((run) => run.start === 0);
    const second = parsed.runs.find((run) => run.start === 1);
    expect(first?.background?.blue).toBeCloseTo(11 / 255, 2);
    expect(second?.background).toBeUndefined();
  });

  it("reads Word's \\highlight and its zero as removal", () => {
    const word = "{\\rtf1\\ansi{\\colortbl;\\red255\\green255\\blue0;}\\highlight1 A\\highlight0 B}";
    const parsed = parseRTF(word);
    expect(parsed.isValid).toBe(true);
    expect(parsed.runs.find((run) => run.start === 0)?.background?.green).toBeCloseTo(1, 2);
    expect(parsed.runs.find((run) => run.start === 1)?.background).toBeUndefined();
  });
});
