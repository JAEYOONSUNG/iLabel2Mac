import type { PrintAutomationSettings } from "../types";

export interface PrintDrainResult {
  supported: boolean;
  drained: boolean;
}

export interface PrintNetworkAdapter {
  waitForDrain(baselineJobIDs: readonly string[], timeoutMs: number): Promise<PrintDrainResult>;
  switchToPrinter(): Promise<{ sessionToken?: string }>;
  restore(sessionToken: string): Promise<void>;
  sleep(milliseconds: number): Promise<void>;
}

export type PrintNetworkPhase =
  | "checking-current-network"
  | "switching-to-printer"
  | "waiting-for-printer"
  | "restoring-network";

export interface PrintNetworkResult {
  deliveredOnCurrentNetwork: boolean;
  switchedNetwork: boolean;
  transmissionTimedOut: boolean;
}

export async function coordinatePrinterNetwork(
  settings: PrintAutomationSettings,
  baselineJobIDs: readonly string[] | undefined,
  adapter: PrintNetworkAdapter,
  onPhase: (phase: PrintNetworkPhase) => void = () => undefined,
): Promise<PrintNetworkResult> {
  if (!settings.enabled || !settings.printerSSID.trim()) {
    return {
      deliveredOnCurrentNetwork: false,
      switchedNetwork: false,
      transmissionTimedOut: false,
    };
  }

  if (baselineJobIDs) {
    onPhase("checking-current-network");
    const local = await adapter.waitForDrain(baselineJobIDs, 5_000);
    if (local.supported && local.drained) {
      return {
        deliveredOnCurrentNetwork: true,
        switchedNetwork: false,
        transmissionTimedOut: false,
      };
    }
  }

  onPhase("switching-to-printer");
  const switched = await adapter.switchToPrinter();
  let transmissionTimedOut = false;
  try {
    if (baselineJobIDs) {
      onPhase("waiting-for-printer");
      const drain = await adapter.waitForDrain(
        baselineJobIDs,
        Math.max(
          15_000,
          Math.min(120_000, settings.settleSeconds * 1_000 + 45_000),
        ),
      );
      if (drain.supported) transmissionTimedOut = !drain.drained;
      else await adapter.sleep(Math.max(1, settings.settleSeconds) * 1_000);
    } else {
      await adapter.sleep(Math.max(1, settings.settleSeconds) * 1_000);
    }
  } finally {
    if (switched.sessionToken && settings.reconnectToPreviousWiFi) {
      onPhase("restoring-network");
      await adapter.restore(switched.sessionToken);
    }
  }

  return {
    deliveredOnCurrentNetwork: false,
    switchedNetwork: true,
    transmissionTimedOut,
  };
}
