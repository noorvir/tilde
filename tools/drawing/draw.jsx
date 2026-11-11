// The drawing canvas: Excalidraw with its own interface hidden, driven from Tilde's HUD.
// Build it with tools/drawing/build.sh.
import { Excalidraw, convertToExcalidrawElements } from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";
import { createRoot } from "react-dom/client";

let api = null;
const taken = new Set();
let drawingTool = "arrow";
// The shapes being edited while their comment is open; nothing else can change meanwhile.
let editing = null;
let isWaitingForEdit = false;
let isPressOnShape = false;
let pressAt = null;
// An arrow started by a click, whose end follows the pointer until the next click.
let clickArrow = null;
const labelCursor = document.createElement("style");
document.addEventListener("DOMContentLoaded", () => document.head.appendChild(labelCursor));
const post = (message) => window.webkit?.messageHandlers?.tilde?.postMessage(message);

function live() {
  return api.getSceneElements().filter((element) => !element.isDeleted);
}

function changeElements(ids, change) {
  const wanted = new Set(ids);
  const elements = api.getSceneElementsIncludingDeleted().map((element) => {
    if (!wanted.has(element.id)) return element;
    return { ...element, ...change(element), version: element.version + 1, versionNonce: Math.floor(Math.random() * 2 ** 31) };
  });
  api.updateScene({ elements, captureUpdate: "NEVER" });
}

function describe(element) {
  const points = element.points?.map(([x, y]) => [Math.round(element.x + x), Math.round(element.y + y)]);
  const shape = { id: element.id, color: element.strokeColor, type: element.type === "freedraw" ? "freehand" : element.type };
  if (element.customData?.tildeWireframe) {
    shape.type = element.customData.tildeWireframe;
    shape.fill = element.customData.fill;
  }
  if (element.type === "text") shape.text = element.text;
  if (element.type === "arrow") {
    shape.from = points[0];
    shape.to = points[points.length - 1];
  } else if (element.type === "freedraw") {
    shape.points = points.filter((_, index) => index % 4 === 0 || index === points.length - 1);
  } else {
    shape.rect = [element.x, element.y, element.width, element.height].map(Math.round);
  }
  return shape;
}

function cancelClickArrow() {
  if (!clickArrow) return;
  clickArrow = null;
  changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), () => ({ isDeleted: true }));
  api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: {} }, captureUpdate: "NEVER" });
}

