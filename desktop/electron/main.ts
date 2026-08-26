import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  nativeTheme,
  protocol,
  session,
  type IpcMainInvokeEvent,
  type OpenDialogOptions,
  type SaveDialogOptions,
  type WebContentsPrintOptions,
} from "electron";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PDFDocument } from "pdf-lib";
import { scheduleUpdateChecks } from "./updater";

type Success<T> = { status: "success"; data: T };
type Cancelled = { status: "cancelled" };
type Failure = {
  status: "error";
  error: { code: string; message: string };
};
type IpcResult<T> = Success<T> | Cancelled | Failure;

interface SaveProjectRequest {
  data: string;
  suggestedName: string;
  existingPath?: string;
}

interface SavePNGRequest {
  base64: string;
  suggestedName: string;
}

interface PrintableHTMLRequest {
  html: string;
  pageWidthMM: number;
  pageHeightMM: number;
  suggestedName?: string;
  jobTitle?: string;
}

interface PrintDrainRequest {
  baselineJobIDs: string[];
  timeoutMs?: number;
}

interface WifiRequest {
  ssid: string;
  password?: string;
  interfaceName?: string;
  restoreSSID?: string;
  timeoutMs?: number;
}

interface WifiTestRequest extends WifiRequest {
  restoreAfterTest?: boolean;
}

interface WifiSession {
  platform: "win32" | "linux";
  previousSSID?: string;
  previousConnection?: string;
  interfaceName?: string;
  temporaryProfile?: string;
}

interface CommandOutput {
  stdout: string;
  stderr: string;
}

class MainProcessError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "MainProcessError";
    this.code = code;
  }
}

const IPC = {
  openProject: "file:open-project",
  saveProject: "file:save-project",
  openCSV: "file:open-csv",
  openImage: "file:open-image",
  savePNG: "file:save-png",
  exportPDF: "output:export-pdf",
  renderPDFForTest: "output:render-pdf-for-test",
  print: "output:print",
  waitForPrintDrain: "output:wait-for-print-drain",
  osInfo: "system:os-info",
  setTheme: "system:set-theme",
  wifiStatus: "wifi:status",
  wifiTest: "wifi:test",
  wifiSwitch: "wifi:switch",
  wifiRestore: "wifi:restore",
} as const;

const MAX_TEXT_BYTES = 256 * 1024 * 1024;
const MAX_IMAGE_BYTES = 128 * 1024 * 1024;
const MAX_HTML_BYTES = 256 * 1024 * 1024;
const authorizedProjectPaths = new Set<string>();
const wifiSessions = new Map<string, WifiSession>();

let mainWindow: BrowserWindow | null = null;

protocol.registerSchemesAsPrivileged([
  {
    scheme: "app",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: false,
      corsEnabled: false,
      stream: true,
    },
  },
]);

function success<T>(data: T): Success<T> {
  return { status: "success", data };
}

function cancelled(): Cancelled {
  return { status: "cancelled" };
}

function failure(error: unknown, fallbackCode = "UNKNOWN_ERROR"): Failure {
  if (error instanceof MainProcessError) {
    return {
      status: "error",
      error: { code: error.code, message: error.message },
    };
  }
  const message = error instanceof Error ? error.message : String(error);
  return {
    status: "error",
    error: { code: fallbackCode, message },
  };
}

function requireMainWindow(): BrowserWindow {
  if (!mainWindow || mainWindow.isDestroyed()) {
    throw new MainProcessError("WINDOW_UNAVAILABLE", "The application window is unavailable.");
  }
  return mainWindow;
}

function assertTrustedSender(event: IpcMainInvokeEvent): void {
  const window = requireMainWindow();
  if (
    event.sender.id !== window.webContents.id ||
    event.senderFrame !== window.webContents.mainFrame ||
    !rendererURLIsAllowed(event.senderFrame.url)
  ) {
    throw new MainProcessError("UNTRUSTED_SENDER", "The IPC request did not come from the application window.");
  }
}

function handle<TArgs extends unknown[], TResult>(
  channel: string,
  handler: (...args: TArgs) => Promise<IpcResult<TResult>> | IpcResult<TResult>,
): void {
  ipcMain.handle(channel, async (event, ...args: TArgs) => {
    try {
      assertTrustedSender(event);
      return await handler(...args);
    } catch (error) {
      return failure(error);
    }
  });
}

function normalizedProjectPath(filePath: string): string {
  const resolved = path.resolve(filePath);
  return process.platform === "win32" ? resolved.toLocaleLowerCase("en-US") : resolved;
}

function sanitizeSuggestedName(input: string, fallback: string, extension: string): string {
  let name = path.basename(typeof input === "string" ? input : "")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-")
    .replace(/[. ]+$/g, "")
    .trim();
  if (!name) name = fallback;

  const reserved = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i;
  if (reserved.test(name)) name = `_${name}`;
  if (!name.toLocaleLowerCase("en-US").endsWith(extension.toLocaleLowerCase("en-US"))) {
    name += extension;
  }
  return name.slice(0, 180);
}

function ensureFileExtension(filePath: string, extension: string): string {
  return filePath.toLocaleLowerCase("en-US").endsWith(extension.toLocaleLowerCase("en-US"))
    ? filePath
    : `${filePath}${extension}`;
}

