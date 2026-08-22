import {
  forwardRef,
  type CSSProperties,
  type ClipboardEvent,
  type CompositionEvent,
  type FormEvent,
  type PointerEvent as ReactPointerEvent,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
} from "react";

import type { LabelElement, RGBAColor } from "../types";
import { elementRichText } from "../core/richText";
import { serializeBase64RTF, type RTFStyleRun } from "../core/rtf";

export type RichTextAction =
  | { kind: "bold" }
  | { kind: "italic" }
  | { kind: "underline" }
  | { kind: "fontFamily"; value: string }
  | { kind: "fontSize"; value: number }
  | { kind: "foreground"; value: RGBAColor };

export interface RichTextEditorHandle {
  applyAction(action: RichTextAction): boolean;
  insertText(value: string): boolean;
  focus(): void;
  flush(): void;
}

interface RichTextEditorProps {
  element: LabelElement;
  className?: string;
  style?: CSSProperties & Partial<Record<`--${string}`, string | number>>;
  ariaLabel?: string;
  placeholder?: string;
  /** CSS/editor point size divided by stored project point size. */
  fontScale?: number;
  circularFlow?: boolean;
  onChange: (text: string, richTextRTF: string | undefined) => void;
  onActive?: (handle: RichTextEditorHandle) => void;
  onEscape?: () => void;
  onPointerDown?: (event: ReactPointerEvent<HTMLDivElement>) => void;
}

function colorCSS(color: RGBAColor | undefined): string | undefined {
  if (!color) return undefined;
  return `rgba(${Math.round(color.red * 255)}, ${Math.round(color.green * 255)}, ${Math.round(color.blue * 255)}, ${color.alpha})`;
}

function colorFromCSS(value: string): RGBAColor | undefined {
  const match = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)/i.exec(value);
  if (!match) return undefined;
  return {
    red: Math.min(1, Number(match[1]) / 255),
    green: Math.min(1, Number(match[2]) / 255),
    blue: Math.min(1, Number(match[3]) / 255),
    alpha: Math.min(1, Number(match[4] ?? 1)),
  };
}

