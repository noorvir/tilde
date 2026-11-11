// Undo and redo in wireframe mode: the whole scene as it was before each change.

import { api } from "../scene.js";
import { showHandles } from "./chip.js";
import { labelled, endLabel } from "./labels.js";

export const wireframeHistory = { undo: [], redo: [] };

export function record(scene = api.getSceneElementsIncludingDeleted()) {
  wireframeHistory.undo.push(scene);
  if (wireframeHistory.undo.length > 200) wireframeHistory.undo.shift();
  wireframeHistory.redo.length = 0;
}

export function clearHistory() {
  wireframeHistory.undo.length = 0;
  wireframeHistory.redo.length = 0;
}

function restoreScene(from, to) {
  if (labelled) endLabel(true);
  const scene = from.pop();
  if (!scene) return;
  to.push(api.getSceneElementsIncludingDeleted());
  api.updateScene({ elements: scene, captureUpdate: "NEVER" });
  showHandles();
}

export function undoWireframe() {
  restoreScene(wireframeHistory.undo, wireframeHistory.redo);
}

export function redoWireframe() {
  restoreScene(wireframeHistory.redo, wireframeHistory.undo);
}
