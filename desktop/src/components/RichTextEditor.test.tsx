// @vitest-environment happy-dom

import { act, createRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

import { makeElement } from "../defaults";
import type { LabelElement } from "../types";
import RichTextEditor, {
  collectEditorValue,
  type RichTextEditorHandle,
} from "./RichTextEditor";

const mountedRoots: Array<{ root: ReturnType<typeof createRoot>; host: HTMLElement }> = [];

afterEach(async () => {
  await act(async () => {
    for (const mounted of mountedRoots.splice(0)) {
      mounted.root.unmount();
      mounted.host.remove();
    }
  });
  document.getSelection()?.removeAllRanges();
});

function editorFixture(html: string): HTMLDivElement {
  const editor = document.createElement("div");
  editor.style.fontFamily = "Arial";
  editor.style.fontSize = "16px";
  editor.style.color = "rgb(0, 0, 0)";
  editor.innerHTML = html;
  document.body.append(editor);
  return editor;
}

describe("contenteditable text collection", () => {
  it("drops Chromium caret placeholder breaks when the editor is empty", () => {
    const editor = editorFixture("<br>");
    expect(collectEditorValue(editor, 1).text).toBe("");
    editor.remove();
  });

  it("serializes a trailing empty paragraph as exactly one newline", () => {
    const editor = editorFixture("<span>A</span><div><span><br></span></div>");
    expect(collectEditorValue(editor, 1).text).toBe("A\n");
    editor.remove();
  });

  it("keeps one boundary between adjacent contenteditable block lines", () => {
    const editor = editorFixture("<div><span>A</span></div><div><span>B</span></div>");
    expect(collectEditorValue(editor, 1).text).toBe("A\nB");
    editor.remove();
  });

  it("keeps a deliberate newline-only rich-text span", () => {
    const editor = editorFixture("<span>A</span><span><br></span><span>B</span>");
    expect(collectEditorValue(editor, 1).text).toBe("A\nB");
    editor.remove();
  });
});

describe("RichTextEditor synchronization", () => {
  it("observes a contenteditable DOM mutation even when no input event arrives", async () => {
    const element = makeElement("text");
    element.content = "AB";
    const changes: string[] = [];
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mountedRoots.push({ root, host });
    await act(async () => root.render(
      <RichTextEditor element={element} onChange={(content) => changes.push(content)} />,
    ));

    host.querySelector<HTMLElement>(".rich-text-editor span")!.textContent = "AC";
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 80));
    });

    expect(changes.at(-1)).toBe("AC");
  });

  it("does not lose an input sync during an unrelated parent render", async () => {
    const element = makeElement("text");
    element.content = "AB";
    const changes: string[] = [];
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mountedRoots.push({ root, host });
    const Harness = ({ tick }: { tick: number }) => (
      <>
        <span data-tick={tick} />
        <RichTextEditor
          element={element}
          onChange={(content) => changes.push(content)}
        />
      </>
    );
    await act(async () => root.render(<Harness tick={0} />));
    const editor = host.querySelector<HTMLElement>(".rich-text-editor")!;
    editor.querySelector("span")!.textContent = "AC";
    editor.dispatchEvent(new InputEvent("input", { bubbles: true }));
    await act(async () => root.render(<Harness tick={1} />));
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 180));
    });

    expect(changes.at(-1)).toBe("AC");
  });

  it("keeps the saved selection connected across blur and a controlled update", async () => {
    const initial = makeElement("text");
    initial.content = "AB";
    const editorHandle = createRef<RichTextEditorHandle>();

    function Harness() {
      const [element, setElement] = useState<LabelElement>(initial);
      return (
        <>
          <RichTextEditor
            ref={editorHandle}
            element={element}
            onChange={(content, richTextRTF) => setElement((current) => ({
              ...current,
              content,
              richTextRTF,
            }))}
          />
          <button id="outside">Outside</button>
        </>
      );
    }

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mountedRoots.push({ root, host });
    Object.defineProperty(document, "execCommand", {
      configurable: true,
      value: vi.fn(() => true),
    });
    await act(async () => root.render(<Harness />));

    const editor = host.querySelector<HTMLElement>(".rich-text-editor")!;
    const text = editor.querySelector("span")!.firstChild!;
    await act(async () => editor.focus());
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 1);
    document.getSelection()!.removeAllRanges();
    document.getSelection()!.addRange(range);
    document.dispatchEvent(new Event("selectionchange"));
    text.nodeValue = "AC";
    editor.dispatchEvent(new InputEvent("input", { bubbles: true }));

    await act(async () => editorHandle.current!.flush());
    await act(async () => host.querySelector<HTMLButtonElement>("#outside")!.focus());

    expect(editorHandle.current!.insertText("{{serial}}")).toBe(true);
  });

  it("flushes marked IME text for an explicit save before compositionend", async () => {
    const element = makeElement("text");
    element.content = "A";
    const editorHandle = createRef<RichTextEditorHandle>();
    const changes: string[] = [];
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mountedRoots.push({ root, host });
    await act(async () => root.render(
      <RichTextEditor
        ref={editorHandle}
        element={element}
        onChange={(content) => changes.push(content)}
      />,
    ));

    const editor = host.querySelector<HTMLElement>(".rich-text-editor")!;
    editor.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    editor.querySelector("span")!.textContent = "한";
    editorHandle.current!.flush();

    expect(changes.at(-1)).toBe("한");
  });

  it("applies an exact point size without Chromium's xxx-large command value", async () => {
    const element = makeElement("text");
    element.content = "AB";
    const editorHandle = createRef<RichTextEditorHandle>();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mountedRoots.push({ root, host });
    Object.defineProperty(document, "execCommand", {
      configurable: true,
      value: vi.fn(() => true),
    });
    await act(async () => root.render(
      <RichTextEditor ref={editorHandle} element={element} onChange={() => undefined} />,
    ));

    const editor = host.querySelector<HTMLElement>(".rich-text-editor")!;
    const text = editor.querySelector("span")!.firstChild!;
    editor.focus();
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 1);
    document.getSelection()!.removeAllRanges();
    document.getSelection()!.addRange(range);
    document.dispatchEvent(new Event("selectionchange"));

    expect(editorHandle.current!.applyAction({ kind: "fontSize", value: 18 })).toBe(true);
    expect(editor.innerHTML).toContain("font-size: 18pt");
    expect(editor.innerHTML).not.toContain("xxx-large");
  });
});
