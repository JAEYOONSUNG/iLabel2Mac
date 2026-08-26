#!/usr/bin/env node
/* Put a version out.

   Four things have to happen and the order is the whole point: build and
   publish the files, then move the feed, then check that a stranger can reach
   both. Moving the feed first would tell every copy of the app about a version
   that cannot be downloaded yet — a notice pointing at nothing, which is worse
   than no notice.

       node tools/release.mjs patch                 0.2.0 -> 0.2.1
       node tools/release.mjs minor                 0.2.0 -> 0.3.0
       node tools/release.mjs 0.3.0                 exactly that
       node tools/release.mjs patch --dry           say what it would do
       node tools/release.mjs patch --notes "..."   shown in the update prompt

   The heavy lifting is CI's: pushing the tag starts the Release workflow,
   which builds the DMG on a Mac runner and the Windows and Linux packages on
   theirs, publishing everything to one GitHub release. This script bumps the
   version, pushes the tag, waits for that workflow, updates feed.json on
   gh-pages, and verifies the result is publicly reachable. It refuses to start
   on a dirty tree or a failing suite, because a release is the one build
   nobody can take back. */
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const SLUG = "JAEYOONSUNG/iLabel-Studio";
const FEED_URL = "https://jaeyoonsung.github.io/iLabel-Studio/feed.json";
const FEED_BRANCH = "gh-pages";

const argv = process.argv.slice(2);
const dry = argv.includes("--dry");
const notesIndex = argv.indexOf("--notes");
const notes = notesIndex >= 0 ? String(argv[notesIndex + 1] || "") : "";
const what = argv.find((a, i) =>
  !a.startsWith("-") && (notesIndex < 0 || i !== notesIndex + 1)) || "patch";

const say = (...a) => console.log(...a);
const step = (n) => say(`\n── ${n} ──`);
const die = (m) => { console.error("\n" + m); process.exit(1); };
const run = (file, args, opts) => execFileSync(file, args,
  Object.assign({ cwd: repo, encoding: "utf8", stdio: "pipe" }, opts || {})).trim();
const runLoud = (file, args, opts) => {
  const r = spawnSync(file, args, Object.assign({ cwd: repo, stdio: "inherit" }, opts || {}));
  if (r.status !== 0) throw new Error(`${file} ${args.join(" ")} failed`);
};
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

function nextVersion(current) {
  if (/^\d+\.\d+\.\d+$/.test(what)) return what;
  const [major, minor, patch] = current.split(".").map(Number);
  if (what === "major") return `${major + 1}.0.0`;
  if (what === "minor") return `${major}.${minor + 1}.0`;
  if (what === "patch") return `${major}.${minor}.${patch + 1}`;
  die(`Not a bump I know: ${what} (patch, minor, major, or x.y.z)`);
}

step("Preflight");
const branch = run("git", ["rev-parse", "--abbrev-ref", "HEAD"]);
if (branch !== "main") die(`Releases are cut from main; this is ${branch}.`);
if (run("git", ["status", "--porcelain"])) die("The tree is dirty; a release is the one build nobody can take back.");
runLoud("git", ["pull", "--ff-only", "origin", "main"]);
const current = JSON.parse(readFileSync(join(repo, "desktop/package.json"), "utf8")).version;
const version = nextVersion(current);
const tag = `v${version}`;
say(`${current} -> ${version}`);
if (run("git", ["tag", "-l", tag])) die(`Tag ${tag} already exists.`);

step("Test");
if (dry) say("(dry) swift test && npm test");
else {
  runLoud("swift", ["test"]);
  runLoud("npm", ["test"], { cwd: join(repo, "desktop") });
}

step("Version, tag, push");
if (dry) { say(`(dry) would tag ${tag} and push`); process.exit(0); }
runLoud("npm", ["version", "--no-git-tag-version", version], { cwd: join(repo, "desktop") });
runLoud("git", ["add", "desktop/package.json", "desktop/package-lock.json"]);
runLoud("git", ["commit", "-m", `Release ${tag}`]);
runLoud("git", ["tag", tag]);
runLoud("git", ["push", "origin", "main", tag]);

