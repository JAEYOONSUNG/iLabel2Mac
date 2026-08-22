import { contextBridge, ipcRenderer } from "electron";

type SaveProjectRequest = {
  data: string;
  suggestedName: string;
  existingPath?: string;
};

type SavePNGRequest = {
  base64: string;
  suggestedName: string;
};

type PrintableHTMLRequest = {
  html: string;
  pageWidthMM: number;
  pageHeightMM: number;
  suggestedName?: string;
  jobTitle?: string;
};

type PrintDrainRequest = {
  baselineJobIDs: string[];
  timeoutMs?: number;
};

type WifiRequest = {
  ssid: string;
  password?: string;
  interfaceName?: string;
  restoreSSID?: string;
  timeoutMs?: number;
};

type WifiTestRequest = WifiRequest & {
  restoreAfterTest?: boolean;
};

const api = Object.freeze({
  openProject: () => ipcRenderer.invoke("file:open-project"),
  saveProject: (request: SaveProjectRequest) => ipcRenderer.invoke("file:save-project", request),
  openCSV: () => ipcRenderer.invoke("file:open-csv"),
  openImage: () => ipcRenderer.invoke("file:open-image"),
  savePNG: (request: SavePNGRequest) => ipcRenderer.invoke("file:save-png", request),
  exportPDF: (request: PrintableHTMLRequest) => ipcRenderer.invoke("output:export-pdf", request),
  renderPDFForTest: (request: PrintableHTMLRequest) => ipcRenderer.invoke("output:render-pdf-for-test", request),
  print: (request: PrintableHTMLRequest) => ipcRenderer.invoke("output:print", request),
  waitForPrintDrain: (request: PrintDrainRequest) => ipcRenderer.invoke("output:wait-for-print-drain", request),
  getOSInfo: () => ipcRenderer.invoke("system:os-info"),
  setTheme: (theme: "light" | "dark" | "system") => ipcRenderer.invoke("system:set-theme", theme),
  wifi: Object.freeze({
    getStatus: () => ipcRenderer.invoke("wifi:status"),
    test: (request: WifiTestRequest) => ipcRenderer.invoke("wifi:test", request),
    switch: (request: WifiRequest) => ipcRenderer.invoke("wifi:switch", request),
    restore: (sessionToken: string) => ipcRenderer.invoke("wifi:restore", sessionToken),
  }),
});

contextBridge.exposeInMainWorld("iLabelDesktop", api);
