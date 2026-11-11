// The window the wireframe is on: its components keep their place on it when it moves.

import { taken, live, changeElements } from "../scene.js";
import { showHandles } from "./chip.js";
import { wireframeHistory } from "./history.js";
import { moveLabel } from "./labels.js";
import { adjusting } from "./pointer.js";
import { snapRects } from "./snap.js";

let wireframeWindow = null;
export const windowOutline = document.createElement("div");
windowOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9996;display:none;border:1.5px solid rgba(47,118,255,.6);border-radius:10px";

export function setWireframeWindow(rect) {
  const before = wireframeWindow;
  wireframeWindow = rect;
  windowOutline.style.display = rect ? "block" : "none";
  if (!rect) return;
  const [left, top, width, height] = rect;
  Object.assign(windowOutline.style, { left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px` });
  const dx = before ? left - before[0] : 0;
  const dy = before ? top - before[1] : 0;
  if (!dx && !dy) return;
  changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), (element) => ({ x: element.x + dx, y: element.y + dy }));
  const shift = (scene) => scene.map((element) => (taken.has(element.id) ? element : { ...element, x: element.x + dx, y: element.y + dy }));
  for (const stack of [wireframeHistory.undo, wireframeHistory.redo]) stack.forEach((scene, index) => { stack[index] = shift(scene); });
  if (adjusting) adjusting.before = shift(adjusting.before);
  // The lines seen near the pointer were where the window was.
  snapRects.clear();
  moveLabel(dx, dy, shift);
  showHandles();
}
