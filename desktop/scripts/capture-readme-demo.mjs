import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(scriptDirectory, "..");
const repositoryRoot = path.resolve(desktopRoot, "..");
const outputPath = path.resolve(
  process.argv[2] ?? path.join(repositoryRoot, "docs/assets/capture-queue-workflow.gif"),
);
const require = createRequire(import.meta.url);
const electronExecutable = require("electron");
const port = 9800 + (process.pid % 150);
const userData = await mkdtemp(path.join(os.tmpdir(), "ilabel2-readme-demo-"));
const framesDirectory = await mkdtemp(path.join(os.tmpdir(), "ilabel2-readme-frames-"));
const output = [];
const application = spawn(electronExecutable, [
  desktopRoot,
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${userData}`,
  "--disable-gpu",
  "--force-device-scale-factor=1",
], {
  shell: false,
  windowsHide: true,
  stdio: ["ignore", "pipe", "pipe"],
});
application.stdout.on("data", (chunk) => output.push(String(chunk)));
application.stderr.on("data", (chunk) => output.push(String(chunk)));

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function pageTarget() {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (application.exitCode !== null) {
      throw new Error(`Electron exited early (${application.exitCode}).\n${output.join("")}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json`);
      const targets = await response.json();
      const page = targets.find((target) => target.type === "page" && target.url.startsWith("app://renderer/"));
      if (page?.webSocketDebuggerUrl) return page;
    } catch {
      // DevTools is still starting.
    }
    await delay(200);
  }
  throw new Error(`Timed out waiting for Electron.\n${output.join("")}`);
}

const target = await pageTarget();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let nextID = 1;
let frameIndex = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(String(event.data));
  const resolve = pending.get(message.id);
  if (resolve) {
    pending.delete(message.id);
    resolve(message);
  }
});

function command(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = nextID++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP command timed out: ${method}`));
    }, 30_000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await command("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.exception?.description ?? "Renderer evaluation failed");
  }
  return result.result.value;
}

await command("Page.enable");
await evaluate("document.fonts.ready");
const viewport = await evaluate("({ width: innerWidth, height: innerHeight })");
const clip = {
  x: Math.min(280, Math.max(0, viewport.width - 900)),
  y: 0,
  width: viewport.width - Math.min(280, Math.max(0, viewport.width - 900)),
  height: Math.min(820, viewport.height),
  scale: 1,
};

async function captureFrame() {
  let screenshot;
  try {
    screenshot = await command("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
      clip,
    });
  } catch (error) {
    throw new Error(`README capture failed at frame ${frameIndex + 1}`, { cause: error });
  }
  frameIndex += 1;
  const filename = `frame-${String(frameIndex).padStart(4, "0")}.png`;
  await writeFile(path.join(framesDirectory, filename), Buffer.from(screenshot.data, "base64"));
}

async function hold(frames) {
  for (let index = 0; index < frames; index += 1) {
    await captureFrame();
    await delay(25);
  }
}

async function caption(text) {
  await evaluate(`document.querySelector('#ilabel-demo-caption').textContent = ${JSON.stringify(text)}`);
}

async function moveCursor(selector) {
  const found = await evaluate(`(() => {
    const target = document.querySelector(${JSON.stringify(selector)});
    if (!target) return false;
    target.scrollIntoView({ block: 'center', inline: 'nearest' });
    const bounds = target.getBoundingClientRect();
    const cursor = document.querySelector('#ilabel-demo-cursor');
    cursor.style.left = (bounds.left + bounds.width / 2) + 'px';
    cursor.style.top = (bounds.top + bounds.height / 2) + 'px';
    return true;
  })()`);
  if (!found) throw new Error(`Demo target is missing: ${selector}`);
  await hold(4);
}

async function pulseCursor() {
  await evaluate(`document.querySelector('#ilabel-demo-cursor').classList.add('pressed')`);
  await hold(2);
  await evaluate(`document.querySelector('#ilabel-demo-cursor').classList.remove('pressed')`);
}

async function refreshButtonTargets() {
  await evaluate(`(() => {
    for (const button of document.querySelectorAll('button')) {
      const label = button.textContent.trim();
      if (['Text', 'Page', 'Capture Current Setup', 'Print Captures'].includes(label)) {
        button.dataset.demoLabel = label;
      }
    }
  })()`);
}

async function clickButton(label) {
  await refreshButtonTargets();
  const selector = `[data-demo-label=${JSON.stringify(label)}]`;
  await moveCursor(selector);
  await pulseCursor();
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  await hold(4);
}

async function setNumber(label, value) {
  const selector = `[data-demo-number=${JSON.stringify(label)}]`;
  await moveCursor(selector);
  await pulseCursor();
  await evaluate(`(() => {
    const input = document.querySelector(${JSON.stringify(selector)});
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, ${JSON.stringify(String(value))});
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    input.blur();
  })()`);
  await hold(4);
}

