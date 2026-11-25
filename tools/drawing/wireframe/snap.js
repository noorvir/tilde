// Wireframe snapping: x and y each go to the nearest line within reach: edges of the elements
// seen near the pointer, thirds and halves of the screen, the window and the containers under
// the pointer (blue guides), and edges and centres of the shapes drawn (orange guides), which
// win over the page's lines within reach so that shapes line up with each other.

import { ringStyle } from "../rings.js";
import { api, live } from "../scene.js";

const wireframeReach = 8;
export const snapRects = new Map();
let snapAreas = [];
const fractions = [[0, ""], [1 / 3, "⅓"], [1 / 2, "½"], [2 / 3, "⅔"], [1, ""]];

// `except`: the components being moved or resized, which have no lines of their own.
export function snapLines(pointer, except = []) {
  const lines = { x: [], y: [] };
  for (const [left, top, width, height] of snapRects.values()) {
    const away = Math.hypot(Math.max(left - pointer.x, 0, pointer.x - left - width), Math.max(top - pointer.y, 0, pointer.y - top - height));
    if (away > 400) continue;
    lines.x.push({ value: left }, { value: left + width });
    lines.y.push({ value: top }, { value: top + height });
  }
  for (const { rect: [left, top, width, height], name } of snapAreas) {
    for (const [fraction, label] of fractions) {
      const text = label && `${label} ${name}`;
      lines.x.push({ value: left + width * fraction, label: text });
      lines.y.push({ value: top + height * fraction, label: text });
    }
  }
  const drawing = api.getAppState().newElement?.id;
  for (const element of live()) {
    if (element.id === drawing || !element.customData?.tildeWireframe || except.includes(element.groupIds[0])) continue;
    lines.x.push({ value: element.x, own: true }, { value: element.x + element.width / 2, own: true }, { value: element.x + element.width, own: true });
    lines.y.push({ value: element.y, own: true }, { value: element.y + element.height / 2, own: true }, { value: element.y + element.height, own: true });
  }
  return lines;
}

export function nearest(lines, value) {
  let best = null;
  for (const line of lines) {
    const distance = Math.abs(line.value - value);
    const score = distance - (line.own ? 3 : 0);
    if (distance <= wireframeReach && (!best || score < best.score)) best = { ...line, distance, score };
  }
  return best;
}

// The nearest snap of any of `values` (a component's edges and centre on one axis), with the
// shift that puts that value on its line.
export function nearestOf(lines, values) {
  let best = null;
  for (const value of values) {
    const line = nearest(lines, value);
    if (line && (!best || line.score < best.score)) best = { ...line, shift: line.value - value };
  }
  return best;
}

const guideStyle = "position:fixed;pointer-events:none;z-index:9998;display:none;";
export const guideX = document.createElement("div");
guideX.style.cssText = `${guideStyle}top:0;bottom:0;width:0;border-left:1px dashed #2F76FF`;
export const guideY = document.createElement("div");
guideY.style.cssText = `${guideStyle}left:0;right:0;height:0;border-top:1px dashed #2F76FF`;
export const guideLabel = document.createElement("div");
guideLabel.style.cssText = `${guideStyle}padding:2px 6px;border-radius:6px;background:#2F76FF;color:#fff;font:600 11px -apple-system,sans-serif`;
export const snapRing = document.createElement("div");
snapRing.style.cssText = `${ringStyle};border-color:#2F76FF;background:rgba(47,118,255,.25)`;
export let isWireframeSnapped = false;

export function hideGuides() {
  isWireframeSnapped = false;
  for (const element of [guideX, guideY, guideLabel, snapRing]) element.style.display = "none";
}

const guideColours = { page: "#2F76FF", own: "#FF8A00" };

export function showGuides(x, y, point) {
  isWireframeSnapped = Boolean(x || y);
  guideX.style.borderLeftColor = x?.own ? guideColours.own : guideColours.page;
  guideY.style.borderTopColor = y?.own ? guideColours.own : guideColours.page;
  const ringColour = [x, y].filter(Boolean).every((line) => line.own) ? guideColours.own : guideColours.page;
  snapRing.style.borderColor = ringColour;
  snapRing.style.background = `color-mix(in srgb, ${ringColour} 25%, transparent)`;
  guideX.style.display = x ? "block" : "none";
  guideY.style.display = y ? "block" : "none";
  snapRing.style.display = isWireframeSnapped ? "block" : "none";
  if (x) guideX.style.left = `${x.value}px`;
  if (y) guideY.style.top = `${y.value}px`;
  snapRing.style.left = `${point.x}px`;
  snapRing.style.top = `${point.y}px`;
  const label = [x?.label, y?.label].filter(Boolean).join(" · ");
  guideLabel.style.display = label ? "block" : "none";
  guideLabel.textContent = label;
  guideLabel.style.left = `${point.x + 12}px`;
  guideLabel.style.top = `${point.y + 12}px`;
}

// Lines to snap to, in points from the top left of the canvas: `rects` add to those seen
// near the pointer before; `containers`, `window` and `screen` replace theirs.
export function setSnapTargets({ rects, containers, window: windowRect, screen }) {
  for (const rect of rects) {
    const key = rect.map(Math.round).join(",");
    snapRects.delete(key);
    snapRects.set(key, rect);
  }
  while (snapRects.size > 400) snapRects.delete(snapRects.keys().next().value);
  snapAreas = [
    ...(screen ? [{ rect: screen, name: "screen" }] : []),
    ...(windowRect ? [{ rect: windowRect, name: "window" }] : []),
    ...containers.map((rect) => ({ rect, name: "container" })),
  ];
}