function assertString(value: unknown, field: string, maxBytes: number): asserts value is string {
  if (typeof value !== "string") {
    throw new MainProcessError("INVALID_ARGUMENT", `${field} must be a string.`);
  }
  if (Buffer.byteLength(value, "utf8") > maxBytes) {
    throw new MainProcessError("PAYLOAD_TOO_LARGE", `${field} is too large.`);
  }
}

function validateProjectJSON(data: string): void {
  assertString(data, "Project data", MAX_TEXT_BYTES);
  let parsed: unknown;
  try {
    parsed = JSON.parse(data);
  } catch {
    throw new MainProcessError("INVALID_PROJECT_JSON", "The project data is not valid JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new MainProcessError("INVALID_PROJECT_JSON", "The project JSON must contain an object.");
  }
}

async function openTextFile(options: OpenDialogOptions): Promise<IpcResult<{ path: string; name: string; text: string }>> {
  const result = await dialog.showOpenDialog(requireMainWindow(), options);
  if (result.canceled || result.filePaths.length === 0) return cancelled();

  const filePath = result.filePaths[0];
  const buffer = await readFile(filePath);
  if (buffer.byteLength > MAX_TEXT_BYTES) {
    throw new MainProcessError("FILE_TOO_LARGE", "The selected file is too large.");
  }
  return success({ path: filePath, name: path.basename(filePath), text: decodeText(buffer) });
}

function decodeText(buffer: Buffer): string {
  if (buffer.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]))) {
    return buffer.subarray(3).toString("utf8");
  }
  if (buffer.subarray(0, 2).equals(Buffer.from([0xff, 0xfe]))) {
    return buffer.subarray(2).toString("utf16le");
  }
  if (buffer.subarray(0, 2).equals(Buffer.from([0xfe, 0xff]))) {
    const body = Buffer.from(buffer.subarray(2));
    for (let index = 0; index + 1 < body.length; index += 2) {
      const first = body[index];
      body[index] = body[index + 1];
      body[index + 1] = first;
    }
    return body.toString("utf16le");
  }
  return buffer.toString("utf8");
}

async function openProject(): Promise<IpcResult<{ path: string; name: string; text: string }>> {
  const result = await openTextFile({
    title: "Open iLabel Studio Project",
    properties: ["openFile"],
    filters: [
      { name: "iLabel Studio project", extensions: ["json"] },
      { name: "All files", extensions: ["*"] },
    ],
  });
  if (result.status !== "success") return result;
  validateProjectJSON(result.data.text);
  authorizedProjectPaths.add(normalizedProjectPath(result.data.path));
  return result;
}

async function saveProject(request: SaveProjectRequest): Promise<IpcResult<{ path: string; name: string }>> {
  if (!request || typeof request !== "object") {
    throw new MainProcessError("INVALID_ARGUMENT", "Missing project save request.");
  }
  validateProjectJSON(request.data);
  const suggestedName = sanitizeSuggestedName(request.suggestedName, "Untitled", ".ilabel.json");

  let targetPath: string | undefined;
  if (typeof request.existingPath === "string") {
    const normalized = normalizedProjectPath(request.existingPath);
    if (authorizedProjectPaths.has(normalized) && path.extname(request.existingPath).toLowerCase() === ".json") {
      targetPath = path.resolve(request.existingPath);
    }
  }

  if (!targetPath) {
    const options: SaveDialogOptions = {
      title: "Save iLabel Studio Project",
      defaultPath: suggestedName,
      filters: [{ name: "iLabel Studio project", extensions: ["json"] }],
    };
    const result = await dialog.showSaveDialog(requireMainWindow(), options);
    if (result.canceled || !result.filePath) return cancelled();
    targetPath = ensureFileExtension(result.filePath, ".json");
  }

  await writeFile(targetPath, request.data, { encoding: "utf8", mode: 0o600 });
  authorizedProjectPaths.add(normalizedProjectPath(targetPath));
  return success({ path: targetPath, name: path.basename(targetPath) });
}

async function openCSV(): Promise<IpcResult<{ path: string; name: string; text: string }>> {
  return openTextFile({
    title: "Open CSV Data",
    properties: ["openFile"],
    filters: [
      { name: "Delimited text", extensions: ["csv", "tsv", "txt"] },
      { name: "All files", extensions: ["*"] },
    ],
  });
}

function imageMimeType(filePath: string): string {
  switch (path.extname(filePath).toLowerCase()) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".webp": return "image/webp";
    case ".bmp": return "image/bmp";
    case ".svg": return "image/svg+xml";
    case ".tif":
    case ".tiff": return "image/tiff";
    default: return "application/octet-stream";
  }
}