window.tildeDraw = {
  setTool(type) {
    cancelClickArrow();
    drawingTool = type;
    if (!editing) api.setActiveTool({ type, locked: true });
  },
  // Only these shapes can change, with the handles of the selection tool, and no shape can be drawn.
  editShapes(ids) {
    isWaitingForEdit = false;
    editing = new Set(ids);
    changeElements(live().filter((element) => !editing.has(element.id)).map((element) => element.id), () => ({ locked: true }));
    api.setActiveTool({ type: "selection" });
    selectEdited();
  },
  endEditing() {
    isWaitingForEdit = false;
    if (!editing) return;
    editing = null;
    changeElements(live().map((element) => element.id), () => ({ locked: false }));
    api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
    api.setActiveTool({ type: drawingTool, locked: true });
  },
  setOverLabel(isOverLabel) {
    labelCursor.textContent = isOverLabel ? "canvas { cursor: pointer !important; }" : "";
  },
  setColor(color) {
    if (wireframe) return;
    api.updateScene({ appState: { currentItemStrokeColor: color }, captureUpdate: "NEVER" });
  },
  deselect() {
    cancelClickArrow();
    api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
  },
  // The element under the pointer, for snapping; nil clears it.
  setSnapFrame(frame) {
    snapFrame = frame;
  },
  shapesOf(ids) {
    const wanted = new Set(ids);
    return JSON.stringify(live().filter((element) => wanted.has(element.id) && !isPart(element)).map(describe));
  },
  clear() {
    editing = null;
    isWaitingForEdit = false;
    taken.clear();
    api.updateScene({ elements: [], captureUpdate: "NEVER" });
    api.history.clear();
  },
  // The shapes drawn since the last call, in points from the top left of the canvas.
  takeNewShapes() {
    const elements = live().filter((element) => !taken.has(element.id));
    if (!elements.length) return "";
    elements.forEach((element) => taken.add(element.id));
    api.history.clear();
    wireframeUndone.length = 0;
    return JSON.stringify(elements.filter((element) => !isPart(element)).map(describe));
  },
  // With the parts of each shape: a wireframe box is several elements in one group.
  remove(ids) {
    changeElements(withGroups(ids), () => ({ isDeleted: true }));
  },
  // `state`: { tool, fill } while in wireframe mode, null to leave it; its shapes not taken go.
  setWireframe(state) {
    const wasOn = wireframe !== null;
    wireframe = state;
    hideGuides();
    if (!state) {
      if (!wasOn) return;
      changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), () => ({ isDeleted: true }));
      wireframeUndone.length = 0;
      api.updateScene({ appState: { currentItemRoughness: 0, selectedElementIds: {} }, captureUpdate: "NEVER" });
      return;
    }
    api.updateScene({
      appState: {
        currentItemStrokeColor: wireframeStroke, currentItemRoughness: 1, currentItemBackgroundColor: "transparent",
        currentItemFontFamily: 2, currentItemFontSize: 28, selectedElementIds: {},
      },
      captureUpdate: "NEVER",
    });
    drawingTool = state.tool === "text" ? "text" : "rectangle";
    if (!editing) api.setActiveTool({ type: drawingTool, locked: true });
  },
  // The last wireframe shape not taken yet goes, and comes back with redo.
  undoWireframe() {
    const last = live().filter((element) => !taken.has(element.id)).pop();
    if (!last) return;
    const ids = withGroups([last.id]);
    wireframeUndone.push(ids);
    changeElements(ids, () => ({ isDeleted: true }));
  },
  redoWireframe() {
    const ids = wireframeUndone.pop();
    if (ids) changeElements(ids, () => ({ isDeleted: false }));
  },
  // Lines to snap to, in points from the top left of the canvas: `rects` add to those seen
  // near the pointer before; `containers`, `window` and `screen` replace theirs.
  setSnapTargets({ rects, containers, window: windowRect, screen }) {
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
  },
};

// Wireframe mode: rough grey boxes, buttons, image placeholders and text over the screen,
// sent together as one note. Its shapes stay until Done takes them all.
let wireframe = null;
let wireframePress = null;
const wireframeUndone = [];
const wireframeStroke = "#5C5C5C";
// An opaque base under a pattern hides the screen below; outline only shows it.
const wireframeFills = {
  dots: { base: "#EEEEEE", fillStyle: "dots", backgroundColor: "#8E8E8E" },
  hatched: { base: "#F4F4F4", fillStyle: "hachure", backgroundColor: "#A8A8A8" },
  white: { base: null, fillStyle: "solid", backgroundColor: "#FFFFFF" },
  outline: { base: null, fillStyle: "solid", backgroundColor: "transparent" },
};

const isPart = (element) => element.customData?.tildePart === true;

function withGroups(ids) {
  const wanted = new Set(ids);
  const groups = new Set(live().filter((element) => wanted.has(element.id)).flatMap((element) => element.groupIds));
  return live().filter((element) => wanted.has(element.id) || element.groupIds.some((group) => groups.has(group))).map((element) => element.id);
}

