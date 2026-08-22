import { describe, expect, it } from "vitest";

import {
  COLORS,
  DEFAULT_SERIAL_SETTINGS,
  createStarterDocument,
  makeElement,
} from "../defaults";
import type {
  LabelDocument,
  LabelElement,
  MergeContext,
  SheetTemplate,
} from "../types";
import {
  renderLabelSVG,
  renderPageSVG,
  renderPrintHTML,
  svgToStandaloneDataURL,
} from "./svg";
import { serializeBase64RTF } from "./rtf";

const NOW = new Date(2026, 7, 22, 14, 5, 0);
const TTF_FONT_DATA = "AAEAAAAAAAA=";
const OTF_FONT_DATA = "T1RUTwAAAAA=";
const WOFF_FONT_DATA = "d09GRgAAAAA=";
const WOFF2_FONT_DATA = "d09GMgAAAAA=";

const ACTIVE_CONTEXT: MergeContext = {
  row: { Name: "Sample" },
  serialValue: 7,
  rowNumber: 1,
  pageNumber: 1,
  slotNumber: 1,
  isActive: true,
};

function oneUpSheet(overrides: Partial<SheetTemplate> = {}): SheetTemplate {
  return {
    id: "test-sheet",
    name: "Test sheet",
    pageWidthMM: 50,
    pageHeightMM: 30,
    columns: 1,
    rows: 1,
    labelWidthMM: 50,
    labelHeightMM: 30,
    horizontalGapMM: 0,
    verticalGapMM: 0,
    marginLeftMM: 0,
    marginTopMM: 0,
    shape: "roundedRectangle",
    cornerRadiusMM: 2,
    ...overrides,
  };
}

function documentWith(
  elements: LabelElement[],
  sheet: SheetTemplate = oneUpSheet(),
): LabelDocument {
  const document = createStarterDocument();
  document.title = "SVG <test> & output";
  document.sheet = sheet;
  document.elements = elements;
  document.serial = {
    ...DEFAULT_SERIAL_SETTINGS,
    mode: "rangedSets",
    start: 1,
    end: 1,
    repeatSets: 1,
    prefix: "",
    suffix: "",
  };
  document.placement = { selectedSlotIndices: [], fillDirection: "horizontal" };
  delete document.dataTable;
  delete document.printQueue;
  return document;
}