function fontFamilyFromCSS(value: string): string {
  const first = value.split(",", 1)[0]?.trim() || "Arial";
  return first.replace(/^(?:"|')|(?:"|')$/g, "");
}

function stylesEqual(left: RTFStyleRun, right: RTFStyleRun): boolean {
  return JSON.stringify({
    fontName: left.fontName,
    fontSize: left.fontSize,
    bold: left.bold,
    italic: left.italic,
    underline: left.underline,
    foreground: left.foreground,
  }) === JSON.stringify({
    fontName: right.fontName,
    fontSize: right.fontSize,
    bold: right.bold,
    italic: right.italic,
    underline: right.underline,
    foreground: right.foreground,
  });
}

function appendRun(
  runs: RTFStyleRun[],
  start: number,
  length: number,
  style: Omit<RTFStyleRun, "start" | "length">,
): void {
  if (length <= 0) return;
  const run: RTFStyleRun = { ...style, start, length };
  const previous = runs.at(-1);
  if (
    previous &&
    previous.start + previous.length === start &&
    stylesEqual(previous, run)
  ) {
    previous.length += length;
  } else {
    runs.push(run);
  }
}

function computedRun(
  element: HTMLElement,
  fontScale: number,
): Omit<RTFStyleRun, "start" | "length"> {
  const computed = getComputedStyle(element);
  const numericWeight = Number.parseInt(computed.fontWeight, 10);
  return {
    fontName: fontFamilyFromCSS(computed.fontFamily),
    fontSize: Math.max(
      0.5,
      (Number.parseFloat(computed.fontSize) * 0.75) / Math.max(0.001, fontScale),
    ),
    bold: Number.isFinite(numericWeight)
      ? numericWeight >= 600
      : /bold/i.test(computed.fontWeight),
    italic: /italic|oblique/i.test(computed.fontStyle),
    underline: computed.textDecorationLine.includes("underline"),
    foreground: colorFromCSS(computed.color),
  };
}

function editableChildren(container: HTMLElement): Node[] {
  return [...container.childNodes].filter((node) =>
    !(node instanceof HTMLElement && node.dataset.richTextGuard === "true") &&
    !(node.nodeType === Node.TEXT_NODE && (node.nodeValue ?? "").length === 0));
}

function isBlockElement(node: Node): node is HTMLElement {
  return node instanceof HTMLElement && (node.tagName === "DIV" || node.tagName === "P");
}

function isCaretPlaceholderBreak(node: HTMLElement, editor: HTMLElement): boolean {
  const parent = node.parentElement;
  if (!parent) return false;
  if (parent === editor) return editableChildren(editor).length === 1;
  const block = parent.closest("div, p");
  return Boolean(
    block &&
    block !== editor &&
    editor.contains(block) &&
    block.textContent === "" &&
    block.querySelectorAll("br").length === 1,
  );
}

export function collectEditorValue(
  editor: HTMLElement,
  fontScale: number,
): { text: string; runs: RTFStyleRun[] } {
  let text = "";
  const runs: RTFStyleRun[] = [];

  const append = (value: string, styleElement: HTMLElement): void => {
    if (!value) return;
    const start = text.length;
    text += value;
    appendRun(runs, start, value.length, computedRun(styleElement, fontScale));
  };

  const visit = (node: Node, parentStyle: HTMLElement): void => {
    if (node.nodeType === Node.TEXT_NODE) {
      append(node.nodeValue ?? "", parentStyle);
      return;
    }
    if (!(node instanceof HTMLElement)) return;
    if (node.dataset.richTextGuard === "true") return;
    if (node.tagName === "BR") {
      // Chromium keeps a sole <br> as a caret placeholder in an empty editor
      // or empty paragraph. The paragraph boundary already carries the real
      // newline, so serializing this marker would create phantom lines.
      if (isCaretPlaceholderBreak(node, editor)) return;
      append("\n", parentStyle);
      return;
    }
    visitContainer(node, node);
  };

  const visitContainer = (container: HTMLElement, parentStyle: HTMLElement): void => {
    let previousWasBlock = false;
    let hasPrevious = false;
    for (const child of editableChildren(container)) {
      const block = isBlockElement(child);
      if (hasPrevious && (block || previousWasBlock)) {
        append("\n", block ? child : parentStyle);
      }
      visit(child, parentStyle);
      hasPrevious = true;
      previousWasBlock = block;
    }
  };

  visitContainer(editor, editor);
  return { text, runs };
}

function populateEditor(
  editor: HTMLElement,
  element: LabelElement,
  fontScale: number,
  circularFlow: boolean,
): void {
  const rich = elementRichText(element);
  editor.replaceChildren();
  if (circularFlow) {
    const guard = document.createElement("i");
    guard.className = "circle-flow-guard";
    guard.contentEditable = "false";
    guard.dataset.richTextGuard = "true";
    editor.append(guard);
  }
  for (const run of rich.runs) {
    const span = document.createElement("span");
    span.style.fontFamily = run.fontName || element.fontName;
    span.style.fontSize = `${(run.fontSize ?? element.fontSize) * fontScale}pt`;
    span.style.fontWeight = run.bold ? "700" : "400";
    span.style.fontStyle = run.italic ? "italic" : "normal";
    span.style.textDecoration = run.underline ? "underline" : "none";
    span.style.color = colorCSS(run.foreground ?? element.foreground) ?? "black";
    const value = rich.text.slice(run.start, run.start + run.length);
    const pieces = value.split("\n");
    pieces.forEach((piece, index) => {
      if (index > 0) span.append(document.createElement("br"));
      if (piece) span.append(document.createTextNode(piece));
    });
    editor.append(span);
  }
}

function rescaleEditorFontSizes(
  editor: HTMLElement,
  previousScale: number,
  nextScale: number,
): void {
  const ratio = nextScale / Math.max(0.001, previousScale);
  if (!Number.isFinite(ratio) || Math.abs(ratio - 1) < 0.000_001) return;
  for (const node of editor.querySelectorAll<HTMLElement>("[style]")) {
    const match = /^([\d.]+)(pt|px)$/i.exec(node.style.fontSize.trim());
    if (!match) continue;
    const size = Number.parseFloat(match[1]);
    if (!Number.isFinite(size)) continue;
    node.style.fontSize = `${Math.max(0.01, size * ratio)}${match[2].toLowerCase()}`;
  }
}

function applyFontSizeToRange(
  range: Range,
  selection: Selection,
  sizePoints: number,
  fontScale: number,
): Range | undefined {
  try {
    const wrapper = document.createElement("span");
    const cssSize = `${Math.max(0.5, sizePoints) * fontScale}pt`;
    wrapper.style.fontSize = cssSize;
    wrapper.append(range.extractContents());
    for (const child of wrapper.querySelectorAll<HTMLElement>("*")) {
      if (child.style.fontSize || child.tagName === "FONT") {
        child.style.fontSize = cssSize;
        child.removeAttribute("size");
      }
    }
    range.insertNode(wrapper);
    const styledRange = document.createRange();
    styledRange.selectNodeContents(wrapper);
    selection.removeAllRanges();
    selection.addRange(styledRange);
    return styledRange;
  } catch {
    return undefined;
  }
}

function rangeBelongsToEditor(range: Range | undefined, editor: HTMLElement): range is Range {
  return Boolean(
    range &&
    editor.isConnected &&
    editor.contains(range.commonAncestorContainer),
  );
}

const RichTextEditor = forwardRef<RichTextEditorHandle, RichTextEditorProps>(
  function RichTextEditor(
    {
      element,
      className = "rich-text-editor",
      style,
      ariaLabel = "Rich text content",
      placeholder = "Type label text",
      fontScale = 1,
      circularFlow = false,
      onChange,
      onActive,
      onEscape,
      onPointerDown,
    },
    forwardedRef,
  ) {
    const editorRef = useRef<HTMLDivElement>(null);
    const selectedRange = useRef<Range | undefined>(undefined);
    const composing = useRef(false);
    const syncTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
    const appliedSignature = useRef("");
    const appliedFontScale = useRef(fontScale);
    const appliedCircularFlow = useRef(circularFlow);
    const lastSynchronizedMarkup = useRef("");
    const syncRef = useRef<(includeComposition?: boolean) => void>(() => undefined);

    const rememberSelection = (): void => {
      const editor = editorRef.current;
      const selection = document.getSelection();
      if (!editor || !selection || selection.rangeCount === 0) return;
      const range = selection.getRangeAt(0);
      if (editor.contains(range.commonAncestorContainer)) {
        selectedRange.current = range.cloneRange();
      }
    };

    const sync = (includeComposition = false): void => {
      if (syncTimer.current) clearTimeout(syncTimer.current);
      syncTimer.current = undefined;
      const editor = editorRef.current;
      if (!editor || (composing.current && !includeComposition)) return;
      const value = collectEditorValue(editor, fontScale);
      const rtf = value.text.length > 0
        ? serializeBase64RTF(value.text, value.runs)
        : undefined;
      // Record this controlled value before the parent update lands. A toolbar
      // click blurs the editor; rebuilding here would disconnect the saved
      // Range before the toolbar action can restore and format it.
      appliedSignature.current = `${element.id}\u0000${value.text}\u0000${rtf ?? ""}`;
      lastSynchronizedMarkup.current = editor.innerHTML;
      onChange(value.text, rtf);
    };
    syncRef.current = sync;

    const scheduleSync = (): void => {
      if (syncTimer.current) clearTimeout(syncTimer.current);
      syncTimer.current = setTimeout(() => syncRef.current(), 45);
    };

    const restoreSelection = (): Range | undefined => {
      const editor = editorRef.current;
      const range = selectedRange.current;
      if (!editor || !rangeBelongsToEditor(range, editor)) return undefined;
      const selection = document.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      return range;
    };

    const handle: RichTextEditorHandle = {
      applyAction(action) {
        const editor = editorRef.current;
        if (!editor) return false;
        let range = restoreSelection();
        if (!range) return false;
        const selection = document.getSelection();
        if (!selection) return false;
        if (range.collapsed) {
          if (
            action.kind === "fontFamily" ||
            action.kind === "fontSize" ||
            action.kind === "foreground"
          ) {
            return false;
          }
          range = document.createRange();
          range.selectNodeContents(editor);
          selection.removeAllRanges();
          selection.addRange(range);
        }
        editor.focus({ preventScroll: true });
        document.execCommand("styleWithCSS", false, "true");
        switch (action.kind) {
          case "bold":
          case "italic":
          case "underline":
            document.execCommand(action.kind, false);
            break;
          case "fontFamily":
            document.execCommand("fontName", false, action.value);
            break;
          case "foreground":
            document.execCommand("foreColor", false, colorCSS(action.value) ?? "#000000");
            break;
          case "fontSize": {
            const styledRange = applyFontSizeToRange(
              range,
              selection,
              action.value,
              fontScale,
            );
            if (!styledRange) return false;
            range = styledRange;
            break;
          }
        }
        rememberSelection();
        sync();
        return true;
      },
      insertText(value) {
        const editor = editorRef.current;
        if (!editor || !restoreSelection()) return false;
        editor.focus({ preventScroll: true });
        document.execCommand("insertText", false, value);
        rememberSelection();
        sync();
        return true;
      },
      focus() {
        editorRef.current?.focus({ preventScroll: true });
      },
      // An explicit save must include the marked IME text already present in
      // the contenteditable DOM, even before compositionend fires.
      flush() {
        sync(true);
      },
    };

    useImperativeHandle(forwardedRef, () => handle);

    useLayoutEffect(() => {
      const editor = editorRef.current;
      if (!editor) return;
      // Scaling is a presentation concern. Update the existing nodes in place
      // for both active and inactive editors so RTF point sizes stay stable.
      rescaleEditorFontSizes(editor, appliedFontScale.current, fontScale);
      appliedFontScale.current = fontScale;
      if (document.activeElement === editor || composing.current) {
        return;
      }
      const signature = `${element.id}\u0000${element.content}\u0000${element.richTextRTF ?? ""}`;
      if (
        signature === appliedSignature.current &&
        circularFlow === appliedCircularFlow.current
      ) return;
      populateEditor(editor, element, fontScale, circularFlow);
      appliedSignature.current = signature;
      appliedFontScale.current = fontScale;
      appliedCircularFlow.current = circularFlow;
      lastSynchronizedMarkup.current = editor.innerHTML;
    }, [circularFlow, element, fontScale]);

    useLayoutEffect(() => {
      const selectionChanged = () => rememberSelection();
      const observer = new MutationObserver(() => {
        const editor = editorRef.current;
        if (
          !editor ||
          composing.current ||
          editor.innerHTML === lastSynchronizedMarkup.current
        ) return;
        scheduleSync();
      });
      document.addEventListener("selectionchange", selectionChanged);
      if (editorRef.current) {
        observer.observe(editorRef.current, {
          attributes: true,
          characterData: true,
          childList: true,
          subtree: true,
        });
      }
      return () => {
        document.removeEventListener("selectionchange", selectionChanged);
        observer.disconnect();
        if (syncTimer.current) clearTimeout(syncTimer.current);
      };
    }, []);

    const input = (_event: FormEvent<HTMLDivElement>): void => {
      rememberSelection();
      scheduleSync();
    };
    const paste = (event: ClipboardEvent<HTMLDivElement>): void => {
      event.preventDefault();
      document.execCommand("insertText", false, event.clipboardData.getData("text/plain"));
      rememberSelection();
      sync();
    };
    const compositionStart = (_event: CompositionEvent<HTMLDivElement>): void => {
      composing.current = true;
    };
    const compositionEnd = (_event: CompositionEvent<HTMLDivElement>): void => {
      composing.current = false;
      sync();
    };

    return (
      <div
        ref={editorRef}
        className={`${className}${circularFlow ? " circular-rich-editor" : ""}`}
        style={{
          fontFamily: element.fontName,
          fontSize: `${element.fontSize * fontScale}pt`,
          fontWeight: element.isBold ? 700 : 400,
          fontStyle: element.isItalic ? "italic" : "normal",
          textDecoration: element.isUnderline ? "underline" : "none",
          color: colorCSS(element.foreground),
          textAlign: element.textAlignment === "leading"
            ? "left"
            : element.textAlignment === "trailing"
              ? "right"
              : "center",
          writingMode: element.verticalTextLayout ? "vertical-rl" : "horizontal-tb",
          ...style,
        }}
        contentEditable
        suppressContentEditableWarning
        spellCheck={false}
        role="textbox"
        aria-multiline="true"
        aria-label={ariaLabel}
        data-placeholder={placeholder}
        onFocus={() => {
          rememberSelection();
          onActive?.(handle);
        }}
        onMouseUp={rememberSelection}
        onKeyUp={rememberSelection}
        onInput={input}
        onBlur={() => sync()}
        onPaste={paste}
        onCompositionStart={compositionStart}
        onCompositionEnd={compositionEnd}
        onPointerDown={onPointerDown}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            sync();
            onEscape?.();
          }
        }}
      />
    );
  },
);

export default RichTextEditor;