async function openImage(): Promise<IpcResult<{ path: string; name: string; base64: string; mime: string }>> {
  const result = await dialog.showOpenDialog(requireMainWindow(), {
    title: "Choose an Image",
    properties: ["openFile"],
    filters: [
      { name: "Images", extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tif", "tiff"] },
      { name: "All files", extensions: ["*"] },
    ],
  });
  if (result.canceled || result.filePaths.length === 0) return cancelled();

  const filePath = result.filePaths[0];
  const data = await readFile(filePath);
  if (data.byteLength > MAX_IMAGE_BYTES) {
    throw new MainProcessError("FILE_TOO_LARGE", "The selected image is too large.");
  }
  return success({
    path: filePath,
    name: path.basename(filePath),
    base64: data.toString("base64"),
    mime: imageMimeType(filePath),
  });
}

function decodePNG(input: string): Buffer {
  assertString(input, "PNG data", MAX_IMAGE_BYTES * 2);
  const match = /^data:image\/png;base64,(.*)$/s.exec(input);
  const encoded = (match?.[1] ?? input).replace(/\s+/g, "");
  if (!encoded || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new MainProcessError("INVALID_PNG", "The PNG payload is not valid base64 data.");
  }
  const data = Buffer.from(encoded, "base64");
  if (data.byteLength > MAX_IMAGE_BYTES) {
    throw new MainProcessError("PAYLOAD_TOO_LARGE", "The PNG payload is too large.");
  }
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (data.byteLength < signature.length || !data.subarray(0, signature.length).equals(signature)) {
    throw new MainProcessError("INVALID_PNG", "The payload does not contain a PNG image.");
  }
  return data;
}

async function savePNG(request: SavePNGRequest): Promise<IpcResult<{ path: string; name: string }>> {
  if (!request || typeof request !== "object") {
    throw new MainProcessError("INVALID_ARGUMENT", "Missing PNG save request.");
  }
  const data = decodePNG(request.base64);
  const defaultPath = sanitizeSuggestedName(request.suggestedName, "label-page", ".png");
  const result = await dialog.showSaveDialog(requireMainWindow(), {
    title: "Export PNG",
    defaultPath,
    filters: [{ name: "PNG image", extensions: ["png"] }],
  });
  if (result.canceled || !result.filePath) return cancelled();
  const targetPath = ensureFileExtension(result.filePath, ".png");
  await writeFile(targetPath, data, { mode: 0o600 });
  return success({ path: targetPath, name: path.basename(targetPath) });
}

function validatePrintableRequest(request: PrintableHTMLRequest): PrintableHTMLRequest {
  if (!request || typeof request !== "object") {
    throw new MainProcessError("INVALID_ARGUMENT", "Missing printable HTML request.");
  }
  assertString(request.html, "Printable HTML", MAX_HTML_BYTES);
  for (const [name, value] of [
    ["pageWidthMM", request.pageWidthMM],
    ["pageHeightMM", request.pageHeightMM],
  ] as const) {
    if (!Number.isFinite(value) || value < 1 || value > 2_000) {
      throw new MainProcessError("INVALID_PAGE_SIZE", `${name} must be between 1 and 2000 millimeters.`);
    }
  }
  return request;
}

function printableHTML(request: PrintableHTMLRequest): string {
  const policy = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; script-src 'none'; connect-src 'none'; media-src data: blob:";
  const title = (request.jobTitle || "iLabel Studio")
    .slice(0, 128)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  const head = [
    '<meta charset="UTF-8">',
    `<meta http-equiv="Content-Security-Policy" content="${policy}">`,
    `<title>${title}</title>`,
    "<style>",
    `@page { size: ${request.pageWidthMM}mm ${request.pageHeightMM}mm; margin: 0; }`,
    "html, body { margin: 0 !important; padding: 0 !important; print-color-adjust: exact; -webkit-print-color-adjust: exact; }",
    "</style>",
  ].join("");

  if (/<head(?:\s[^>]*)?>/i.test(request.html)) {
    return request.html.replace(/<head(?:\s[^>]*)?>/i, (tag) => `${tag}${head}`);
  }
  if (/<html(?:\s[^>]*)?>/i.test(request.html)) {
    return request.html.replace(/<html(?:\s[^>]*)?>/i, (tag) => `${tag}<head>${head}</head>`);
  }
  return `<!doctype html><html><head>${head}</head><body>${request.html}</body></html>`;
}

async function withPrintableWindow<T>(
  request: PrintableHTMLRequest,
  operation: (window: BrowserWindow) => Promise<T>,
): Promise<T> {
  validatePrintableRequest(request);
  const tempDirectory = await mkdtemp(path.join(app.getPath("temp"), "ilabel2-print-"));
  const htmlPath = path.join(tempDirectory, "document.html");
  let printWindow: BrowserWindow | null = null;
  try {
    await writeFile(htmlPath, printableHTML(request), { encoding: "utf8", mode: 0o600 });
    printWindow = new BrowserWindow({
      show: false,
      backgroundColor: "#ffffff",
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        javascript: true,
        backgroundThrottling: false,
      },
    });
    printWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    await printWindow.loadFile(htmlPath);
    printWindow.webContents.on("will-navigate", (event) => event.preventDefault());
    await Promise.race([
      printWindow.webContents.executeJavaScript(
        "document.fonts.ready.then(() => true)",
        true,
      ),
      new Promise((resolve) => setTimeout(resolve, 10_000)),
    ]);
    return await operation(printWindow);
  } finally {
    if (printWindow && !printWindow.isDestroyed()) printWindow.destroy();
    await rm(tempDirectory, { recursive: true, force: true }).catch(() => undefined);
  }
}

function pageSizeMicrons(request: PrintableHTMLRequest): { width: number; height: number } {
  return {
    width: Math.round(request.pageWidthMM * 1_000),
    height: Math.round(request.pageHeightMM * 1_000),
  };
}

async function exportPDF(request: PrintableHTMLRequest): Promise<IpcResult<{ path: string; name: string }>> {
  validatePrintableRequest(request);
  const defaultPath = sanitizeSuggestedName(request.suggestedName ?? "label-pages", "label-pages", ".pdf");
  const selected = await dialog.showSaveDialog(requireMainWindow(), {
    title: "Export PDF",
    defaultPath,
    filters: [{ name: "PDF document", extensions: ["pdf"] }],
  });
  if (selected.canceled || !selected.filePath) return cancelled();

  const targetPath = ensureFileExtension(selected.filePath, ".pdf");

  const pdf = await createPDFData(request);
  await writeFile(targetPath, pdf, { mode: 0o600 });
  return success({ path: targetPath, name: path.basename(targetPath) });
}

