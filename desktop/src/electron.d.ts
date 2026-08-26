export type IPCSuccess<T> = {
  status: "success";
  data: T;
};

export type IPCCancelled = {
  status: "cancelled";
};

export type IPCFailure = {
  status: "error";
  error: {
    code: string;
    message: string;
  };
};

export type IPCResult<T> = IPCSuccess<T> | IPCCancelled | IPCFailure;

export interface OpenTextFileData {
  path: string;
  name: string;
  text: string;
}

export interface OpenImageData {
  path: string;
  name: string;
  /** Raw file bytes encoded as base64, without a data-URL prefix. */
  base64: string;
  mime: string;
}

export interface SavedFileData {
  path: string;
  name: string;
}

export interface SaveProjectRequest {
  /** Complete UTF-8 JSON text. It is validated before being written. */
  data: string;
  suggestedName: string;
  /** Reused only when this process previously opened or saved the path. */
  existingPath?: string;
}

export interface SavePNGRequest {
  /** PNG bytes as raw base64 or a data:image/png;base64 URL. */
  base64: string;
  suggestedName: string;
}

export interface PrintableHTMLRequest {
  /** Self-contained, static HTML. Images and fonts should use data URLs. */
  html: string;
  pageWidthMM: number;
  pageHeightMM: number;
  suggestedName?: string;
  jobTitle?: string;
}

export interface PrintJobData {
  jobTitle: string;
  baselineJobIDs?: string[];
}

export interface PrintDrainRequest {
  baselineJobIDs: string[];
  timeoutMs?: number;
}

export interface PrintDrainData {
  supported: boolean;
  drained: boolean;
  observedJob: boolean;
  remainingJobIDs: string[];
}

export type DesktopPlatform =
  | "aix"
  | "android"
  | "darwin"
  | "freebsd"
  | "haiku"
  | "linux"
  | "openbsd"
  | "sunos"
  | "win32"
  | "cygwin"
  | "netbsd";

export interface OSInfo {
  platform: DesktopPlatform;
  arch: string;
  release: string;
  version: string;
  appVersion: string;
  isPackaged: boolean;
}

export interface WifiRequest {
  ssid: string;
  /** Used only for this request and never persisted by Electron. */
  password?: string;
  interfaceName?: string;
  /** Fallback network/profile when the current SSID cannot be detected. */
  restoreSSID?: string;
  timeoutMs?: number;
}

export interface WifiTestRequest extends WifiRequest {
  /** Defaults to true when a previous SSID can be identified. */
  restoreAfterTest?: boolean;
}

export interface WifiStatus {
  supported: boolean;
  platform: DesktopPlatform;
  tool?: "netsh" | "nmcli";
  currentSSID?: string;
  interfaceName?: string;
  connectionName?: string;
}

export interface WifiSwitchData {
  /** In-memory token used by wifi.restore; it expires when the app exits. */
  sessionToken: string;
  targetSSID: string;
  previousSSID?: string;
  currentSSID?: string;
  interfaceName?: string;
}

export interface WifiRestoreData {
  restored: boolean;
  currentSSID?: string;
}

export interface WifiTestData {
  connected: boolean;
  restored: boolean;
  targetSSID: string;
  currentSSID?: string;
  restoreError?: string;
}

export interface ILabelDesktopAPI {
  openProject(): Promise<IPCResult<OpenTextFileData>>;
  saveProject(request: SaveProjectRequest): Promise<IPCResult<SavedFileData>>;
  openCSV(): Promise<IPCResult<OpenTextFileData>>;
  openImage(): Promise<IPCResult<OpenImageData>>;
  savePNG(request: SavePNGRequest): Promise<IPCResult<SavedFileData>>;
  exportPDF(request: PrintableHTMLRequest): Promise<IPCResult<SavedFileData>>;
  /** Available only when the packaged smoke flag is present. */
  renderPDFForTest(request: PrintableHTMLRequest): Promise<IPCResult<{ base64: string }>>;
  print(request: PrintableHTMLRequest): Promise<IPCResult<PrintJobData>>;
  waitForPrintDrain(request: PrintDrainRequest): Promise<IPCResult<PrintDrainData>>;
  getOSInfo(): Promise<IPCResult<OSInfo>>;
  setTheme(theme: "light" | "dark" | "system"): Promise<IPCResult<"light" | "dark" | "system">>;
  updates: {
    /** The offer announced this session, if any — for components that mount late. */
    state(): Promise<UpdateOffer | null>;
    download(): Promise<UpdateDownloadResult>;
    install(): Promise<void>;
    skip(version: string): Promise<void>;
    openDownloads(): Promise<void>;
    onAvailable(listener: (offer: UpdateOffer) => void): () => void;
    onProgress(listener: (progress: UpdateProgress) => void): () => void;
  };
  wifi: {
    getStatus(): Promise<IPCResult<WifiStatus>>;
    test(request: WifiTestRequest): Promise<IPCResult<WifiTestData>>;
    switch(request: WifiRequest): Promise<IPCResult<WifiSwitchData>>;
    restore(sessionToken: string): Promise<IPCResult<WifiRestoreData>>;
  };
}

export interface UpdateOffer {
  version: string;
  notes: string;
  url: string;
  current: string;
  /** Whether this copy can replace itself (installer/AppImage) or must be
      handed the download (portable, deb). */
  self: boolean;
}

export interface UpdateProgress {
  percent: number;
}

export type UpdateDownloadResult =
  | { status: "success" }
  | { status: "error"; error: { code: string; message: string } };

declare global {
  interface Window {
    iLabelDesktop: ILabelDesktopAPI;
  }
}