function wireframeElements(kind, { x, y, width, height }, fillName) {
  const fill = wireframeFills[fillName] ?? wireframeFills.dots;
  const groupIds = [`wireframe-${Math.random().toString(36).slice(2)}`];
  const style = { strokeColor: wireframeStroke, strokeWidth: 2, roughness: 1 };
  const skeletons = [];
  if (fill.base) {
    skeletons.push({ type: "rectangle", x, y, width, height, ...style, strokeColor: "transparent", backgroundColor: fill.base, fillStyle: "solid", roundness: kind === "button" ? { type: 3 } : null });
  }
  const frame = {
    type: "rectangle", x, y, width, height, ...style, backgroundColor: fill.backgroundColor, fillStyle: fill.fillStyle,
    roundness: kind === "button" ? { type: 3 } : null, customData: { tildeWireframe: kind, fill: fillName },
  };
  if (kind === "button") {
    frame.label = { text: "Button", fontSize: Math.max(12, Math.min(24, height * 0.4)), fontFamily: 2, strokeColor: wireframeStroke };
  }
  skeletons.push(frame);
  if (kind === "image") {
    skeletons.push({ type: "line", x, y, width, height, points: [[0, 0], [width, height]], ...style });
    skeletons.push({ type: "line", x: x + width, y, width, height, points: [[0, 0], [-width, height]], ...style });
  }
  return convertToExcalidrawElements(skeletons).map((element) => ({
    ...element,
    groupIds,
    customData: element.customData?.tildeWireframe ? element.customData : { tildePart: true },
  }));
}

