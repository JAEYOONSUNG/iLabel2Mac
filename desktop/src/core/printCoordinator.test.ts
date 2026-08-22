import { describe, expect, it, vi } from "vitest";

import type { PrintAutomationSettings } from "../types";
import {
  coordinatePrinterNetwork,
  type PrintNetworkAdapter,
} from "./printCoordinator";

const SETTINGS: PrintAutomationSettings = {
  enabled: true,
  wifiService: "Wi-Fi",
  printerSSID: "Printer-AP",
  printerPassword: "",
  reconnectToPreviousWiFi: true,
  settleSeconds: 2,
};

function adapter(
  drains: Array<{ supported: boolean; drained: boolean }>,
): PrintNetworkAdapter & Record<string, ReturnType<typeof vi.fn>> {
  return {
    waitForDrain: vi.fn(async () => drains.shift() ?? { supported: false, drained: false }),
    switchToPrinter: vi.fn(async () => ({ sessionToken: "session" })),
    restore: vi.fn(async () => undefined),
    sleep: vi.fn(async () => undefined),
  };
}

describe("print network coordinator", () => {
  it("does not switch Wi-Fi when the current LAN drains the new job", async () => {
    const mock = adapter([{ supported: true, drained: true }]);
    const result = await coordinatePrinterNetwork(SETTINGS, ["old-job"], mock);
    expect(result.deliveredOnCurrentNetwork).toBe(true);
    expect(mock.switchToPrinter).not.toHaveBeenCalled();
    expect(mock.restore).not.toHaveBeenCalled();
  });

  it("switches once, waits for drain, and restores", async () => {
    const mock = adapter([
      { supported: true, drained: false },
      { supported: true, drained: true },
    ]);
    const phases: string[] = [];
    const result = await coordinatePrinterNetwork(
      SETTINGS,
      [],
      mock,
      (phase) => phases.push(phase),
    );
    expect(result).toEqual({
      deliveredOnCurrentNetwork: false,
      switchedNetwork: true,
      transmissionTimedOut: false,
    });
    expect(mock.switchToPrinter).toHaveBeenCalledTimes(1);
    expect(mock.restore).toHaveBeenCalledWith("session");
    expect(phases).toEqual([
      "checking-current-network",
      "switching-to-printer",
      "waiting-for-printer",
      "restoring-network",
    ]);
  });

  it("uses the settle fallback when spool monitoring is unavailable", async () => {
    const mock = adapter([
      { supported: false, drained: false },
      { supported: false, drained: false },
    ]);
    await coordinatePrinterNetwork(SETTINGS, [], mock);
    expect(mock.sleep).toHaveBeenCalledWith(2_000);
    expect(mock.restore).toHaveBeenCalledTimes(1);
  });

  it("never switches for disabled automation", async () => {
    const mock = adapter([]);
    await coordinatePrinterNetwork({ ...SETTINGS, enabled: false }, [], mock);
    expect(mock.waitForDrain).not.toHaveBeenCalled();
    expect(mock.switchToPrinter).not.toHaveBeenCalled();
  });
});
