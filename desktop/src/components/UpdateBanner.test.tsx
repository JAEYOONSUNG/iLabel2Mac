// @vitest-environment happy-dom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { UpdateOffer } from "../electron";
import UpdateBanner from "./UpdateBanner";

const mountedRoots: Array<{ root: ReturnType<typeof createRoot>; host: HTMLElement }> = [];

afterEach(async () => {
  await act(async () => {
    for (const mounted of mountedRoots.splice(0)) {
      mounted.root.unmount();
      mounted.host.remove();
    }
  });
  // @ts-expect-error test bridge teardown
  delete window.iLabelDesktop;
});

function installBridge(offer: UpdateOffer | null, download = vi.fn()) {
  const bridge = {
    state: vi.fn().mockResolvedValue(offer),
    download,
    install: vi.fn().mockResolvedValue(undefined),
    skip: vi.fn().mockResolvedValue(undefined),
    openDownloads: vi.fn().mockResolvedValue(undefined),
    onAvailable: vi.fn().mockReturnValue(() => undefined),
    onProgress: vi.fn().mockReturnValue(() => undefined),
  };
  // @ts-expect-error only the updates bridge matters to this component
  window.iLabelDesktop = { updates: bridge };
  return bridge;
}

async function mountBanner(): Promise<HTMLElement> {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mountedRoots.push({ root, host });
  await act(async () => {
    root.render(<UpdateBanner />);
  });
  return host;
}

const offer: UpdateOffer = {
  version: "0.9.9",
  notes: "",
  url: "https://example.invalid/download",
  current: "0.1.0",
  self: true,
};

describe("UpdateBanner", () => {
  it("stays out of the way when no update is on offer", async () => {
    installBridge(null);
    const host = await mountBanner();
    expect(host.querySelector(".update-banner")).toBeNull();
  });

  it("offers a self-updating copy an install button", async () => {
    installBridge(offer);
    const host = await mountBanner();
    expect(host.textContent).toContain("0.9.9 is available");
    expect(host.textContent).toContain("You have 0.1.0");
    expect(host.querySelector("button.primary")?.textContent).toBe("Install Update");
  });

  it("hands a portable copy the download instead of a dead button", async () => {
    installBridge({ ...offer, self: false });
    const host = await mountBanner();
    expect(host.querySelector("button.primary")?.textContent).toBe("Open Downloads");
    expect(host.textContent).toContain("cannot replace itself");
  });

  it("moves through download to the restart offer", async () => {
    const download = vi.fn().mockResolvedValue({ status: "success" });
    installBridge(offer, download);
    const host = await mountBanner();
    await act(async () => {
      (host.querySelector("button.primary") as HTMLButtonElement).click();
    });
    expect(download).toHaveBeenCalledOnce();
    expect(host.textContent).toContain("0.9.9 is ready");
    expect(host.querySelector("button.primary")?.textContent).toBe("Restart Now");
  });

  it("reports a failed download and offers the manual way out", async () => {
    const download = vi.fn().mockResolvedValue({
      status: "error",
      error: { code: "update-download-failed", message: "boom" },
    });
    installBridge(offer, download);
    const host = await mountBanner();
    await act(async () => {
      (host.querySelector("button.primary") as HTMLButtonElement).click();
    });
    expect(host.textContent).toContain("could not be installed");
    expect(host.textContent).toContain("boom");
    expect(host.querySelector("button.primary")?.textContent).toBe("Open Downloads");
  });

  it("remembers a skipped version through the bridge", async () => {
    const bridge = installBridge(offer);
    const host = await mountBanner();
    const skip = [...host.querySelectorAll("button")].find((b) => b.textContent === "Skip");
    await act(async () => {
      skip?.click();
    });
    expect(bridge.skip).toHaveBeenCalledWith("0.9.9");
    expect(host.querySelector(".update-banner")).toBeNull();
  });
});
