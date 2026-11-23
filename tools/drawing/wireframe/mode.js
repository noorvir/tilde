// Wireframe mode: components (section, table, button, dropdown, list, plain rectangles and
// ellipses, and older notes' cards) and text over the screen, sent together as one note. Its shapes stay until
// Done takes them all. Each component is one element, which wireframe/look.js draws.

import { moveCursor, setSelectMode } from "../cursor.js";
import { drawColor, useTool } from "../draw-mode.js";
import { api, taken, live, changeElements, isTextField } from "../scene.js";
import { selection, setKindIcons, deleteComponent, hideHandles } from "./chip.js";
import { kindNames, wireframeElements } from "./components.js";
import { clearHistory, undoWireframe, redoWireframe } from "./history.js";
import { commented, closeComment } from "./comment.js";
import { labelled, endLabel } from "./labels.js";
import { stopAdjusting } from "./pointer.js";
import { hideGuides } from "./snap.js";
import { windowOutline, setWireframeWindow } from "./window.js";

export let wireframe = null;

// `state`: { tool, icons } while in wireframe mode, null to leave it; its shapes not taken go.
export function setWireframe(state) {
  const wasOn = wireframe !== null;
  wireframe = state;
  if (state?.icons) setKindIcons(state.icons);
  setSelectMode(Boolean(state) && !state.tool);
  hideGuides();
  if (!state) {
    if (!wasOn) return;
    stopAdjusting();
    if (commented) closeComment(true);
    selection.selected = null;
    if (labelled) endLabel(false);
    hideHandles();
    setWireframeWindow(null);
    moveCursor.textContent = "";
    changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), () => ({ isDeleted: true }));
    clearHistory();
    api.updateScene({
      appState: { currentItemStrokeColor: drawColor, currentItemStrokeStyle: "solid", currentItemStrokeWidth: 2, currentItemRoundness: "round", selectedElementIds: {} },
      captureUpdate: "NEVER",
    });
    return;
  }
  api.updateScene({
    appState: {
      // The rectangle being drawn shows only as the look of the tool's component.
      currentItemStrokeColor: "transparent", currentItemStrokeStyle: "solid", currentItemStrokeWidth: 1, currentItemBackgroundColor: "transparent",
      currentItemRoundness: "sharp", selectedElementIds: {},
    },
    captureUpdate: "NEVER",
  });
  useTool("rectangle");
}

// The components of a wireframe note, to edit it again: its shapes as the report gives them,
// and their origin in points from the top left of the canvas.
export function restoreWireframe({ shapes, origin: [left, top] }) {
  const elements = shapes.filter((shape) => kindNames[shape.type] || shape.type === "text").flatMap((shape) => {
    const [x, y, width, height] = shape.rect;
    const data = Object.fromEntries(["label", "text", "comment", "borders", "rows", "columns", "filled", "radius"].filter((key) => shape[key] !== undefined).map((key) => [key, shape[key]]));
    return wireframeElements(shape.type, { x: x + left, y: y + top, width, height }, data);
  });
  api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...elements], captureUpdate: "NEVER" });
  clearHistory();
}

// Before Done takes the components: the label that is typed is kept, and no handle, guide or
// outline shows in the pictures.
export function finishEdits() {
  if (labelled) endLabel(true);
  if (commented) closeComment(true);
  selection.selected = null;
  hideHandles();
  hideGuides();
  windowOutline.style.display = "none";
}

// In wireframe mode ⌘Z and ⇧⌘Z undo and redo its changes, and Delete deletes the component
// under the pointer; Excalidraw's own history knows none of them.
export function keyPressed(event) {
  if (!wireframe || isTextField(event.target)) return;
  const isUndo = event.metaKey && event.key.toLowerCase() === "z";
  const isDelete = (event.key === "Backspace" || event.key === "Delete") && (selection.hovered ?? selection.selected);
  if (!isUndo && !isDelete) return;
  event.stopPropagation();
  event.preventDefault();
  if (isDelete) deleteComponent(selection.hovered ?? selection.selected);
  else if (event.shiftKey) redoWireframe();
  else undoWireframe();
}
