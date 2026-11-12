// The bridge to Tilde: the functions that Tilde calls, and the keys and the focus that Tilde
// must know of.

import { isSelectMode, setOverLabel } from "./cursor.js";
import { clickArrow, cancelClickArrow, setTool, editShapes, endEditing, resetEditing, setColor, setNoTool, deselect, setSnapFrame } from "./draw-mode.js";
import { api, taken, post, live, changeElements, describe, isPart, withGroups, isTextField } from "./scene.js";
import { selection, selectGroup, showHandles } from "./wireframe/chip.js";
import { clearHistory, undoWireframe, redoWireframe } from "./wireframe/history.js";
import { wireframe, setWireframe, restoreWireframe, finishEdits } from "./wireframe/mode.js";
import { snapAgain, takesPointer as wireframeTakesPointer, pointerWentThrough } from "./wireframe/pointer.js";
import { setSnapTargets } from "./wireframe/snap.js";
import { setWireframeWindow } from "./wireframe/window.js";

function shapesOf(ids) {
  const wanted = new Set(ids);
  return JSON.stringify(live().filter((element) => wanted.has(element.id) && !isPart(element)).map(describe));
}

function clear() {
  resetEditing();
  taken.clear();
  api.updateScene({ elements: [], captureUpdate: "NEVER" });
  api.history.clear();
}

// The shapes drawn and not taken yet, as `takeNewShapes` gives them; they stay as they are.
function newShapes() {
  return JSON.stringify(live().filter((element) => !taken.has(element.id) && !isPart(element)).map(describe));
}

// The shapes drawn since the last call, in points from the top left of the canvas.
function takeNewShapes() {
  finishEdits();
  const elements = live().filter((element) => !taken.has(element.id));
  if (!elements.length) return "";
  elements.forEach((element) => taken.add(element.id));
  api.history.clear();
  clearHistory();
  return JSON.stringify(elements.filter((element) => !isPart(element)).map(describe));
}

// With the parts of each shape: a wireframe box is several elements in one group.
function remove(ids) {
  changeElements(withGroups(ids), () => ({ isDeleted: true }));
}

// The lines under the pointer, which Tilde found after the pointer got there.
function setSnapTargetsHere(targets) {
  setSnapTargets(targets);
  snapAgain();
}

// Whether a press at this point, in points from the top left of the canvas, is for the page.
// With a tool, every press is; with none, Draw takes no press, and wireframe mode only those on
// its components.
function takesPointer(x, y) {
  if (!isSelectMode) return true;
  return Boolean(wireframe) && wireframeTakesPointer(x, y);
}

window.tildeDraw = {
  setTool, editShapes, endEditing, setOverLabel, setColor, setNoTool, deselect, setSnapFrame,
  shapesOf, clear, newShapes, takeNewShapes, remove, takesPointer, pointerWentThrough,
  setWireframe, undoWireframe, redoWireframe, restoreWireframe, setWireframeWindow, setSnapTargets: setSnapTargetsHere,
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

// Esc reaches Tilde only when the page has nothing of its own to step back from. Either way
// the page used it: marked so, it goes no further, to macOS, which would play the alert sound.
export function escapePressed(event) {
  if (event.key !== "Escape") return;
  // Excalidraw ends the text being typed.
  if (wireframe && isTextField(event.target)) return;
  event.preventDefault();
  // In wireframe mode Esc steps back one level: the kind menu, then the selection; with
  // nothing selected it reaches Tilde, which puts the tool down.
  if (wireframe && (selection.isMenuOpen || selection.selected)) {
    event.stopPropagation();
    if (selection.isMenuOpen) {
      selection.isMenuOpen = false;
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
