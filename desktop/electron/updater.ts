import { app, ipcMain, shell, type BrowserWindow } from "electron";
import { get as httpGet } from "node:http";
import { get as httpsGet } from "node:https";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

/* The feed is a few hundred bytes of JSON on the project homepage naming the
   newest version per platform. Checking it is the only outbound request the
   updater makes without being asked; the actual download happens through
   electron-updater against the GitHub release, and only after the person says
   so — asked for, never assumed. The asking itself happens in the renderer,
   which draws the offer in the app's own design instead of an OS dialog. */
const FEED_URL = process.env.ILABEL_UPDATE_FEED
  || "https://jaeyoonsung.github.io/iLabel-Studio/feed.json";
const RELEASES_URL = "https://github.com/JAEYOONSUNG/iLabel-Studio/releases/latest";
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

interface FeedEntry {
  version: string;
  url: string;
  notes?: string;
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

/** `1.1.34` against `1.1.9`: compared as numbers, field by field, because
    string order puts 1.1.9 after 1.1.34 and would offer a downgrade. */
export function newerVersion(a: string, b: string): boolean {
  const parts = (v: string): number[] =>
    String(v || "")
      .replace(/^v/, "")
      .split("-")[0]
      .split(".")
      .map((n) => Number(n) || 0);
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i += 1) {
    if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  }
  return false;
}

function fetchFeed(url: string): Promise<Record<string, FeedEntry>> {
  // Plain http never resolves for the default feed — it only exists so a test
  // can point ILABEL_UPDATE_FEED at a local server.
  const get = url.startsWith("http:") ? httpGet : httpsGet;
  return new Promise((resolve, reject) => {
    const request = get(url, { timeout: 8000 }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`HTTP ${response.statusCode}`));
        return;
      }
      let buffer = "";
      let size = 0;
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => {
        size += Buffer.byteLength(chunk, "utf8");
        // a feed is a few hundred bytes; anything else is not one
        if (size > 64 * 1024) {
          response.destroy(new Error("feed too large"));
          return;
        }
        buffer += chunk;
      });
      response.on("end", () => {
        try {
          resolve(JSON.parse(buffer));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on("timeout", () => request.destroy(new Error("timed out")));
    request.on("error", reject);
  });
}

/* On Linux the format decides, not the platform: an AppImage is one file and
   electron-updater replaces it in place. A `.deb` belongs to the package
   manager, and the Windows portable build has no installer to hand over to —
   both are handed the download instead of a button that cannot finish. */
function selfUpdating(): boolean {
  if (!app.isPackaged) return false;
  if (process.platform === "win32") return !process.env.PORTABLE_EXECUTABLE_DIR;
  if (process.platform === "linux") return Boolean(process.env.APPIMAGE);
  return false;
}

function prefsPath(): string {
  return path.join(app.getPath("userData"), "update-prefs.json");
}

async function readSkippedVersion(): Promise<string> {
  try {
    const raw = JSON.parse(await readFile(prefsPath(), "utf8")) as { skip?: string };
    return String(raw.skip || "");
  } catch {
    return "";
  }
}

async function writeSkippedVersion(version: string): Promise<void> {
  try {
    await writeFile(prefsPath(), JSON.stringify({ skip: version }), "utf8");
  } catch {
    // a missed preference write only means one extra offer later
  }
}

let offer: UpdateOffer | null = null;
let offeredThisSession = "";

async function checkForUpdate(window: BrowserWindow | null): Promise<void> {
  let feed: Record<string, FeedEntry>;
  try {
    feed = await fetchFeed(FEED_URL);
  } catch {
    return; // silent: a machine with no network must not be told something is wrong
  }
  const key = process.platform === "win32" ? "win" : "linux";
  const entry = feed[key];
  if (!entry?.version || !newerVersion(entry.version, app.getVersion())) return;
  if (entry.version === offeredThisSession) return;
  if (entry.version === (await readSkippedVersion())) return;
  offeredThisSession = entry.version;
  offer = {
    version: entry.version,
    notes: String(entry.notes || ""),
    url: String(entry.url || ""),
    current: app.getVersion(),
    self: selfUpdating(),
  };
  if (window && !window.isDestroyed()) {
    window.webContents.send("update:available", offer);
  }
}

type UpdateResult = { status: "success" } | { status: "error"; error: { code: string; message: string } };

let progressForwarderAttached = false;

async function downloadUpdate(window: BrowserWindow | null): Promise<UpdateResult> {
  try {
    const { autoUpdater } = await import("electron-updater");
    autoUpdater.autoDownload = false; // asked for, never assumed
    autoUpdater.autoInstallOnAppQuit = true; // consent was just given
    autoUpdater.logger = null;
    /* A hundred megabytes with nothing on screen reads as frozen — the banner
       shows the percentage, and the dock or taskbar mirrors it. Attached once:
       a second download must not double every progress event. */
    if (!progressForwarderAttached) {
      progressForwarderAttached = true;
      autoUpdater.on("download-progress", (progress) => {
        const percent = Math.max(0, Math.round(progress?.percent || 0));
        if (window && !window.isDestroyed()) {
          window.setProgressBar(percent / 100);
          window.webContents.send("update:progress", { percent });
        }
      });
    }
    const downloaded = new Promise<void>((resolve, reject) => {
      autoUpdater.once("update-downloaded", () => resolve());
      autoUpdater.once("error", (error) => reject(error));
    });
    await autoUpdater.checkForUpdates();
    await autoUpdater.downloadUpdate();
    await downloaded;
    if (window && !window.isDestroyed()) window.setProgressBar(-1);
    return { status: "success" };
  } catch (error) {
    if (window && !window.isDestroyed()) window.setProgressBar(-1);
    return {
      status: "error",
      error: { code: "update-download-failed", message: String((error as Error)?.message || error) },
    };
  }
}

export function registerUpdateIPC(getWindow: () => BrowserWindow | null): void {
  // A reloaded renderer asks for the standing offer; one the person already
  // skipped must not come back through that side door.
  ipcMain.handle("update:state", async () =>
    offer && offer.version !== (await readSkippedVersion()) ? offer : null);
  ipcMain.handle("update:download", () => downloadUpdate(getWindow()));
  ipcMain.handle("update:install", async () => {
    const { autoUpdater } = await import("electron-updater");
    autoUpdater.quitAndInstall();
  });
  ipcMain.handle("update:skip", async (_event, version: unknown) => {
    await writeSkippedVersion(String(version || ""));
  });
  ipcMain.handle("update:open-downloads", () => {
    void shell.openExternal(offer?.url || RELEASES_URL);
  });
}

/* A launch is the moment to look — somebody who quits and reopens after a
   release should be told, and that is the one moment they are ready to restart
   anyway. The interval only covers sessions that stay open for days. */
export function scheduleUpdateChecks(getWindow: () => BrowserWindow | null): void {
  if (!app.isPackaged) return; // running from source there is no bundle to replace
  const tick = (): void => {
    void checkForUpdate(getWindow());
  };
  setTimeout(tick, 5000);
  setInterval(tick, CHECK_EVERY_MS);
}
