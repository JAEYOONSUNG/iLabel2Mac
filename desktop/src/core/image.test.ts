// @vitest-environment happy-dom

import { afterEach, describe, expect, it, vi } from "vitest";

import { createStarterDocument, makeElement } from "../defaults";
import type { LabelElement } from "../types";
import {
  normalizeDocumentImages,
  normalizeImportedImage,
  sanitizeSVGText,
} from "./image";

const OUTPUT_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n0sAAAAASUVORK5CYII=";

function encoded(bytes: readonly number[]): string {
  return btoa(String.fromCharCode(...bytes));
}

const FORMAT_BYTES = {
  png: encoded([137, 80, 78, 71, 13, 10, 26, 10, 0]),
  jpeg: encoded([0xff, 0xd8, 0xff, 0xe0, 0]),
  webp: encoded([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]),
  bmp: encoded([66, 77, 0, 0]),
  gif: encoded([71, 73, 70, 56, 57, 97, 0]),
  tiff: encoded([73, 73, 42, 0, 0]),
  heic: encoded([0, 0, 0, 24, 102, 116, 121, 112, 104, 101, 105, 99]),
};

function installBitmapMocks(options: { reject?: boolean } = {}): ReturnType<typeof vi.fn> {
  const drawImage = vi.fn();
  const close = vi.fn();
  Object.defineProperty(globalThis, "createImageBitmap", {
    configurable: true,
    writable: true,
    value: options.reject
      ? vi.fn(async () => { throw new Error("decoder unavailable"); })
      : vi.fn(async () => ({ width: 2, height: 3, close })),
  });
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({ drawImage } as never);
  vi.spyOn(HTMLCanvasElement.prototype, "toDataURL")
    .mockReturnValue(`data:image/png;base64,${OUTPUT_PNG}`);
  return drawImage;
}

function image(name: string, imageData: string): LabelElement {
  const element = makeElement("image");
  element.name = name;
  element.imageData = imageData;
  return element;
}

afterEach(() => {
  vi.restoreAllMocks();
  Reflect.deleteProperty(globalThis, "createImageBitmap");
});

describe("SVG image sanitization", () => {
  it("keeps ordinary vector geometry and inline data", () => {
    const result = sanitizeSVGText(`
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
        <defs><linearGradient id="g"><stop offset="1" stop-color="#fff"/></linearGradient></defs>
        <rect width="10" height="10" fill="url(#g)"/>
        <image href="data:image/png;base64,iVBORw0KGgo="/>
      </svg>
    `);
    expect(result).toContain("<rect");
    expect(result).toContain("url(#g)");
    expect(result).toContain("data:image/png;base64");
  });

  it("rejects scripts, event handlers, and external resources", () => {
    expect(() => sanitizeSVGText('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')).toThrow(/active content/i);
    expect(() => sanitizeSVGText('<svg xmlns="http://www.w3.org/2000/svg"><rect onclick="alert(1)"/></svg>')).toThrow(/event-handler/i);
    expect(() => sanitizeSVGText('<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/a.png"/></svg>')).toThrow(/external resource/i);
    expect(() => sanitizeSVGText('<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:url(https://example.com/a)"/></svg>')).toThrow(/external resource/i);
  });

  it("rejects malformed or non-SVG XML", () => {
    expect(() => sanitizeSVGText("<svg><broken></svg>")).toThrow(/malformed/i);
    expect(() => sanitizeSVGText("<html></html>")).toThrow(/malformed/i);
  });
});

describe("opened-project image normalization", () => {
  it.each([
    ["PNG", FORMAT_BYTES.png],
    ["JPEG", FORMAT_BYTES.jpeg],
    ["WebP", FORMAT_BYTES.webp],
    ["BMP", FORMAT_BYTES.bmp],
    ["GIF first frame", FORMAT_BYTES.gif],
  ])("decodes and normalizes %s artwork to portable PNG bytes", async (_label, data) => {
    const drawImage = installBitmapMocks();
    await expect(normalizeImportedImage(data)).resolves.toBe(OUTPUT_PNG);
    expect(drawImage).toHaveBeenCalledTimes(1);
  });

  it("sanitizes SVG bytes discovered without stored MIME metadata", async () => {
    const source = `<svg xmlns="http://www.w3.org/2000/svg"><rect width="2" height="3"/></svg>`;
    const result = await normalizeImportedImage(btoa(source));
    expect(atob(result)).toContain("<rect");
    expect(atob(result)).not.toContain("<script");
  });

  it("normalizes current artwork and every captured batch without mutating the source", async () => {
    installBitmapMocks();
    const source = createStarterDocument();
    source.elements = [image("Current Logo", FORMAT_BYTES.png)];
    source.printQueue = [
      {
        id: crypto.randomUUID(),
        name: "Archived Run",
        quantity: 1,
        elements: [image("Captured Badge", FORMAT_BYTES.gif)],
      },
    ];

    const result = await normalizeDocumentImages(source);
    expect(result).not.toBe(source);
    expect(result.elements[0]?.imageData).toBe(OUTPUT_PNG);
    expect(result.printQueue?.[0]?.elements[0]?.imageData).toBe(OUTPUT_PNG);
    expect(source.elements[0]?.imageData).toBe(FORMAT_BYTES.png);
    expect(source.printQueue?.[0]?.elements[0]?.imageData).toBe(FORMAT_BYTES.gif);
  });

  it.each([
    ["Legacy TIFF Logo", FORMAT_BYTES.tiff, "image/tiff"],
    ["Legacy HEIC Photo", FORMAT_BYTES.heic, "image/heic"],
  ])("throws a named error instead of silently retaining unsupported %s", async (name, data, mime) => {
    installBitmapMocks({ reject: true });
    const source = createStarterDocument();
    source.elements = [image(name, data)];

    await expect(normalizeDocumentImages(source)).rejects.toThrow(
      new RegExp(`${name}.*${mime}`, "i"),
    );
  });

  it("names the capture and element when a queued legacy image cannot decode", async () => {
    installBitmapMocks({ reject: true });
    const source = createStarterDocument();
    source.elements = [];
    source.printQueue = [
      {
        id: crypto.randomUUID(),
        name: "Old Batch",
        quantity: 1,
        elements: [image("Queue TIFF", FORMAT_BYTES.tiff)],
      },
    ];

    await expect(normalizeDocumentImages(source)).rejects.toThrow(
      /Queue TIFF.*Old Batch.*image\/tiff/i,
    );
  });
});