async function createPDFData(request: PrintableHTMLRequest): Promise<Buffer> {
  const raw = await withPrintableWindow(request, (window) => window.webContents.printToPDF({
    printBackground: true,
    preferCSSPageSize: true,
    margins: { top: 0, bottom: 0, left: 0, right: 0 },
  }));
  const pdf = await PDFDocument.load(raw);
  const targetWidth = request.pageWidthMM * 72 / 25.4;
  const targetHeight = request.pageHeightMM * 72 / 25.4;
  for (const page of pdf.getPages()) {
    const current = page.getSize();
    page.scaleContent(targetWidth / current.width, targetHeight / current.height);
    page.setMediaBox(0, 0, targetWidth, targetHeight);
    page.setCropBox(0, 0, targetWidth, targetHeight);
    page.setBleedBox(0, 0, targetWidth, targetHeight);
    page.setTrimBox(0, 0, targetWidth, targetHeight);
    page.setArtBox(0, 0, targetWidth, targetHeight);
  }
  return Buffer.from(await pdf.save({ useObjectStreams: false }));
}

async function renderPDFForTest(
  request: PrintableHTMLRequest,
): Promise<IpcResult<{ base64: string }>> {
  if (!process.argv.includes("--enable-output-test-api")) {
    throw new MainProcessError("TEST_API_DISABLED", "The output test API is disabled.");
  }
  const pdf = await createPDFData(request);
  return success({ base64: pdf.toString("base64") });
}

async function printHTML(request: PrintableHTMLRequest): Promise<IpcResult<{ jobTitle: string; baselineJobIDs?: string[] }>> {
  validatePrintableRequest(request);
  const jobTitle = typeof request.jobTitle === "string" && request.jobTitle.trim()
    ? request.jobTitle.trim().slice(0, 128)
    : "iLabel Studio";
  const baselineJobIDs = await pendingPrintJobIDs().catch(() => null);

  return withPrintableWindow(request, (window) => new Promise<IpcResult<{ jobTitle: string; baselineJobIDs?: string[] }>>((resolve) => {
    const options: WebContentsPrintOptions = {
      silent: false,
      printBackground: true,
      pageSize: pageSizeMicrons(request),
      margins: { marginType: "none" },
      header: "",
      footer: "",
    };
    window.webContents.print(options, (didSucceed, reason) => {
      if (didSucceed) {
        resolve(success({
          jobTitle,
          ...(baselineJobIDs ? { baselineJobIDs } : {}),
        }));
      } else if (/cancel/i.test(reason ?? "")) {
        resolve(cancelled());
      } else {
        resolve(failure(new MainProcessError("PRINT_FAILED", reason || "The print job failed.")));
      }
    });
  }));
}

function validateWifiRequest(request: WifiRequest): WifiRequest {
  if (!request || typeof request !== "object") {
    throw new MainProcessError("INVALID_ARGUMENT", "Missing Wi-Fi request.");
  }
  for (const [field, value, maximum] of [
    ["SSID", request.ssid, 128],
    ["password", request.password, 256],
    ["interface name", request.interfaceName, 256],
    ["restore SSID", request.restoreSSID, 128],
  ] as const) {
    if (value === undefined && field !== "SSID") continue;
    if (typeof value !== "string" || value.length > maximum || /[\u0000\r\n]/.test(value)) {
      throw new MainProcessError("INVALID_WIFI_ARGUMENT", `The ${field} is invalid.`);
    }
  }
  if (!request.ssid.trim()) {
    throw new MainProcessError("INVALID_WIFI_ARGUMENT", "The printer SSID is empty.");
  }
  if (process.platform === "linux" && (request.ssid.startsWith("-") || request.interfaceName?.startsWith("-") || request.restoreSSID?.startsWith("-"))) {
    throw new MainProcessError("INVALID_WIFI_ARGUMENT", "Wi-Fi names beginning with '-' are not supported.");
  }
  if (request.timeoutMs !== undefined && (!Number.isFinite(request.timeoutMs) || request.timeoutMs < 1_000 || request.timeoutMs > 120_000)) {
    throw new MainProcessError("INVALID_WIFI_ARGUMENT", "timeoutMs must be between 1000 and 120000.");
  }
  return request;
}

function commandErrorMessage(output: CommandOutput, fallback: string): string {
  const message = (output.stderr || output.stdout).trim();
  return message ? message.slice(0, 2_000) : fallback;
}