async function typeLabelContent(value) {
  const selector = '[contenteditable="true"][aria-label="Text content"]';
  await moveCursor(selector);
  await pulseCursor();
  await evaluate(`(() => {
    const editor = document.querySelector(${JSON.stringify(selector)});
    editor.focus();
    const range = document.createRange();
    range.selectNodeContents(editor);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.execCommand('delete');
  })()`);
  await delay(80);
  for (const character of value) {
    await command("Input.insertText", { text: character });
    await hold(1);
  }
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).blur()`);
  let entered;
  const deadline = Date.now() + 3_000;
  do {
    entered = await evaluate(`(() => ({
      editor: document.querySelector(${JSON.stringify(selector)})?.innerText,
      preview: document.querySelector('.label-board .svg-surface [data-element-type="text"] text')?.textContent
    }))()`);
    if (entered.editor === value && entered.preview?.includes("Sample (1)")) break;
    await delay(80);
  } while (Date.now() < deadline);
  if (entered.editor !== value || !entered.preview?.includes("Sample (1)")) {
    throw new Error(`Label entry did not reach the editor and preview: ${JSON.stringify(entered)}`);
  }
  await hold(5);
}

async function selectSlot(slotIndex) {
  const selector = `.page-slot-hit[data-slot-index="${slotIndex}"]`;
  await moveCursor(selector);
  await pulseCursor();
  await evaluate(`(() => {
    const slot = document.querySelector(${JSON.stringify(selector)});
    slot.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 0, buttons: 1 }));
    slot.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, button: 0, buttons: 0 }));
  })()`);
  await hold(5);
}

try {
  await evaluate(`(() => {
    const style = document.createElement('style');
    style.textContent = \`
      #ilabel-demo-caption {
        position: fixed;
        z-index: 2147483646;
        left: 50%;
        bottom: max(18px, calc(100vh - 800px));
        transform: translateX(-50%);
        max-width: min(720px, calc(100vw - 40px));
        padding: 9px 15px;
        border: 1px solid rgb(255 255 255 / 35%);
        border-radius: 999px;
        color: white;
        background: rgb(25 28 34 / 88%);
        box-shadow: 0 8px 24px rgb(0 0 0 / 22%);
        font: 650 13px/1.25 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        letter-spacing: .01em;
        text-align: center;
        pointer-events: none;
      }
      #ilabel-demo-cursor {
        position: fixed;
        z-index: 2147483647;
        width: 18px;
        height: 18px;
        margin: -9px 0 0 -9px;
        border: 2px solid white;
        border-radius: 50%;
        background: #2878e2;
        box-shadow: 0 2px 8px rgb(0 0 0 / 42%);
        transition: left .28s ease, top .28s ease, transform .12s ease;
        pointer-events: none;
      }
      #ilabel-demo-cursor.pressed { transform: scale(.68); }
    \`;
    document.head.append(style);
    const caption = document.createElement('div');
    caption.id = 'ilabel-demo-caption';
    document.body.append(caption);
    const cursor = document.createElement('div');
    cursor.id = 'ilabel-demo-cursor';
    cursor.style.left = '50%';
    cursor.style.top = '50%';
    document.body.append(cursor);

    for (const button of document.querySelectorAll('button')) {
      const label = button.textContent.trim();
      if (['Text', 'Page', 'Capture Current Setup', 'Print Captures'].includes(label)) {
        button.dataset.demoLabel = label;
      }
    }
    for (const field of document.querySelectorAll('.field-label')) {
      const label = field.querySelector(':scope > span')?.textContent.trim();
      const input = field.querySelector(':scope > input[type="number"]');
      if (input && ['End', 'Repeat'].includes(label)) input.dataset.demoNumber = label;
    }
  })()`);

  await caption("1 · Add a Text object to the label");
  await hold(6);
  await clickButton("Text");
  await hold(4);

  await caption("2 · Type the label content and serial token");
  await typeLabelContent("Sample {{serial}}");

  await caption("3 · Switch to the full Page Preview");
  await clickButton("Page");
  await hold(4);
  await evaluate(`(() => {
    for (const button of document.querySelectorAll('button')) {
      const label = button.textContent.trim();
      if (['Capture Current Setup', 'Print Captures'].includes(label)) button.dataset.demoLabel = label;
    }
    for (const field of document.querySelectorAll('.field-label')) {
      const label = field.querySelector(':scope > span')?.textContent.trim();
      const input = field.querySelector(':scope > input[type="number"]');
      if (input && ['End', 'Repeat'].includes(label)) input.dataset.demoNumber = label;
    }
  })()`);

  await caption("4 · Set End 4 × Repeat 2 = 8 labels");
  await hold(6);
  await setNumber("End", 4);
  await setNumber("Repeat", 2);
  await hold(4);

  await caption("5 · Choose the first label position");
  await selectSlot(0);
  await hold(4);

  await caption("6 · Capture Current Setup locks those 8 labels");
  await clickButton("Capture Current Setup");
  await hold(6);

  await caption("7 · Click another empty position for the next capture");
  await selectSlot(8);
  await hold(4);

  await caption("8 · Change the next run to 3 labels");
  await setNumber("End", 3);
  await setNumber("Repeat", 1);
  await hold(4);

  await caption("9 · Capture again — both setups stay locked in the queue");
  await clickButton("Capture Current Setup");
  await hold(8);

  await caption("Ready · Print Captures sends the complete queue");
  await refreshButtonTargets();
  await moveCursor('[data-demo-label="Print Captures"]');
  await hold(8);

  if (frameIndex > 220) {
    throw new Error(`README demo is too long: ${frameIndex} frames`);
  }

  const ffmpeg = spawnSync("ffmpeg", [
    "-y",
    "-loglevel", "error",
    "-framerate", "10",
    "-i", path.join(framesDirectory, "frame-%04d.png"),
    "-vf", "fps=10,scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3",
    "-loop", "0",
    outputPath,
  ], { encoding: "utf8" });
  if (ffmpeg.status !== 0) {
    throw new Error(`ffmpeg failed: ${ffmpeg.stderr || ffmpeg.stdout}`);
  }
  process.stdout.write(`README demo written to ${outputPath} (${frameIndex} frames).\n`);
} finally {
  socket.close();
  application.kill();
  await Promise.race([
    new Promise((resolve) => application.once("exit", resolve)),
    delay(3_000),
  ]);
  await rm(userData, { recursive: true, force: true });
  await rm(framesDirectory, { recursive: true, force: true });
}
