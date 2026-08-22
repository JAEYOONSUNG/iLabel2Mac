import { describe, expect, it } from "vitest";

import { rasterPixelSize, readPNGDPI, setPNGDataURLDPI, setPNGDPI } from "./png";

const ONE_PIXEL_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n0sAAAAASUVORK5CYII=";

function bytes(base64: string): Uint8Array {
  const value = atob(base64);
  return Uint8Array.from(value, (character) => character.charCodeAt(0));
}

describe("PNG physical density", () => {
  it("matches the native 720 DPI A4 raster grid and physical size", () => {
    const size = rasterPixelSize(210, 297, 720);
    expect(size).toEqual({ width: 5953, height: 8419 });
    expect(Math.abs(size.width / 720 * 25.4 - 210)).toBeLessThanOrEqual(0.05);
    expect(Math.abs(size.height / 720 * 25.4 - 297)).toBeLessThanOrEqual(0.05);
  });
  it("writes a standards-compliant 720 DPI pHYs chunk", () => {
    const result = setPNGDPI(bytes(ONE_PIXEL_PNG), 720);
    expect(readPNGDPI(result)).toBeCloseTo(720, 1);
    expect(new TextDecoder("latin1").decode(result)).toContain("pHYs");
  });

  it("replaces an existing density chunk instead of duplicating it", () => {
    const once = setPNGDPI(bytes(ONE_PIXEL_PNG), 300);
    const twice = setPNGDPI(once, 720);
    const text = new TextDecoder("latin1").decode(twice);
    expect(text.match(/pHYs/g)).toHaveLength(1);
    expect(readPNGDPI(twice)).toBeCloseTo(720, 1);
  });

  it("updates PNG data URLs and rejects invalid input", () => {
    const result = setPNGDataURLDPI(`data:image/png;base64,${ONE_PIXEL_PNG}`, 720);
    expect(result).toMatch(/^data:image\/png;base64,/);
    expect(readPNGDPI(bytes(result.split(",", 2)[1]!))).toBeCloseTo(720, 1);
    expect(() => setPNGDPI(new Uint8Array([1, 2, 3]), 720)).toThrow(/not a PNG/i);
  });
});