async function runCommand(command: string, args: readonly string[], timeoutMs = 30_000): Promise<CommandOutput> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, [...args], {
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, LANG: "C", LC_ALL: "C" },
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let outputBytes = 0;
    let finished = false;

    const finish = (error?: Error, result?: CommandOutput): void => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(result ?? { stdout: "", stderr: "" });
    };

    const collect = (target: Buffer[], chunk: Buffer): void => {
      outputBytes += chunk.byteLength;
      if (outputBytes > 4 * 1024 * 1024) {
        child.kill();
        finish(new MainProcessError("COMMAND_OUTPUT_TOO_LARGE", "The Wi-Fi command returned too much output."));
        return;
      }
      target.push(chunk);
    };

    child.stdout.on("data", (chunk: Buffer) => collect(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => collect(stderr, chunk));
    child.once("error", (error) => finish(new MainProcessError("COMMAND_UNAVAILABLE", error.message)));
    child.once("close", (code) => {
      const result = {
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      };
      if (code === 0) finish(undefined, result);
      else finish(new MainProcessError("COMMAND_FAILED", commandErrorMessage(result, `Wi-Fi command exited with code ${code}.`)));
    });

    const timer = setTimeout(() => {
      child.kill();
      finish(new MainProcessError("COMMAND_TIMEOUT", "The Wi-Fi command timed out."));
    }, timeoutMs);
  });
}

async function pendingPrintJobIDs(): Promise<string[] | null> {
  try {
    let output: CommandOutput;
    if (process.platform === "win32") {
      const powershell = path.join(
        process.env.SystemRoot || "C:\\Windows",
        "System32",
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe",
      );
      await access(powershell);
      const script = "Get-Printer | ForEach-Object { $printerName = $_.Name; Get-PrintJob -PrinterName $printerName -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ($printerName + '|' + $_.ID) } }";
      output = await runCommand(
        powershell,
        ["-NoProfile", "-NonInteractive", "-Command", script],
        12_000,
      );
    } else if (process.platform === "linux") {
      const candidates = ["/usr/bin/lpstat", "/bin/lpstat"];
      let lpstat: string | undefined;
      for (const candidate of candidates) {
        try {
          await access(candidate);
          lpstat = candidate;
          break;
        } catch {
          // Try the next fixed system path.
        }
      }
      if (!lpstat) return null;
      output = await runCommand(lpstat, ["-o"], 12_000);
    } else {
      return null;
    }

    const jobs = output.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => process.platform === "linux" ? line.split(/\s+/, 1)[0] : line)
      .filter((value): value is string => Boolean(value));
    return [...new Set(jobs)];
  } catch {
    return null;
  }
}

async function waitForPrintDrain(request: PrintDrainRequest): Promise<IpcResult<{
  supported: boolean;
  drained: boolean;
  observedJob: boolean;
  remainingJobIDs: string[];
}>> {
  if (!request || typeof request !== "object" || !Array.isArray(request.baselineJobIDs)) {
    throw new MainProcessError("INVALID_ARGUMENT", "Missing print-drain request.");
  }
  if (request.baselineJobIDs.some((job) => typeof job !== "string" || job.length > 512 || /[\r\n\u0000]/.test(job))) {
    throw new MainProcessError("INVALID_ARGUMENT", "The print-job baseline is invalid.");
  }
  const timeoutMs = request.timeoutMs ?? 45_000;
  if (!Number.isFinite(timeoutMs) || timeoutMs < 5_000 || timeoutMs > 180_000) {
    throw new MainProcessError("INVALID_ARGUMENT", "Print-drain timeout must be between 5 and 180 seconds.");
  }
  const first = await pendingPrintJobIDs();
  if (first === null) {
    return success({ supported: false, drained: false, observedJob: false, remainingJobIDs: [] });
  }

  const baseline = new Set(request.baselineJobIDs);
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let observedJob = false;
  let remaining: string[] = [];
  while (Date.now() < deadline) {
    const current = await pendingPrintJobIDs();
    if (current === null) {
      return success({ supported: false, drained: false, observedJob, remainingJobIDs: remaining });
    }
    remaining = current.filter((job) => !baseline.has(job));
    if (remaining.length > 0) {
      observedJob = true;
    } else if (observedJob || Date.now() - startedAt >= 5_000) {
      return success({ supported: true, drained: true, observedJob, remainingJobIDs: [] });
    }
    await new Promise((resolve) => setTimeout(resolve, 750));
  }
  return success({ supported: true, drained: false, observedJob, remainingJobIDs: remaining });
}

function windowsNetsh(): string {
  return path.join(process.env.SystemRoot || "C:\\Windows", "System32", "netsh.exe");
}

function fieldValue(output: string, field: RegExp): string | undefined {
  for (const line of output.split(/\r?\n/)) {
    const match = /^\s*([^:]+?)\s*:\s*(.*?)\s*$/.exec(line);
    if (match && field.test(match[1].trim()) && match[2]) return match[2].trim();
  }
  return undefined;
}

async function windowsWifiStatus(): Promise<{
  supported: true;
  platform: "win32";
  tool: "netsh";
  currentSSID?: string;
  interfaceName?: string;
  connectionName?: string;
}> {
  const output = await runCommand(windowsNetsh(), ["wlan", "show", "interfaces"]);
  return {
    supported: true,
    platform: "win32",
    tool: "netsh",
    currentSSID: fieldValue(output.stdout, /^SSID$/i),
    interfaceName: fieldValue(output.stdout, /^(Name|Interface name)$/i),
    connectionName: fieldValue(output.stdout, /^Profile$/i),
  };
}

function splitNmcli(line: string): string[] {
  const fields: string[] = [];
  let field = "";
  let escaped = false;
  for (const character of line) {
    if (escaped) {
      field += character;
      escaped = false;
    } else if (character === "\\") {
      escaped = true;
    } else if (character === ":") {
      fields.push(field);
      field = "";
    } else {
      field += character;
    }
  }
  if (escaped) field += "\\";
  fields.push(field);
  return fields;
}