describe("renderLabelSVG", () => {
  it("uses millimetre geometry, resolves tokens, escapes XML, and preserves style", () => {
    const text = makeElement("text");
    text.frame = { x: 2, y: 3, width: 40, height: 12 };
    text.content = '<unsafe & "quoted"> {{serial_raw}} {{date}} {{Name}}';
    text.foreground = { red: 0.5, green: 0, blue: 0, alpha: 0.75 };
    text.opacity = 0.4;
    text.rotation = 12.5;
    text.isItalic = true;
    text.isUnderline = true;

    const document = documentWith([text]);
    const first = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });
    const second = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });

    expect(first).toBe(second);
    expect(first).toContain('width="50mm" height="30mm" viewBox="0 0 50 30"');
    expect(first).toContain("&lt;unsafe");
    expect(first).toContain("&amp;");
    expect(first).toContain("&quot;quoted&quot;");
    expect(first).toContain("&gt; 7");
    expect(first).toContain("2026.08.");
    expect(first).toContain(">22</tspan>");
    expect(first).toContain(">Sample</tspan>");
    expect(first).not.toContain("<unsafe");
    expect(first).toContain('fill="#800000"');
    expect(first).toContain('fill-opacity="0.75"');
    expect(first).toContain('opacity="0.4"');
    expect(first).toContain('transform="rotate(12.5 22 9)"');
    expect(first).toContain('font-style="italic"');
    expect(first).toContain('text-decoration="underline"');
    expect(first).toContain('data-layout="rectangular"');
  });

  it("renders vertical grapheme lines without splitting Korean characters", () => {
    const text = makeElement("text");
    text.content = "가나\nAB";
    text.verticalTextLayout = true;
    text.frame = { x: 0, y: 0, width: 20, height: 28 };
    const svg = renderLabelSVG(documentWith([text]), ACTIVE_CONTEXT, { now: NOW });

    expect(svg).toContain('data-layout="vertical"');
    expect(svg).toMatch(/<tspan[^>]*>가<\/tspan>/);
    expect(svg).toMatch(/<tspan[^>]*>나<\/tspan>/);
    expect(svg).toMatch(/<tspan[^>]*>A<\/tspan>/);
    expect(svg).toMatch(/<tspan[^>]*>B<\/tspan>/);
  });

  it("renders selection-level RTF styles and keeps token replacement styling", () => {
    const text = makeElement("text");
    text.frame = { x: 0, y: 0, width: 50, height: 20 };
    text.content = "A{{serial}}B";
    text.richTextRTF = serializeBase64RTF(text.content, [
      { start: 0, length: 1, fontName: "Arial", fontSize: 10, foreground: { red: 1, green: 0, blue: 0, alpha: 1 } },
      { start: 1, length: 10, fontName: "Courier New", fontSize: 18, bold: true, italic: true, underline: true, foreground: { red: 0, green: 0, blue: 1, alpha: 1 } },
      { start: 11, length: 1, fontName: "Arial", fontSize: 12, foreground: { red: 0, green: 0.6, blue: 0, alpha: 1 } },
    ]);
    const document = documentWith([text]);
    document.serial = { ...document.serial, digits: 2, prefix: "(", suffix: ")", start: 7, end: 7 };

    const svg = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });

    expect(svg).toContain('fill="#ff0000">A</tspan>');
    expect(svg).toMatch(/font-family="Courier New"[^>]*font-size="6\.35"[^>]*font-weight="700"[^>]*font-style="italic"[^>]*text-decoration="underline"[^>]*fill="#0000ff">\(07\)<\/tspan>/);
    expect(svg).toContain('fill="#009900">B</tspan>');
    expect(svg).toContain('data-text-length="6"');
  });

  it("uses the actual rich-text run size for line height and centering", () => {
    const text = makeElement("text");
    text.frame = { x: 0, y: 0, width: 50, height: 20 };
    text.fontSize = 72;
    text.content = "Small";
    text.richTextRTF = serializeBase64RTF(text.content, [
      { start: 0, length: text.content.length, fontName: "Arial", fontSize: 8 },
    ]);

    const svg = renderLabelSVG(documentWith([text]), ACTIVE_CONTEXT, { now: NOW });

    expect(svg).toMatch(/data-line-font-size="2\.82222[0-9]"/);
    expect(svg).not.toContain('data-line-font-size="25.4"');
  });

  it("embeds a validated font once and resolves both family and PostScript names safely", () => {
    const familyText = makeElement("text");
    familyText.fontName = 'Family "/><script>alert(1)</script>';
    familyText.frame = { x: 1, y: 1, width: 20, height: 8 };
    const postScriptText = makeElement("text");
    postScriptText.fontName = 'Face"</style><script>alert(2)</script>';
    postScriptText.frame = { x: 1, y: 10, width: 20, height: 8 };
    const document = documentWith([familyText, postScriptText]);
    document.embeddedFonts = [
      {
        postScriptName: postScriptText.fontName,
        familyName: familyText.fontName,
        data: TTF_FONT_DATA,
      },
      {
        postScriptName: "Duplicate-Name",
        familyName: "Duplicate Family",
        data: TTF_FONT_DATA,
      },
    ];

    const svg = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });
    const alias = svg.match(/@font-face\{font-family:"([A-Za-z0-9-]+)"/)?.[1];

    expect(alias).toBeTruthy();
    expect(svg.match(/@font-face/g)).toHaveLength(1);
    expect(svg).toContain(`src:url(data:font/ttf;base64,${TTF_FONT_DATA})`);
    expect(svg).toContain('format("truetype")');
    expect(svg.match(new RegExp(`font-family="${alias}"`, "g"))?.length).toBeGreaterThanOrEqual(2);
    expect(svg).not.toContain("<script>");
    expect(svg).not.toContain("</style><script>");
    expect(svg).not.toContain(familyText.fontName);
    expect(svg).not.toContain(postScriptText.fontName);
  });

  it("detects OpenType and web-font signatures and ignores unsupported data", () => {
    const text = makeElement("text");
    text.fontName = "Open Face";
    const document = documentWith([text]);
    document.embeddedFonts = [
      { postScriptName: "Open-Face", familyName: "Open Face", data: OTF_FONT_DATA },
      { postScriptName: "Web-Face", familyName: "Web Face", data: WOFF_FONT_DATA },
      { postScriptName: "Web2-Face", familyName: "Web2 Face", data: WOFF2_FONT_DATA },
      { postScriptName: "Unknown-Face", familyName: "Unknown Face", data: "PHNjcmlwdD4=" },
      { postScriptName: "Malformed-Face", familyName: "Malformed Face", data: "AAEAAA==<" },
    ];

    const svg = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });

    expect(svg.match(/@font-face/g)).toHaveLength(3);
    expect(svg).toContain(`data:font/otf;base64,${OTF_FONT_DATA}`);
    expect(svg).toContain('format("opentype")');
    expect(svg).toContain(`data:font/woff;base64,${WOFF_FONT_DATA}`);
    expect(svg).toContain('format("woff")');
    expect(svg).toContain(`data:font/woff2;base64,${WOFF2_FONT_DATA}`);
    expect(svg).toContain('format("woff2")');
    expect(svg).not.toContain("PHNjcmlwdD4=");
    expect(svg).not.toContain("AAEAAA==&lt;");
  });

  it("caps the number of untrusted embedded font faces", () => {
    const document = documentWith([makeElement("text")]);
    document.embeddedFonts = Array.from({ length: 70 }, (_, index) => ({
      postScriptName: `Limited-Face-${index}`,
      familyName: `Limited Family ${index}`,
      data: btoa(String.fromCharCode(0, 1, 0, 0, index)),
    }));

    const svg = renderLabelSVG(document, ACTIVE_CONTEXT, { now: NOW });

    expect(svg.match(/@font-face/g)).toHaveLength(64);
  });

  it("approximates circular chord flow with ellipse clips and per-line widths", () => {
    const sheet = oneUpSheet({
      pageWidthMM: 30,
      pageHeightMM: 30,
      labelWidthMM: 30,
      labelHeightMM: 30,
      shape: "circle",
      cornerRadiusMM: 15,
    });
    const text = makeElement("text");
    text.frame = { x: 0, y: 0, width: 30, height: 30 };
    text.content = "Circular text follows the available chord width";
    text.fontSize = 9;
    text.usesCircularTextFlow = true;
    const svg = renderLabelSVG(documentWith([text], sheet), ACTIVE_CONTEXT, {
      now: NOW,
    });

    expect(svg).toContain("<ellipse");
    expect(svg).toContain('data-layout="circular-chord"');
    expect(svg).toContain("data-available-width=");
    expect(svg).not.toMatch(/(?:NaN|Infinity)/);
    const widths = [...svg.matchAll(/data-available-width="([0-9.]+)"/g)].map(
      (match) => Number(match[1]),
    );
    expect(widths.length).toBeGreaterThan(1);
    expect(new Set(widths.map((value) => value.toFixed(3))).size).toBeGreaterThan(1);
  });

  it("limits circular lines to the narrowest chord across each full line band", () => {
    const sheet = oneUpSheet({
      pageWidthMM: 12,
      pageHeightMM: 12,
      labelWidthMM: 12,
      labelHeightMM: 12,
      shape: "circle",
      cornerRadiusMM: 6,
    });
    const text = makeElement("text");
    text.frame = { x: 0, y: 0, width: 12, height: 12 };
    text.content = "WWWW WWWW WWWW";
    text.fontSize = 4;
    text.usesCircularTextFlow = true;
    const svg = renderLabelSVG(documentWith([text], sheet), ACTIVE_CONTEXT, { now: NOW });
    const lines = [...svg.matchAll(
      /<tspan x="[^"]+" y="([0-9.]+)" data-text-start="[^"]+" data-text-length="[^"]+" data-line-font-size="([0-9.]+)" data-available-width="([0-9.]+)">/g,
    )];

    expect(lines.length).toBeGreaterThan(1);
    for (const line of lines) {
      const baseline = Number(line[1]);
      const fontSize = Number(line[2]);
      const available = Number(line[3]);
      const top = baseline - fontSize * 0.92;
      const bottom = top + fontSize * 1.2;
      const chord = (y: number) => {
        const normalized = (y - 6) / 5.4;
        return Math.abs(normalized) >= 1
          ? 0.1
          : Math.max(0.1, 10 * Math.sqrt(1 - normalized * normalized));
      };
      expect(available).toBeLessThanOrEqual(Math.min(chord(top), chord(bottom)) + 0.000_01);
    }
  });

  it("renders shape and fit/fill raster images with rounded clipping", () => {
    const shape = makeElement("rectangle");
    shape.frame = { x: 1, y: 1, width: 12, height: 8 };
    shape.cornerRadiusMM = 2;
    shape.background = { red: 0.1, green: 0.2, blue: 0.3, alpha: 0.5 };

    const fit = makeElement("image");
    fit.frame = { x: 15, y: 1, width: 12, height: 8 };
    fit.imageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB";
    fit.imageScaleMode = "fit";

    const fill = { ...fit, id: `${fit.id}-fill`, frame: { x: 29, y: 1, width: 12, height: 8 }, imageScaleMode: "fill" as const };
    const vector = { ...fit, id: `${fit.id}-svg`, frame: { x: 1, y: 12, width: 12, height: 8 } };
    vector.imageData = "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg==";
    const svg = renderLabelSVG(documentWith([shape, fit, fill, vector]), ACTIVE_CONTEXT, {
      now: NOW,
    });

    expect(svg).toContain('fill="#1a334d" fill-opacity="0.5"');
    expect(svg).toContain("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB");
    expect(svg).toContain('preserveAspectRatio="xMidYMid meet"');
    expect(svg).toContain('preserveAspectRatio="xMidYMid slice"');
    expect(svg).toContain("data:image/svg+xml;base64,PHN2Zy");
    expect(svg.match(/<clipPath/g)?.length).toBeGreaterThanOrEqual(3);
  });

  it("uses qrcode's module matrix and bwip-js vector Code128 output", () => {
    const qr = makeElement("qrCode");
    qr.frame = { x: 1, y: 1, width: 16, height: 16 };
    qr.content = "LOT-{{serial_raw}}";
    const barcode = makeElement("code128");
    barcode.frame = { x: 19, y: 2, width: 29, height: 12 };
    barcode.content = "SKU-{{serial_raw}}";
    const document = documentWith([qr, barcode]);

    const svg = renderLabelSVG(document, ACTIVE_CONTEXT, {
      now: NOW,
      codePaddingMM: 1,
    });
    const other = renderLabelSVG(
      document,
      { ...ACTIVE_CONTEXT, serialValue: 8 },
      { now: NOW, codePaddingMM: 1 },
    );

    expect(svg).toContain('data-kind="qr"');
    expect(svg).toMatch(/data-modules="\d+"/);
    expect(svg).toContain('shape-rendering="crispEdges"');
    expect(svg).toContain('data-kind="code128"');
    expect(svg).toMatch(/data-kind="code128"[\s\S]*<(?:path|rect)/);
    expect(svg).not.toBe(other);
  });
});