// After Excalidraw has finished the rectangle of a drag: it becomes the shape of the tool.
function finishWireframeShape() {
  const before = wireframePress;
  wireframePress = null;
  if (!before || !wireframe) return;
  const created = live().filter((element) => !before.has(element.id));
  if (created.length) wireframeUndone.length = 0;
  const box = created.find((element) => element.type === "rectangle" && !element.customData);
  if (!box || wireframe.tool === "text") return;
  const rest = api.getSceneElementsIncludingDeleted().filter((element) => element.id !== box.id);
  if (box.width < 4 || box.height < 4) {
    api.updateScene({ elements: rest, appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
    return;
  }
  const elements = wireframeElements(wireframe.tool, box, wireframe.fill);
  api.updateScene({ elements: [...rest, ...elements], appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
}

// Wireframe snapping: x and y each go to the nearest line within reach: edges of the elements
// seen near the pointer, thirds and halves of the screen, the window and the containers under
// the pointer, and edges and centres of the shapes drawn.
const wireframeReach = 8;
const snapRects = new Map();
let snapAreas = [];
const fractions = [[0, ""], [1 / 3, "⅓"], [1 / 2, "½"], [2 / 3, "⅔"], [1, ""]];

function snapLines(pointer) {
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
    if (element.id === drawing || isPart(element) || !(element.customData?.tildeWireframe || element.type === "text")) continue;
    lines.x.push({ value: element.x }, { value: element.x + element.width / 2 }, { value: element.x + element.width });
    lines.y.push({ value: element.y }, { value: element.y + element.height / 2 }, { value: element.y + element.height });
  }
  return lines;
}

function nearest(lines, value) {
  let best = null;
  for (const line of lines) {
    const distance = Math.abs(line.value - value);
    if (distance <= wireframeReach && (!best || distance < best.distance)) best = { ...line, distance };
  }
  return best;
}

const guideStyle = "position:fixed;pointer-events:none;z-index:9998;display:none;";
const guideX = document.createElement("div");
guideX.style.cssText = `${guideStyle}top:0;bottom:0;width:0;border-left:1px dashed #2F76FF`;
const guideY = document.createElement("div");
guideY.style.cssText = `${guideStyle}left:0;right:0;height:0;border-top:1px dashed #2F76FF`;
const guideLabel = document.createElement("div");
guideLabel.style.cssText = `${guideStyle}padding:2px 6px;border-radius:6px;background:#2F76FF;color:#fff;font:600 11px -apple-system,sans-serif`;
const snapRing = document.createElement("div");
document.addEventListener("DOMContentLoaded", () => document.body.append(guideX, guideY, guideLabel, snapRing));
let isWireframeSnapped = false;

function hideGuides() {
  isWireframeSnapped = false;
  for (const element of [guideX, guideY, guideLabel, snapRing]) element.style.display = "none";
}

function showGuides(x, y, point) {
  isWireframeSnapped = Boolean(x || y);
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

// The pointer itself snaps: Excalidraw gets the event again at the snapped point, so the
// shape follows the guides while it is drawn. ⌘ turns snapping off.
const retargeted = new WeakSet();
function snapPointer(event) {
  if (!wireframe || retargeted.has(event)) return;
  if (event.type === "pointerdown") wireframePress = new Set(api.getSceneElementsIncludingDeleted().map((element) => element.id));
  const tool = api?.getAppState().activeTool.type;
  if ((tool !== "rectangle" && tool !== "text") || event.metaKey || editing) {
    hideGuides();
    return;
  }
  const pointer = { x: event.clientX, y: event.clientY };
  const lines = snapLines(pointer);
  const x = nearest(lines.x, pointer.x);
  const y = nearest(lines.y, pointer.y);
  const point = { x: x?.value ?? pointer.x, y: y?.value ?? pointer.y };
  showGuides(x, y, point);
  if (!x && !y) return;
  event.stopImmediatePropagation();
  const copy = new PointerEvent(event.type, {
    bubbles: true, cancelable: true, composed: true, view: window,
    clientX: point.x, clientY: point.y, screenX: event.screenX + point.x - pointer.x, screenY: event.screenY + point.y - pointer.y,
    pointerId: event.pointerId, pointerType: event.pointerType, isPrimary: event.isPrimary, button: event.button, buttons: event.buttons,
    pressure: event.pressure, width: event.width, height: event.height,
    shiftKey: event.shiftKey, altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey,
  });
  retargeted.add(copy);
  event.target.dispatchEvent(copy);
}
for (const type of ["pointerdown", "pointermove", "pointerup"]) window.addEventListener(type, snapPointer, true);

// A scroll would move the scene; the canvas has nothing to scroll.
window.addEventListener("wheel", (event) => {
  event.stopPropagation();
  event.preventDefault();
}, { capture: true, passive: false });

// Tilde takes its own keys before the page; it must know when a text field here has the
// keyboard. Excalidraw's own one-key tools would change the tool behind the HUD's back.
const isTextField = (element) => element?.matches?.("textarea, input, [contenteditable]") ?? false;
document.addEventListener("focusin", (event) => post(isTextField(event.target) ? "typing" : "notTyping"));
document.addEventListener("focusout", () => post("notTyping"));
document.addEventListener("keydown", (event) => {
  if (isTextField(event.target) || event.metaKey || event.ctrlKey || event.altKey) return;
  if (/^[a-z0-9 ]$/i.test(event.key)) {
    event.stopPropagation();
    event.preventDefault();
  }
}, true);

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  // Excalidraw ends the text being typed.
  if (wireframe && isTextField(event.target)) return;
  if (clickArrow) {
    event.stopPropagation();
    cancelClickArrow();
    return;
  }
  post("escape");
}, true);

// Snapping: to the corners, edge midpoints and centre of the element under the pointer.
const snapDistance = 16;
let snapFrame = null;
let startSnap = null;
let pointerAt = 0;
const ringStyle = "position:fixed;width:12px;height:12px;margin:-8px 0 0 -8px;border:2px solid;border-radius:50%;pointer-events:none;z-index:9999;display:none";
const ring = document.createElement("div");
ring.style.cssText = `${ringStyle};border-color:#2F76FF;background:rgba(47,118,255,.25)`;
// The same ring at the pointer while a drawing tool is ready, in the colour it draws with, so
// the tool shows; it gives way to the snap ring and to a shape being drawn.
const cursorRing = document.createElement("div");
cursorRing.style.cssText = ringStyle;
snapRing.style.cssText = `${ringStyle};border-color:#2F76FF;background:rgba(47,118,255,.25)`;
document.addEventListener("DOMContentLoaded", () => document.body.append(ring, cursorRing));
let isPressed = false;

function snapPoint(x, y, event) {
  if (!snapFrame || event.metaKey) return null;
  const [left, top, width, height] = snapFrame;
  const xs = [left, left + width / 2, left + width];
  const ys = [top, top + height / 2, top + height];
  let best = null;
  for (const px of xs) {
    for (const py of ys) {
      const distance = Math.hypot(px - x, py - y);
      if (distance <= snapDistance && (!best || distance < best.distance)) best = { x: px, y: py, distance };
    }
  }
  return best;
}

const drawingTools = new Set(["arrow", "rectangle", "ellipse"]);
const cursorTools = new Set([...drawingTools, "freedraw"]);

function showCursorRing(event, isSnapping) {
  const tool = api?.getAppState().activeTool.type;
  const isShown = cursorTools.has(tool) && !editing && !clickArrow && !isPressed && !isSnapping && !isWireframeSnapped;
  cursorRing.style.display = isShown ? "block" : "none";
  if (!isShown) return;
  const color = api.getAppState().currentItemStrokeColor;
  cursorRing.style.borderColor = color;
  cursorRing.style.background = `color-mix(in srgb, ${color} 25%, transparent)`;
  cursorRing.style.left = `${event.clientX}px`;
  cursorRing.style.top = `${event.clientY}px`;
}

window.addEventListener("pointermove", (event) => {
  const now = performance.now();
  if (now - pointerAt > 50) {
    pointerAt = now;
    post(`pointer:${event.clientX},${event.clientY}`);
  }
  const tool = api?.getAppState().activeTool.type;
  const point = drawingTools.has(tool) || tool === "selection" ? snapPoint(event.clientX, event.clientY, event) : null;
  ring.style.display = point ? "block" : "none";
  if (point) {
    ring.style.left = `${point.x}px`;
    ring.style.top = `${point.y}px`;
  }
  showCursorRing(event, point !== null);
}, true);

document.addEventListener("pointerleave", () => {
  cursorRing.style.display = "none";
});

function selectEdited() {
  const element = live().find((candidate) => editing.has(candidate.id));
  const selectedLinearElement = element?.type === "arrow" ? new globalThis.TildeLinearElementEditor(element) : null;
  const selectedElementIds = Object.fromEntries([...editing].map((id) => [id, true]));
  api.updateScene({ appState: { selectedElementIds, selectedLinearElement }, captureUpdate: "NEVER" });
}

function distanceToSegment(x, y, [ax, ay], [bx, by]) {
  const lengthSquared = (bx - ax) ** 2 + (by - ay) ** 2;
  const along = lengthSquared ? Math.max(0, Math.min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / lengthSquared)) : 0;
  return Math.hypot(x - ax - along * (bx - ax), y - ay - along * (by - ay));
}

// Whether a press at this point belongs to the shapes being edited, with room for their handles.
function isOnEditedShape(x, y) {
  const reach = 18;
  return live().filter((element) => editing.has(element.id)).some((element) => {
    if (element.type === "arrow") {
      const points = element.points.map(([px, py]) => [element.x + px, element.y + py]);
      return points.slice(1).some((point, index) => distanceToSegment(x, y, points[index], point) <= reach);
    }
    const xs = element.points?.map(([px]) => element.x + px) ?? [element.x, element.x + element.width];
    const ys = element.points?.map(([, py]) => element.y + py) ?? [element.y, element.y + element.height];
    return x >= Math.min(...xs) - reach && x <= Math.max(...xs) + reach && y >= Math.min(...ys) - reach && y <= Math.max(...ys) + reach;
  });
}

window.addEventListener("pointerdown", (event) => {
  isPressed = true;
  cursorRing.style.display = "none";
  startSnap = snapPoint(event.clientX, event.clientY, event);
  pressAt = { x: event.clientX, y: event.clientY };
  isPressOnShape = true;
  if (isWaitingForEdit || (editing && !isOnEditedShape(event.clientX, event.clientY))) {
    isPressOnShape = false;
    event.stopPropagation();
    event.preventDefault();
    if (editing) post("clickAway");
  }
}, true);

function linePoints(start, end) {
  return { x: start.x, y: start.y, width: Math.abs(end.x - start.x), height: Math.abs(end.y - start.y), points: [[0, 0], [end.x - start.x, end.y - start.y]], lastCommittedPoint: null };
}

function snapNewShape(element, event) {
  const end = snapPoint(event.clientX, event.clientY, event);
  if (!startSnap && !end) return;
  if (element.type === "arrow") {
    const last = element.points[element.points.length - 1];
    const from = startSnap ?? { x: element.x, y: element.y };
    const to = end ?? { x: element.x + last[0], y: element.y + last[1] };
    changeElements([element.id], () => linePoints(from, to));
  } else if (element.type === "rectangle" || element.type === "ellipse") {
    const firstX = startSnap?.x ?? element.x;
    const firstY = startSnap?.y ?? element.y;
    const lastX = end?.x ?? element.x + element.width;
    const lastY = end?.y ?? element.y + element.height;
    changeElements([element.id], () => ({
      x: Math.min(firstX, lastX), y: Math.min(firstY, lastY), width: Math.abs(lastX - firstX), height: Math.abs(lastY - firstY),
    }));
  }
}

function snapSelectedArrow(event) {
  const end = snapPoint(event.clientX, event.clientY, event);
  const selected = Object.keys(api.getAppState().selectedElementIds);
  if (!end || selected.length !== 1) return;
  const element = live().find((candidate) => candidate.id === selected[0]);
  if (element?.type !== "arrow") return;
  const last = element.points[element.points.length - 1];
  const start = { x: element.x, y: element.y };
  const stop = { x: element.x + last[0], y: element.y + last[1] };
  const nearStart = Math.hypot(start.x - end.x, start.y - end.y) < Math.hypot(stop.x - end.x, stop.y - end.y);
  // A snap is for an end that was dragged, not for an arrow moved as a whole.
  if (Math.min(Math.hypot(start.x - end.x, start.y - end.y), Math.hypot(stop.x - end.x, stop.y - end.y)) > snapDistance * 2) return;
  changeElements([element.id], () => (nearStart ? linePoints(end, stop) : linePoints(start, end)));
}

function finishClickArrow(element, event) {
  const from = clickArrow.start ?? { x: element.x, y: element.y };
  const to = snapPoint(event.clientX, event.clientY, event) ?? { x: event.clientX, y: event.clientY };
  if (Math.hypot(to.x - from.x, to.y - from.y) < 4) {
    cancelClickArrow();
    return;
  }
  clickArrow = null;
  changeElements([element.id], () => linePoints(from, to));
  api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: {} }, captureUpdate: "NEVER" });
  isWaitingForEdit = true;
  post("shape");
}