async function linuxNmcli(): Promise<string> {
  for (const candidate of ["/usr/bin/nmcli", "/bin/nmcli"]) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next fixed system path. We intentionally do not search a
      // renderer-controlled path or invoke a shell.
    }
  }
  throw new MainProcessError("WIFI_UNSUPPORTED", "NetworkManager (nmcli) is not installed.");
}

async function linuxWifiStatus(): Promise<{
  supported: true;
  platform: "linux";
  tool: "nmcli";
  currentSSID?: string;
  interfaceName?: string;
  connectionName?: string;
}> {
  const nmcli = await linuxNmcli();
  const [wifi, active] = await Promise.all([
    runCommand(nmcli, ["-t", "-f", "IN-USE,SSID,DEVICE", "device", "wifi", "list", "--rescan", "no"]),
    runCommand(nmcli, ["-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"]),
  ]);
  const current = wifi.stdout
    .split(/\r?\n/)
    .map(splitNmcli)
    .find((fields) => fields[0] === "*" || fields[0].toLowerCase() === "yes");
  const connection = active.stdout
    .split(/\r?\n/)
    .map(splitNmcli)
    .find((fields) => /(?:wireless|wifi|802-11)/i.test(fields[1] ?? ""));
  return {
    supported: true,
    platform: "linux",
    tool: "nmcli",
    currentSSID: current?.[1],
    interfaceName: current?.[2] || connection?.[2],
    connectionName: connection?.[0],
  };
}

async function wifiStatus(): Promise<{
  supported: boolean;
  platform: NodeJS.Platform;
  tool?: "netsh" | "nmcli";
  currentSSID?: string;
  interfaceName?: string;
  connectionName?: string;
}> {
  if (process.platform === "win32") return windowsWifiStatus();
  if (process.platform === "linux") return linuxWifiStatus();
  return { supported: false, platform: process.platform };
}

async function waitForSSID(expectedSSID: string, timeoutMs: number): Promise<Awaited<ReturnType<typeof wifiStatus>>> {
  const deadline = Date.now() + timeoutMs;
  let lastStatus = await wifiStatus();
  while (Date.now() < deadline) {
    if (lastStatus.currentSSID === expectedSSID) return lastStatus;
    await new Promise((resolve) => setTimeout(resolve, 700));
    lastStatus = await wifiStatus();
  }
  throw new MainProcessError("WIFI_CONNECTION_TIMEOUT", `Timed out waiting to connect to ${expectedSSID}.`);
}

function escapeXML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function windowsProfileXML(profileName: string, ssid: string, password?: string): string {
  const security = password
    ? `<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption><sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>${escapeXML(password)}</keyMaterial></sharedKey>`
    : "<authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>";
  return `<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"><name>${escapeXML(profileName)}</name><SSIDConfig><SSID><name>${escapeXML(ssid)}</name></SSID></SSIDConfig><connectionType>ESS</connectionType><connectionMode>manual</connectionMode><MSM><security>${security}</security></MSM></WLANProfile>`;
}

async function addTemporaryWindowsProfile(request: WifiRequest): Promise<string> {
  const profileName = `iLabel-Studio-${randomUUID()}`;
  const directory = await mkdtemp(path.join(app.getPath("temp"), "ilabel2-wifi-"));
  const profilePath = path.join(directory, "profile.xml");
  try {
    await writeFile(profilePath, windowsProfileXML(profileName, request.ssid, request.password), { encoding: "utf8", mode: 0o600 });
    const args = ["wlan", "add", "profile", `filename=${profilePath}`, "user=current"];
    if (request.interfaceName) args.push(`interface=${request.interfaceName}`);
    await runCommand(windowsNetsh(), args);
    return profileName;
  } finally {
    await rm(directory, { recursive: true, force: true }).catch(() => undefined);
  }
}

async function connectWindowsWifi(request: WifiRequest): Promise<{ status: Awaited<ReturnType<typeof wifiStatus>>; temporaryProfile?: string }> {
  const timeoutMs = request.timeoutMs ?? 25_000;
  let profileName = request.ssid;
  let temporaryProfile: string | undefined;
  try {
    if (request.password) {
      temporaryProfile = await addTemporaryWindowsProfile(request);
      profileName = temporaryProfile;
    }

    const args = ["wlan", "connect", `name=${profileName}`, `ssid=${request.ssid}`];
    if (request.interfaceName) args.push(`interface=${request.interfaceName}`);
    await runCommand(windowsNetsh(), args, timeoutMs);

    try {
      return { status: await waitForSSID(request.ssid, timeoutMs), temporaryProfile };
    } catch (firstError) {
      if (temporaryProfile) throw firstError;
      temporaryProfile = await addTemporaryWindowsProfile(request);
      const retry = ["wlan", "connect", `name=${temporaryProfile}`, `ssid=${request.ssid}`];
      if (request.interfaceName) retry.push(`interface=${request.interfaceName}`);
      await runCommand(windowsNetsh(), retry, timeoutMs);
      return { status: await waitForSSID(request.ssid, timeoutMs), temporaryProfile };
    }
  } catch (error) {
    if (temporaryProfile) {
      await deleteWindowsProfile(temporaryProfile, request.interfaceName);
    }
    throw error;
  }
}

