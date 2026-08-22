import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PDFDocument } from "pdf-lib";

const executable = process.argv[2];
const screenshotPath = process.argv[3];
if (!executable) throw new Error("Usage: node scripts/packaged-smoke.mjs <executable> [screenshot.png]");

const port = 9300 + (process.pid % 500);
const userData = await mkdtemp(path.join(os.tmpdir(), "ilabel2-smoke-"));
const output = [];
const application = spawn(executable, [
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${userData}`,
  "--disable-gpu",
  "--enable-output-test-api",
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
      throw new Error(`Packaged app exited early (${application.exitCode}).\n${output.join("")}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json`);
      const targets = await response.json();
      const page = targets.find((target) => target.type === "page" && target.url.startsWith("app://renderer/"));
      if (page?.webSocketDebuggerUrl) return page;
    } catch {
      // DevTools is still starting.
    }
    await delay(250);
  }
  throw new Error(`Timed out waiting for the packaged renderer.\n${output.join("")}`);
}

const target = await pageTarget();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let nextID = 1;
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

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

try {
  await command("Page.enable");
  await evaluate("document.fonts.ready");
  const initial = await evaluate(`(async () => ({
    root: Boolean(document.querySelector('#root .app-shell')),
    catalog: document.body.innerText.includes('1,006 matches'),
    default680:
      document.querySelector('.format-summary strong')?.textContent.trim() === '680' &&
      document.querySelector('.format-summary')?.innerText.includes('14×20 · 12 × 12 mm') &&
      Boolean(document.querySelector('.object-list .empty-state')),
    api: typeof window.iLabelDesktop?.getOSInfo === 'function',
    os: (await window.iLabelDesktop.getOSInfo()).status
  }))()`);
  assert(initial.root, "The React root did not render.");
  assert(initial.catalog, "The official 1,006-format catalog did not load.");
  assert(initial.default680, "A new packaged app did not start as a blank official 680 document.");
  assert(initial.api && initial.os === "success", "The preload API is unavailable.");

  const localFont = await evaluate(`(async () => {
    if (typeof window.queryLocalFonts !== 'function') return { available: false };
    const fonts = await window.queryLocalFonts();
    if (!fonts.length) return { available: true, count: 0 };
    const font = fonts.find((candidate) => candidate.postscriptName?.trim());
    if (!font) return { available: true, count: fonts.length, loaded: false };
    const blob = await font.blob();
    const dataURL = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
    const face = new FontFace('iLabel2 Smoke Font', await blob.arrayBuffer());
    await face.load();
    document.fonts.add(face);
    return {
      available: true,
      count: fonts.length,
      loaded: document.fonts.check('12px "iLabel2 Smoke Font"'),
      postscriptName: font.postscriptName,
      dataURL,
    };
  })()`);
  assert(localFont.available && localFont.count > 0 && localFont.loaded, "Local font access or FontFace loading failed.");

  for (const [sizeIndex, [widthMM, heightMM]] of [[210, 297], [100, 50], [30, 20.283]].entries()) {
    const embeddedFontStyle = sizeIndex === 0
      ? `<style>@font-face{font-family:"iLabel2 Smoke Embedded";src:url(${localFont.dataURL})}body{font-family:"iLabel2 Smoke Embedded"}</style>`
      : "";
    const request = {
      html: `<!doctype html><html><head>${embeddedFontStyle}</head><body><section style="width:${widthMM}mm;height:${heightMM}mm">calibration Hamburgefons</section></body></html>`,
      pageWidthMM: widthMM,
      pageHeightMM: heightMM,
      jobTitle: "iLabel2 output smoke",
    };
    const pdfResult = await evaluate(`window.iLabelDesktop.renderPDFForTest(${JSON.stringify(request)})`);
    assert(pdfResult.status === "success", `PDF test API failed: ${JSON.stringify(pdfResult)}`);
    const pdfBytes = Buffer.from(pdfResult.data.base64, "base64");
    const pdf = await PDFDocument.load(pdfBytes);
    assert(pdf.getPageCount() === 1, "PDF output has an unexpected page count.");
    const size = pdf.getPage(0).getSize();
    const actualWidthMM = size.width * 25.4 / 72;
    const actualHeightMM = size.height * 25.4 / 72;
    assert(Math.abs(actualWidthMM - widthMM) <= 0.1, `PDF width mismatch: ${actualWidthMM} vs ${widthMM}`);
    assert(Math.abs(actualHeightMM - heightMM) <= 0.1, `PDF height mismatch: ${actualHeightMM} vs ${heightMM}`);
    if (sizeIndex === 0) {
      assert(
        pdfBytes.toString("latin1").includes(localFont.postscriptName),
        `Embedded font ${localFont.postscriptName} is absent from the PDF inventory.`,
      );
    }
  }

  await evaluate(`[...document.querySelectorAll('button')].find((button) => button.textContent.trim() === 'Text').click()`);
  await delay(250);
  await evaluate(`(() => {
    const editor = document.querySelector('.rich-text-editor');
    editor.focus();
    const range = document.createRange();
    range.selectNodeContents(editor);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  })()`);
  await evaluate(`document.execCommand('insertText', false, 'A{{serial}}B')`);
  await delay(350);
  const enteredState = await evaluate(`(() => {
    const editors = [...document.querySelectorAll('.rich-text-editor')];
    return {
      editor: editors[0]?.innerText,
      preview: document.querySelector('.label-board .svg-surface [data-element-type="text"] text')?.textContent,
      editors: editors.map((editor) => {
        const propsKey = Object.keys(editor).find((key) => key.startsWith('__reactProps'));
        return {
          label: editor.getAttribute('aria-label'),
          text: editor.innerText,
          model: propsKey ? editor[propsKey]?.element?.content : undefined,
          active: editor === document.activeElement
        };
      })
    };
  })()`);
  assert(
    enteredState.editor === "A{{serial}}B" && enteredState.preview === "A(1)B",
    `Rich text input did not settle: ${JSON.stringify(enteredState)}`,
  );
  const boldPoint = await evaluate(`(() => {
    const editor = document.querySelector('.rich-text-editor');
    const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
    let text;
    while (!text) {
      const candidate = walker.nextNode();
      if (!candidate) throw new Error('No editable text node found.');
      if (candidate.nodeValue.length >= 11) text = candidate;
    }
    const range = document.createRange();
    range.setStart(text, 1);
    range.setEnd(text, 11);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
    const button = [...document.querySelectorAll('.style-buttons button')]
      .find((candidate) => candidate.textContent.trim() === 'Bold');
    button.scrollIntoView({ block: 'center', inline: 'nearest' });
    const bounds = button.getBoundingClientRect();
    if (bounds.left < 0 || bounds.top < 0 || bounds.right > innerWidth || bounds.bottom > innerHeight) {
      throw new Error('Bold button is outside the packaged viewport.');
    }
    return { x: bounds.left + bounds.width / 2, y: bounds.top + bounds.height / 2 };
  })()`);
  await command("Input.dispatchMouseEvent", { type: "mousePressed", ...boldPoint, button: "left", clickCount: 1 });
  await command("Input.dispatchMouseEvent", { type: "mouseReleased", ...boldPoint, button: "left", clickCount: 1 });
  await delay(350);
  const boldContent = await evaluate("document.querySelector('.rich-text-editor').innerText");
  assert(boldContent === "A{{serial}}B", `Rich text changed after toolbar focus: ${JSON.stringify(boldContent)}`);
  await evaluate(`(() => {
    const editor = document.querySelector('.rich-text-editor');
    const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
    let firstText;
    while (!firstText) {
      const candidate = walker.nextNode();
      if (!candidate) throw new Error('No editable text node found.');
      if (candidate.nodeValue.length > 0) firstText = candidate;
    }
    const range = document.createRange();
    range.setStart(firstText, 0);
    range.setEnd(firstText, 1);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
    const sizeInput = [...document.querySelectorAll('.field-label')]
      .find((label) => label.querySelector('span')?.textContent.trim() === 'Size · pt')
      .querySelector('input');
    sizeInput.scrollIntoView({ block: 'center', inline: 'nearest' });
    sizeInput.focus();
    sizeInput.select();
  })()`);
  await command("Input.insertText", { text: "18" });
  await evaluate(`document.activeElement.blur()`);
  await delay(350);
  const richText = await evaluate(`(() => {
    const selected = [...document.querySelectorAll('.label-board .svg-surface [data-element-type="text"] text tspan tspan')];
    const boldTexts = selected
      .filter((node) => node.getAttribute('font-weight') === '700')
      .map((node) => node.textContent);
    const sized = selected.find((node) => node.textContent === 'A');
    const lines = [...document.querySelectorAll('.label-board .svg-surface [data-element-type="text"] [data-available-width]')];
    const lineOverflows = lines
      .filter((line) => line.getComputedTextLength() > Number(line.dataset.availableWidth) + 0.05).length;
    const boxes = lines.map((line) => line.getBBox());
    const outsideCircle = boxes.filter((box) => [
      [box.x, box.y],
      [box.x + box.width, box.y],
      [box.x, box.y + box.height],
      [box.x + box.width, box.y + box.height],
    ].some(([x, y]) => ((x - 6) / 5) ** 2 + ((y - 6) / 5.4) ** 2 > 1.02)).length;
    const bounds = boxes.length ? {
      left: Math.min(...boxes.map((box) => box.x)),
      right: Math.max(...boxes.map((box) => box.x + box.width)),
      top: Math.min(...boxes.map((box) => box.y)),
      bottom: Math.max(...boxes.map((box) => box.y + box.height)),
    } : { left: 6, right: 6, top: 6, bottom: 6 };
    return {
      content: document.querySelector('.rich-text-editor').innerText,
      boldTexts,
      leadingABold: sized?.getAttribute('font-weight') === '700',
      sizedText: sized?.textContent,
      sizedPoints: Number(sized?.getAttribute('font-size')) * 72 / 25.4,
      lineOverflows,
      outsideCircle,
      centerDelta: Math.max(
        Math.abs((bounds.left + bounds.right) / 2 - 6),
        Math.abs((bounds.top + bounds.bottom) / 2 - 6),
      ),
    };
  })()`);
  assert(
    richText.content === "A{{serial}}B",
    `Rich text content changed unexpectedly: ${JSON.stringify(richText)}`,
  );
  assert(
    richText.boldTexts.some((text) => text?.includes("(1)")) && !richText.leadingABold,
    `Selection-level bold did not survive RTF/token rendering: ${JSON.stringify(richText)}`,
  );
  assert(
    richText.sizedText === "A" && Math.abs(richText.sizedPoints - 18) <= 0.1,
    `Selection-level point size was not applied exactly: ${JSON.stringify(richText)}`,
  );
  assert(richText.lineOverflows === 0, "A rendered text line exceeds its measured print width.");
  assert(richText.outsideCircle === 0, "Circular text ink escaped the inset ellipse.");
  assert(richText.centerDelta <= 0.25, `Circular text is off-center by ${richText.centerDelta}mm.`);

  // Restore the stress-sized run before capturing the human-review screenshot.
  await evaluate(`(() => {
    const editor = document.querySelector('.rich-text-editor');
    const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
    let firstText;
    while (!firstText) {
      const candidate = walker.nextNode();
      if (!candidate) throw new Error('No editable text node found.');
      if (candidate.nodeValue.length > 0) firstText = candidate;
    }
    const range = document.createRange();
    range.setStart(firstText, 0);
    range.setEnd(firstText, 1);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
    const sizeInput = [...document.querySelectorAll('.field-label')]
      .find((label) => label.querySelector('span')?.textContent.trim() === 'Size · pt')
      .querySelector('input');
    sizeInput.scrollIntoView({ block: 'center', inline: 'nearest' });
    sizeInput.focus();
    sizeInput.select();
  })()`);
  await command("Input.insertText", { text: "3.5" });
  await evaluate(`document.activeElement.blur()`);
  await delay(350);

  const tokenPoint = await evaluate(`(() => {
    const editor = document.querySelector('.rich-text-editor');
    const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
    let firstText;
    while (!firstText) {
      const candidate = walker.nextNode();
      if (!candidate) throw new Error('No editable text node found.');
      if (candidate.nodeValue.length > 0) firstText = candidate;
    }
    const range = document.createRange();
    range.setStart(firstText, 1);
    range.collapse(true);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new Event('selectionchange'));
    const token = [...document.querySelectorAll('.token-cloud button')]
      .find((button) => button.textContent.trim() === '{{time}}');
    token.scrollIntoView({ block: 'center', inline: 'nearest' });
    const bounds = token.getBoundingClientRect();
    if (bounds.left < 0 || bounds.top < 0 || bounds.right > innerWidth || bounds.bottom > innerHeight) {
      throw new Error('Token button is outside the packaged viewport.');
    }
    return { x: bounds.left + bounds.width / 2, y: bounds.top + bounds.height / 2 };
  })()`);
  await command("Input.dispatchMouseEvent", { type: "mousePressed", ...tokenPoint, button: "left", clickCount: 1 });
  await command("Input.dispatchMouseEvent", { type: "mouseReleased", ...tokenPoint, button: "left", clickCount: 1 });
  await delay(350);
  const caretTokenContent = await evaluate("document.querySelector('.rich-text-editor').innerText");
  assert(caretTokenContent === "A{{time}}{{serial}}B", "A toolbar token was not inserted at the saved caret.");

  await evaluate(`(() => {
    const slots = [...document.querySelectorAll('.page-slot-hit')];
    slots[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: 0, buttons: 1 }));
    slots[15].dispatchEvent(new PointerEvent('pointerover', { bubbles: true, buttons: 1 }));
    slots[15].dispatchEvent(new PointerEvent('pointerup', { bubbles: true, button: 0, buttons: 0 }));
  })()`);
  await delay(250);
  const selectedArea = await evaluate("document.querySelectorAll('.page-slot-hit.selected').length");
  assert(selectedArea === 4, `Rectangular slot drag selected ${selectedArea} slots instead of 4.`);

  await evaluate(`[...document.querySelectorAll('button')].find((button) => button.textContent.trim() === 'Capture current setup').click()`);
  await delay(350);
  const queue = await evaluate(`({
    captures: document.querySelectorAll('.queue-row').length,
    nextDisabled: [...document.querySelectorAll('button')].find((button) => button.textContent.trim() === 'Next').disabled
  })`);
  assert(queue.captures === 1 && !queue.nextDisabled, "Capture staging page was not created.");

  if (screenshotPath) {
    const screenshot = await command("Page.captureScreenshot", { format: "png", fromSurface: true });
    await writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));
  }
  process.stdout.write(`Packaged smoke passed: ${JSON.stringify({ localFonts: localFont.count, selectedArea, caretTokenContent, ...richText, ...queue })}\n`);
} finally {
  socket.close();
  application.kill();
  await Promise.race([
    new Promise((resolve) => application.once("exit", resolve)),
    delay(3_000),
  ]);
  await rm(userData, { recursive: true, force: true });
}
