// The cursor on the canvas: the ring of a tool that is ready, the cursor that the page sets
// in place of Excalidraw's, and the state with no tool.

import { ringStyle } from "./rings.js";
import { post } from "./scene.js";
import { hideGuides } from "./wireframe/snap.js";

// The hand over a note's label, which a press opens.
export const labelCursor = document.createElement("style");
// The cursor of what the pointer is over: a component that moves, or no tool.
export const moveCursor = document.createElement("style");
// The ring at the pointer while a drawing tool is ready, in the colour it draws with, so
// the tool shows; it gives way to the snap ring and to a shape being drawn.
export const cursorRing = document.createElement("div");
cursorRing.style.cssText = ringStyle;

// No tool, after Esc: nothing draws; in wireframe mode components still change. Tilde must
// know: with no tool, it lets the pointer through to the app behind where the page takes none.
export let isSelectMode = false;

export function setSelectMode(isOn) {
  isSelectMode = isOn;
  post(isOn ? "noTool" : "tool");
  if (!isOn) {
    moveCursor.textContent = "";
    return;
  }
  hideGuides();
  cursorRing.style.display = "none";
  moveCursor.textContent = "canvas { cursor: default !important; }";
}

export function setOverLabel(isOverLabel) {
  labelCursor.textContent = isOverLabel ? "canvas { cursor: pointer !important; }" : "";
}