describe("renderPageSVG", () => {
  it("embeds the same label tree once per active slot with unique clips", () => {
    const sheet = oneUpSheet({
      pageWidthMM: 42,
      pageHeightMM: 20,
      columns: 2,
      rows: 1,
      labelWidthMM: 20,
      labelHeightMM: 20,
      horizontalGapMM: 2,
    });
    const text = makeElement("text");
    text.frame = { x: 1, y: 4, width: 18, height: 10 };
    text.content = "Slot {{slot}}";
    text.fontSize = 8;
    const document = documentWith([text], sheet);
    document.serial.end = 2;

    const svg = renderPageSVG(document, 0, {
      now: NOW,
      showGuides: true,
    });

    expect(svg).toContain('data-render-surface="page"');
    expect(svg).toContain('viewBox="0 0 42 20"');
    expect(svg).toContain('data-slot-index="0"');
    expect(svg).toContain('data-slot-index="1"');
    expect(svg).toContain(">Slot 1</tspan>");
    expect(svg).toContain(">Slot 2</tspan>");
    expect(svg).toContain('transform="translate(22 0)"');
    const ids = [...svg.matchAll(/<clipPath id="([^"]+)"/g)].map((match) => match[1]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("rejects page indices outside the document", () => {
    const document = documentWith([makeElement("text")]);
    expect(() => renderPageSVG(document, -1)).toThrow(RangeError);
    expect(() => renderPageSVG(document, 1)).toThrow(RangeError);
  });

  it("shares one embedded font definition across every slot", () => {
    const sheet = oneUpSheet({
      pageWidthMM: 42,
      pageHeightMM: 20,
      columns: 2,
      rows: 1,
      labelWidthMM: 20,
      labelHeightMM: 20,
      horizontalGapMM: 2,
    });
    const text = makeElement("text");
    text.fontName = "Portable Family";
    const document = documentWith([text], sheet);
    document.serial.end = 2;
    document.embeddedFonts = [
      {
        postScriptName: "Portable-Regular",
        familyName: "Portable Family",
        data: TTF_FONT_DATA,
      },
    ];

    const svg = renderPageSVG(document, 0, { now: NOW });
    const alias = svg.match(/@font-face\{font-family:"([A-Za-z0-9-]+)"/)?.[1];

    expect(svg.match(/@font-face/g)).toHaveLength(1);
    expect(alias).toBeTruthy();
    expect(svg.match(new RegExp(`font-family="${alias}"`, "g"))?.length).toBeGreaterThanOrEqual(2);
  });
});

describe("print and data URL exports", () => {
  it("exports selected or all pages with exact @page millimetres and no guides", () => {
    const document = documentWith([makeElement("text")]);
    document.serial.end = 2;
    const all = renderPrintHTML(document, undefined, {
      now: NOW,
      autoPrint: true,
      showGuides: true,
    });
    const current = renderPrintHTML(document, [1], { now: NOW });

    expect(all).toContain("@page{size:50mm 30mm;margin:0}");
    expect(all.match(/class="ilabel-print-page"/g)).toHaveLength(2);
    expect(all).toContain('data-page-index="0"');
    expect(all).toContain('data-page-index="1"');
    expect(all).toContain("requestAnimationFrame(()=>print())");
    expect(all).toContain("SVG &lt;test&gt; &amp; output");
    expect(current.match(/class="ilabel-print-page"/g)).toHaveLength(1);
    expect(current).toContain('data-page-index="1"');
    expect(current).not.toContain('data-page-index="0"');
  });

  it("encodes Unicode SVG into a standalone reversible data URL", () => {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><text>한글 &amp; labels</text></svg>';
    const url = svgToStandaloneDataURL(svg);

    expect(url).toMatch(/^data:image\/svg\+xml;charset=utf-8,/);
    expect(decodeURIComponent(url.split(",", 2)[1] ?? "")).toBe(svg);
  });

  it("places embedded font CSS once in a multi-page print document", () => {
    const text = makeElement("text");
    text.fontName = "Print Family";
    const document = documentWith([text]);
    document.serial.end = 2;
    document.embeddedFonts = [
      {
        postScriptName: "Print-Regular",
        familyName: "Print Family",
        data: WOFF_FONT_DATA,
      },
    ];

    const html = renderPrintHTML(document, undefined, { now: NOW });
    const alias = html.match(/@font-face\{font-family:"([A-Za-z0-9-]+)"/)?.[1];

    expect(html.match(/@font-face/g)).toHaveLength(1);
    expect(html).toContain(`data:font/woff;base64,${WOFF_FONT_DATA}`);
    expect(alias).toBeTruthy();
    expect(html.match(new RegExp(`font-family="${alias}"`, "g"))?.length).toBeGreaterThanOrEqual(2);
  });

  it("keeps explicit transparent backgrounds and color alpha", () => {
    const text = makeElement("text");
    text.background = { ...COLORS.clear };
    text.foreground = { red: 0, green: 0, blue: 1, alpha: 0.25 };
    const svg = renderLabelSVG(documentWith([text]), ACTIVE_CONTEXT, {
      now: NOW,
      backgroundColor: null,
    });

    expect(svg).not.toContain('<rect width="50" height="30"');
    expect(svg).toContain('fill="#0000ff" fill-opacity="0.25"');
  });
});