async function connectLinuxWifi(request: WifiRequest): Promise<Awaited<ReturnType<typeof wifiStatus>>> {
  const nmcli = await linuxNmcli();
  const timeoutMs = request.timeoutMs ?? 25_000;
  const args = ["--wait", String(Math.ceil(timeoutMs / 1_000)), "device", "wifi", "connect", request.ssid];
  if (request.password) args.push("password", request.password);
  if (request.interfaceName) args.push("ifname", request.interfaceName);
  await runCommand(nmcli, args, timeoutMs + 2_000);
  return waitForSSID(request.ssid, timeoutMs);
}

async function switchWifi(request: WifiRequest): Promise<{
  sessionToken: string;
  targetSSID: string;
  previousSSID?: string;
  currentSSID?: string;
  interfaceName?: string;
}> {
  validateWifiRequest(request);
  if (process.platform !== "win32" && process.platform !== "linux") {
    throw new MainProcessError("WIFI_UNSUPPORTED", "Wi-Fi switching is supported only on Windows and Linux.");
  }

  const before = await wifiStatus();
  let after: Awaited<ReturnType<typeof wifiStatus>>;
  let temporaryProfile: string | undefined;
  if (process.platform === "win32") {
    const connected = await connectWindowsWifi(request);
    after = connected.status;
    temporaryProfile = connected.temporaryProfile;
  } else {
    after = await connectLinuxWifi(request);
  }

  const sessionToken = randomUUID();
  wifiSessions.set(sessionToken, {
    platform: process.platform as "win32" | "linux",
    previousSSID: before.currentSSID || request.restoreSSID?.trim() || undefined,
    previousConnection: before.connectionName || request.restoreSSID?.trim() || undefined,
    interfaceName: before.interfaceName || request.interfaceName,
    temporaryProfile,
  });
  return {
    sessionToken,
    targetSSID: request.ssid,
    previousSSID: before.currentSSID || request.restoreSSID?.trim() || undefined,
    currentSSID: after.currentSSID,
    interfaceName: after.interfaceName,
  };
}

async function deleteWindowsProfile(profileName: string, interfaceName?: string): Promise<void> {
  const args = ["wlan", "delete", "profile", `name=${profileName}`];
  if (interfaceName) args.push(`interface=${interfaceName}`);
  await runCommand(windowsNetsh(), args).catch(() => undefined);
}

async function restoreWifi(sessionToken: string): Promise<{
  restored: boolean;
  currentSSID?: string;
}> {
  if (typeof sessionToken !== "string" || !/^[0-9a-f-]{36}$/i.test(sessionToken)) {
    throw new MainProcessError("INVALID_ARGUMENT", "The Wi-Fi session token is invalid.");
  }
  const session = wifiSessions.get(sessionToken);
  if (!session) {
    throw new MainProcessError("WIFI_SESSION_NOT_FOUND", "The Wi-Fi restore session has expired.");
  }

  try {
    const hasRestoreTarget = Boolean(session.previousConnection || session.previousSSID);
    if (session.platform === "win32") {
      if (hasRestoreTarget) {
        const profile = session.previousConnection || session.previousSSID!;
        const args = ["wlan", "connect", `name=${profile}`];
        if (session.previousSSID) args.push(`ssid=${session.previousSSID}`);
        if (session.interfaceName) args.push(`interface=${session.interfaceName}`);
        await runCommand(windowsNetsh(), args);
        if (session.previousSSID) await waitForSSID(session.previousSSID, 25_000);
      }
    } else if (hasRestoreTarget) {
      const connection = session.previousConnection || session.previousSSID!;
      if (connection.startsWith("-")) {
        throw new MainProcessError("WIFI_RESTORE_FAILED", "Cannot restore a connection name beginning with '-'.");
      }
      const nmcli = await linuxNmcli();
      const args = ["--wait", "25", "connection", "up", "id", connection];
      if (session.interfaceName) args.push("ifname", session.interfaceName);
      await runCommand(nmcli, args, 27_000);
      if (session.previousSSID) await waitForSSID(session.previousSSID, 25_000);
    }

    const status = await wifiStatus();
    return { restored: hasRestoreTarget, currentSSID: status.currentSSID };
  } catch (error) {
    throw new MainProcessError(
      "WIFI_RESTORE_FAILED",
      error instanceof Error ? error.message : "Could not restore the previous Wi-Fi network.",
    );
  } finally {
    if (session.platform === "win32" && session.temporaryProfile) {
      await deleteWindowsProfile(session.temporaryProfile, session.interfaceName);
    }
    wifiSessions.delete(sessionToken);
  }
}

async function testWifi(request: WifiTestRequest): Promise<{
  connected: boolean;
  restored: boolean;
  targetSSID: string;
  currentSSID?: string;
  restoreError?: string;
}> {
  validateWifiRequest(request);
  const switched = await switchWifi(request);
  const session = wifiSessions.get(switched.sessionToken);
  const shouldRestore = request.restoreAfterTest !== false
    && Boolean(session?.previousSSID || session?.previousConnection);
  if (!shouldRestore) {
    return {
      connected: true,
      restored: false,
      targetSSID: switched.targetSSID,
      currentSSID: switched.currentSSID,
    };
  }

  await new Promise((resolve) => setTimeout(resolve, 1_500));
  try {
    const restored = await restoreWifi(switched.sessionToken);
    return {
      connected: true,
      restored: restored.restored,
      targetSSID: switched.targetSSID,
      currentSSID: restored.currentSSID,
    };
  } catch (error) {
    return {
      connected: true,
      restored: false,
      targetSSID: switched.targetSSID,
      currentSSID: switched.currentSSID,
      restoreError: error instanceof Error ? error.message : String(error),
    };
  }
}

