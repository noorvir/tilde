// The bridge to Tilde: the functions that Tilde calls, and the keys and the focus that Tilde
// must know of.

import { setOverLabel } from "./cursor.js";
import { clickArrow, cancelClickArrow, setTool, editShapes, endEditing, resetEditing, setColor, setNoTool, deselect, setSnapFrame } from "./draw-mode.js";
import { api, taken, post, live, changeElements, describe, withGroups, isTextField } from "./scene.js";
import { selection, selectGroup, showHandles } from "./wireframe/chip.js";
import { clearHistory, undoWireframe, redoWireframe } from "./wireframe/history.js";
import { setWireframeLook } from "./wireframe/look.js";
import { showPreview } from "./wireframe/preview.js";
import { wireframe, setWireframe, restoreWireframe, finishEdits } from "./wireframe/mode.js";
import { snapAgain } from "./wireframe/pointer.js";
import { setSnapTargets } from "./wireframe/snap.js";
import { setWireframeWindow } from "./wireframe/window.js";

function shapesOf(ids) {
  const wanted = new Set(ids);
  return JSON.stringify(live().filter((element) => wanted.has(element.id)).map(describe));
}

function clear() {
  resetEditing();
  taken.clear();
  api.updateScene({ elements: [], captureUpdate: "NEVER" });
  api.history.clear();
}

// The shapes drawn and not taken yet, as `takeNewShapes` gives them; they stay as they are.
function newShapes() {
  return JSON.stringify(live().filter((element) => !taken.has(element.id)).map(describe));
}

// The shapes drawn since the last call, in points from the top left of the canvas.
function takeNewShapes() {
  finishEdits();
  const elements = live().filter((element) => !taken.has(element.id));
  if (!elements.length) return "";
  elements.forEach((element) => taken.add(element.id));
  api.history.clear();
  clearHistory();
  return JSON.stringify(elements.map(describe));
}

// With the other elements of each shape's group.
function remove(ids) {
  changeElements(withGroups(ids), () => ({ isDeleted: true }));
}

// The lines under the pointer, which Tilde found after the pointer got there.
function setSnapTargetsHere(targets) {
  setSnapTargets(targets);
  snapAgain();
}

window.tildeDraw = {
  setTool, editShapes, endEditing, setOverLabel, setColor, setNoTool, deselect, setSnapFrame,
  shapesOf, clear, newShapes, takeNewShapes, remove,
  setWireframe, setWireframeLook, showPreview, undoWireframe, redoWireframe, restoreWireframe, setWireframeWindow, setSnapTargets: setSnapTargetsHere,
};

// Tilde takes its own keys before the page; it must know when a text field here has the
// keyboard.
export function focusChanged(event) {
  post(event.type === "focusin" && isTextField(event.target) ? "typing" : "notTyping");
}

// Excalidraw's own one-key tools would change the tool behind the HUD's back.
export function swallowToolKey(event) {
  if (isTextField(event.target) || event.metaKey || event.ctrlKey || event.altKey) return;
  if (/^[a-z0-9 ]$/i.test(event.key)) {
    event.stopPropagation();
    event.preventDefault();
  }
}

// Esc reaches Tilde only when the page has nothing of its own to step back from.
export function escapePressed(event) {
  if (event.key !== "Escape") return;
  // Excalidraw ends the text being typed.
  if (wireframe && isTextField(event.target)) return;
  // In wireframe mode Esc steps back one level: the chip's menu, then the selection; with
  // nothing selected it reaches Tilde, which pauses.
  if (wireframe && (selection.menu || selection.selected)) {
    event.stopPropagation();
    if (selection.menu) {
      selection.menu = null;
      showHandles();
    } else {
      selectGroup(null);
    }
    return;
  }
  if (clickArrow) {
    event.stopPropagation();
    cancelClickArrow();
    return;
  }
  post("escape");
}
