import { app, dialog, shell, type BrowserWindow } from "electron";
import { get } from "node:https";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

/* The feed is a few hundred bytes of JSON on the project homepage naming the
   newest version per platform. Checking it is the only outbound request the
   updater makes without being asked; the actual download happens through
   electron-updater against the GitHub release, and only after the person says
   so — asked for, never assumed. */
const FEED_URL = "https://jaeyoonsung.github.io/iLabel-Studio/feed.json";
const RELEASES_URL = "https://github.com/JAEYOONSUNG/iLabel-Studio/releases/latest";
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

interface FeedEntry {
  version: string;
  url: string;
  notes?: string;
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
   both are told how they are updated instead of offered a button that cannot
   finish. */
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
    // a missed preference write only means one extra prompt later
  }
}

function showBox(
  window: BrowserWindow | null,
  options: Electron.MessageBoxOptions,
): Promise<Electron.MessageBoxReturnValue> {
  if (window && !window.isDestroyed()) return dialog.showMessageBox(window, options);
  return dialog.showMessageBox(options);
}

let promptedThisSession = "";

async function promptAndInstall(
  window: BrowserWindow | null,
  entry: FeedEntry,
): Promise<void> {
  const detail = [
    `You have ${app.getVersion()}.`,
    entry.notes ? `\n${entry.notes}` : "",
    "\nThe update is downloaded from the project's GitHub release and installed when you restart.",
  ].join("");
  const ask = await showBox(window, {
    type: "info",
    message: `iLabel Studio ${entry.version} is available`,
    detail,
    buttons: ["Install Update", "Later", "Skip This Version"],
    defaultId: 0,
    cancelId: 1,
  });
  if (ask.response === 2) {
    await writeSkippedVersion(entry.version);
    return;
  }
  if (ask.response !== 0) return;

  try {
    const { autoUpdater } = await import("electron-updater");
    autoUpdater.autoDownload = false; // asked for, never assumed
    autoUpdater.autoInstallOnAppQuit = true; // consent was just given
    autoUpdater.logger = null;
    /* A hundred megabytes with nothing on screen reads as frozen — the dock or
       taskbar progress bar is where the percentage lives. */
    autoUpdater.on("download-progress", (progress) => {
      if (window && !window.isDestroyed()) {
        window.setProgressBar(Math.max(0, (progress?.percent || 0) / 100));
      }
    });
    const downloaded = new Promise<void>((resolve, reject) => {
      autoUpdater.once("update-downloaded", () => resolve());
      autoUpdater.once("error", (error) => reject(error));
    });
    await autoUpdater.checkForUpdates();
    await autoUpdater.downloadUpdate();
    await downloaded;
    if (window && !window.isDestroyed()) window.setProgressBar(-1);
    const restart = await showBox(window, {
      type: "info",
      message: `iLabel Studio ${entry.version} is ready`,
      detail: "Restart now to finish installing, or keep working — it installs when you quit.",
      buttons: ["Restart Now", "Later"],
      defaultId: 0,
      cancelId: 1,
    });
    if (restart.response === 0) autoUpdater.quitAndInstall();
  } catch (error) {
    if (window && !window.isDestroyed()) window.setProgressBar(-1);
    const failed = await showBox(window, {
      type: "warning",
      message: "The update could not be installed",
      detail: `${String((error as Error)?.message || error)}\n\nYou can download it yourself instead.`,
      buttons: ["Open Downloads Page", "Close"],
      defaultId: 0,
      cancelId: 1,
    });
    if (failed.response === 0) void shell.openExternal(entry.url || RELEASES_URL);
  }
}

async function tellHowToUpdate(
  window: BrowserWindow | null,
  entry: FeedEntry,
): Promise<void> {
  const how =
    process.platform === "linux"
      ? "This copy was installed from a package, so your package manager owns it — update it the way it was installed, or switch to the AppImage build, which updates itself."
      : "This is the portable build, which has no installer to hand over to — download the new portable file and replace this one, or switch to the installer build, which updates itself.";
  const ask = await showBox(window, {
    type: "info",
    message: `iLabel Studio ${entry.version} is available`,
    detail: `You have ${app.getVersion()}.\n\n${how}`,
    buttons: ["Open Downloads Page", "Later", "Skip This Version"],
    defaultId: 0,
    cancelId: 1,
  });
  if (ask.response === 0) void shell.openExternal(entry.url || RELEASES_URL);
  if (ask.response === 2) await writeSkippedVersion(entry.version);
}

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
  if (entry.version === promptedThisSession) return;
  if (entry.version === (await readSkippedVersion())) return;
  promptedThisSession = entry.version;
  if (selfUpdating()) await promptAndInstall(window, entry);
  else await tellHowToUpdate(window, entry);
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