function registerIPC(): void {
  handle(IPC.openProject, openProject);
  handle(IPC.saveProject, saveProject);
  handle(IPC.openCSV, openCSV);
  handle(IPC.openImage, openImage);
  handle(IPC.savePNG, savePNG);
  handle(IPC.exportPDF, exportPDF);
  handle(IPC.renderPDFForTest, renderPDFForTest);
  handle(IPC.print, printHTML);
  handle(IPC.waitForPrintDrain, waitForPrintDrain);
  handle(IPC.osInfo, async () => success({
    platform: process.platform,
    arch: process.arch,
    release: os.release(),
    version: os.version(),
    appVersion: app.getVersion(),
    isPackaged: app.isPackaged,
  }));
  handle(IPC.setTheme, async (theme: unknown) => {
    if (theme !== "light" && theme !== "dark" && theme !== "system") {
      throw new MainProcessError("INVALID_THEME", "Theme must be light, dark, or system.");
    }
    nativeTheme.themeSource = theme;
    return success(theme);
  });
  handle(IPC.wifiStatus, async () => success(await wifiStatus()));
  handle(IPC.wifiTest, async (request: WifiTestRequest) => success(await testWifi(request)));
  handle(IPC.wifiSwitch, async (request: WifiRequest) => success(await switchWifi(request)));
  handle(IPC.wifiRestore, async (sessionToken: string) => success(await restoreWifi(sessionToken)));
}

function trustedDevelopmentURL(): string | undefined {
  if (app.isPackaged) return undefined;
  const configured = process.env.VITE_DEV_SERVER_URL;
  if (!configured) return undefined;
  try {
    const parsed = new URL(configured);
    const localHost = parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost" || parsed.hostname === "[::1]";
    return parsed.protocol === "http:" && localHost ? parsed.href : undefined;
  } catch {
    return undefined;
  }
}

function rendererURLIsAllowed(targetURL: string): boolean {
  const developmentURL = trustedDevelopmentURL();
  if (developmentURL) {
    try {
      return new URL(targetURL).origin === new URL(developmentURL).origin;
    } catch {
      return false;
    }
  }
  try {
    const parsed = new URL(targetURL);
    return parsed.protocol === "app:" && parsed.hostname === "renderer";
  } catch {
    return false;
  }
}

function rendererMIMEType(filePath: string): string {
  switch (path.extname(filePath).toLowerCase()) {
    case ".html": return "text/html; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".json":
    case ".map": return "application/json; charset=utf-8";
    case ".png": return "image/png";
    case ".svg": return "image/svg+xml";
    case ".ico": return "image/x-icon";
    default: return "application/octet-stream";
  }
}

function registerRendererProtocol(): void {
  protocol.handle("app", async (request) => {
    try {
      const url = new URL(request.url);
      if (url.hostname !== "renderer") {
        return new Response("Not found", { status: 404 });
      }
      const requestedPath = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "index.html";
      if (requestedPath !== "index.html" && !/^assets\/[A-Za-z0-9._-]+$/.test(requestedPath)) {
        return new Response("Not found", { status: 404 });
      }
      const rendererRoot = path.resolve(app.getAppPath(), "dist");
      const filePath = path.resolve(rendererRoot, requestedPath);
      const relative = path.relative(rendererRoot, filePath);
      if (relative.startsWith("..") || path.isAbsolute(relative)) {
        return new Response("Not found", { status: 404 });
      }
      const data = await readFile(filePath);
      return new Response(new Uint8Array(data), {
        headers: {
          "Content-Type": rendererMIMEType(filePath),
          "Cache-Control": requestedPath === "index.html" ? "no-store" : "public, max-age=31536000, immutable",
          "X-Content-Type-Options": "nosniff",
        },
      });
    } catch {
      return new Response("Not found", { status: 404 });
    }
  });
}

function configureRendererPermissions(): void {
  const isTrustedRequest = (requestingURL: string, isMainFrame: boolean): boolean =>
    isMainFrame && rendererURLIsAllowed(requestingURL);

  session.defaultSession.setPermissionCheckHandler(
    (_webContents, permission, requestingOrigin, details) =>
      String(permission) === "local-fonts" &&
      isTrustedRequest(details.requestingUrl ?? requestingOrigin, details.isMainFrame),
  );
  session.defaultSession.setPermissionRequestHandler(
    (_webContents, permission, callback, details) => {
      callback(
        String(permission) === "local-fonts" &&
        isTrustedRequest(details.requestingUrl, details.isMainFrame),
      );
    },
  );
}

function createMainWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1080,
    minHeight: 700,
    show: false,
    backgroundColor: "#fcfcfd",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event, targetURL) => {
    if (!rendererURLIsAllowed(targetURL)) event.preventDefault();
  });
  window.once("ready-to-show", () => window.show());

  const developmentURL = trustedDevelopmentURL();
  if (developmentURL) {
    void window.loadURL(developmentURL);
  } else {
    void window.loadURL("app://renderer/index.html");
  }
  return window;
}

void app.whenReady().then(() => {
  nativeTheme.themeSource = "light";
  registerRendererProtocol();
  configureRendererPermissions();
  registerIPC();
  mainWindow = createMainWindow();
  scheduleUpdateChecks(() => mainWindow);
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) mainWindow = createMainWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