step("Wait for the Release workflow");
let conclusion = "";
for (let i = 0; i < 120; i += 1) { // up to ~60 minutes
  await sleep(30_000);
  const runs = JSON.parse(run("gh", ["run", "list", "--repo", SLUG,
    "--workflow", "Release", "--json", "headBranch,status,conclusion,url"]));
  const mine = runs.find((r) => r.headBranch === tag);
  if (!mine) continue;
  process.stdout.write(`\r   ${mine.status}${" ".repeat(12)}`);
  if (mine.status === "completed") { conclusion = mine.conclusion; say(`\n   ${mine.url}`); break; }
}
if (conclusion !== "success") die(`The Release workflow did not succeed (${conclusion || "never finished"}). The feed was not moved.`);

step("Read the published assets");
const assets = JSON.parse(run("gh", ["api", `repos/${SLUG}/releases/tags/${tag}`,
  "--jq", "[.assets[].name]"]));
const url = (name) => `https://github.com/${SLUG}/releases/download/${tag}/${name}`;
const pick = (test, label) => {
  const name = assets.find(test);
  if (!name) die(`No ${label} asset in ${tag}: ${assets.join(", ")}`);
  return url(name);
};
/* The Mac updater swaps its own bundle, so the feed pins the DMG's SHA-256 —
   the checksum from this HTTPS origin is what vouches for the bytes. */
step("Fingerprint the DMG");
const hashDir = mkdtempSync(join(tmpdir(), "ilabel-release-"));
run("gh", ["release", "download", tag, "--repo", SLUG, "--pattern", "*.dmg", "--dir", hashDir]);
const dmgName = readdirSync(hashDir).find((n) => n.endsWith(".dmg"));
if (!dmgName) die("The release's DMG could not be fetched for fingerprinting.");
const dmgSha256 = createHash("sha256").update(readFileSync(join(hashDir, dmgName))).digest("hex");
rmSync(hashDir, { recursive: true, force: true });
say(`   sha256 ${dmgSha256}`);

const feed = {
  mac: { version, url: pick((n) => n.endsWith(".dmg"), "DMG"), sha256: dmgSha256, notes },
  win: { version, url: pick((n) => n.endsWith("-setup.exe"), "Windows setup"), notes },
  linux: { version, url: pick((n) => n.endsWith(".AppImage"), "AppImage"), notes },
};
for (const name of ["latest.yml", "latest-linux.yml"]) {
  if (!assets.includes(name)) die(`electron-updater metadata ${name} is missing from ${tag}.`);
}
say(JSON.stringify(feed, null, 2));

step("Move the feed");
const feedBody = Buffer.from(JSON.stringify(feed, null, 2) + "\n").toString("base64");
let feedSha = "";
try {
  feedSha = run("gh", ["api", `repos/${SLUG}/contents/feed.json?ref=${FEED_BRANCH}`, "--jq", ".sha"]);
} catch { /* first release: the file does not exist yet */ }
const putArgs = ["api", "-X", "PUT", `repos/${SLUG}/contents/feed.json`,
  "-f", `message=Point the update feed at ${tag}`,
  "-f", `content=${feedBody}`, "-f", `branch=${FEED_BRANCH}`];
if (feedSha) putArgs.push("-f", `sha=${feedSha}`);
run("gh", putArgs);

step("Verify a stranger can reach it");
let served = "";
for (let i = 0; i < 40; i += 1) { // Pages deploys take a minute
  await sleep(15_000);
  try {
    const body = run("curl", ["-fsS", `${FEED_URL}?releasecheck=${Date.now()}`]);
    served = JSON.parse(body)?.mac?.version || "";
  } catch { /* not deployed yet */ }
  if (served === version) break;
  process.stdout.write(`\r   feed still serves ${served || "nothing"}${" ".repeat(8)}`);
}
if (served !== version) die(`The public feed never caught up (serves ${served || "nothing"}).`);
for (const entry of Object.values(feed)) {
  const code = run("curl", ["-sIL", "-o", "/dev/null", "-w", "%{http_code}", entry.url]);
  if (code !== "200") die(`${entry.url} answers ${code}.`);
  say(`   200 ${entry.url}`);
}

say(`\n${tag} is out: https://github.com/${SLUG}/releases/tag/${tag}`);
say("Every copy of the app checks the feed within six hours of its next launch.");