window.addEventListener("pointerup", (event) => {
  isPressed = false;
  if (wireframe) {
    setTimeout(finishWireframeShape, 0);
    return;
  }
  if (!isPressOnShape) return;
  ring.style.display = "none";
  // After Excalidraw has finished the shape.
  setTimeout(() => {
    const fresh = live().filter((element) => !taken.has(element.id));
    if (clickArrow && fresh.length) {
      finishClickArrow(fresh[fresh.length - 1], event);
      return;
    }
    const isClick = Math.hypot(event.clientX - pressAt.x, event.clientY - pressAt.y) < 4;
    if (fresh.length && isClick && api.getAppState().activeTool.type === "arrow") {
      clickArrow = { start: startSnap };
      return;
    }
    // With the other tools, a click without a drag draws nothing.
    if (fresh.length && isClick) {
      changeElements(fresh.map((element) => element.id), () => ({ isDeleted: true }));
      api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: {} }, captureUpdate: "NEVER" });
      return;
    }
    if (fresh.length) {
      snapNewShape(fresh[fresh.length - 1], event);
      isWaitingForEdit = true;
      post("shape");
    } else if (api.getAppState().activeTool.type === "selection") {
      snapSelectedArrow(event);
      // A press beside the handles clears the selection; the shape stays in edit mode.
      if (editing && !api.getAppState().selectedElementIds[[...editing][0]]) selectEdited();
      post("edited");
    }
  }, 0);
}, true);

const initialData = {
  appState: {
    viewBackgroundColor: "transparent",
    currentItemStrokeColor: "#2F76FF",
    currentItemRoughness: 0,
    currentItemStrokeWidth: 2,
    activeTool: { type: "arrow", locked: true },
  },
};

createRoot(document.getElementById("root")).render(
  <Excalidraw
    initialData={initialData}
    excalidrawAPI={(value) => {
      api = value;
      post("ready");
    }}
  />
);
