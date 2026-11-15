// Draw mode: the tool, a shape that is edited while its comment is open, the arrow that a
// click starts, and snapping to the element under the pointer.

import { cursorRing, isSelectMode, setSelectMode } from "./cursor.js";
import { ringStyle } from "./rings.js";
import { api, taken, post, postPointer, live, changeElements } from "./scene.js";
import { isHandle } from "./wireframe/chip.js";
import { wireframe } from "./wireframe/mode.js";
import { isOverComponent, isResent, wireframeReleased } from "./wireframe/pointer.js";
import { isWireframeSnapped } from "./wireframe/snap.js";

let drawingTool = "arrow";
// The shapes being edited while their comment is open; nothing else can change meanwhile.
export let editing = null;
let isWaitingForEdit = false;
let isPressOnShape = false;
let pressAt = null;
// An arrow started by a click, whose end follows the pointer until the next click.
export let clickArrow = null;

export function cancelClickArrow() {
  if (!clickArrow) return;
  clickArrow = null;
  changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), () => ({ isDeleted: true }));
  api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: {} }, captureUpdate: "NEVER" });
}

// The tool that draws from now on; while a shape is edited, it waits for the end of the edit.
export function useTool(type) {
  drawingTool = type;
  if (!editing) api.setActiveTool({ type, locked: true });
}

export function setTool(type) {
  cancelClickArrow();
  setSelectMode(false);
  useTool(type);
}

// Only these shapes can change, with the handles of the selection tool, and no shape can be drawn.
export function editShapes(ids) {
  isWaitingForEdit = false;
  editing = new Set(ids);
  changeElements(live().filter((element) => !editing.has(element.id)).map((element) => element.id), () => ({ locked: true }));
  api.setActiveTool({ type: "selection" });
  selectEdited();
}

export function endEditing() {
  isWaitingForEdit = false;
  if (!editing) return;
  editing = null;
  changeElements(live().map((element) => element.id), () => ({ locked: false }));
  api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
  api.setActiveTool({ type: drawingTool, locked: true });
}

// The session ended: no shape is edited.
export function resetEditing() {
  editing = null;
  isWaitingForEdit = false;
}

// Draw's colour, which wireframe mode gives back when it ends.
export let drawColor = "#2F76FF";

export function setColor(color) {
  drawColor = color;
  if (wireframe) return;
  api.updateScene({ appState: { currentItemStrokeColor: color }, captureUpdate: "NEVER" });
}

// No tool: nothing draws until one is chosen.
export function setNoTool() {
  cancelClickArrow();
  setSelectMode(true);
}

export function deselect() {
  cancelClickArrow();
  api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
}

// The element under the pointer, for snapping; nil clears it.
export function setSnapFrame(frame) {
  snapFrame = frame;
}

// In Draw with no tool, the canvas takes no press, so nothing draws.
export function blockPressWithNoTool(event) {
  if (!isSelectMode || wireframe) return;
  event.stopImmediatePropagation();
  event.preventDefault();
}

// Snapping: to the corners, edge midpoints and centre of the element under the pointer.
const snapDistance = 16;
let snapFrame = null;
let startSnap = null;
export const ring = document.createElement("div");
ring.style.cssText = `${ringStyle};border-color:#2F76FF;background:rgba(47,118,255,.25)`;
export let isPressed = false;

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
  const isShown = cursorTools.has(tool) && !isSelectMode && !editing && !clickArrow && !isPressed && !isSnapping && !isWireframeSnapped && !isHandle(event.target)
    && !(wireframe && (isOverComponent || wireframe.tool === "text"));
  cursorRing.style.display = isShown ? "block" : "none";
  if (!isShown) return;
  // Wireframe shapes have their own colours: the ring is Tilde's blue.
  const color = wireframe ? "#2F76FF" : api.getAppState().currentItemStrokeColor;
  cursorRing.style.borderColor = color;
  cursorRing.style.background = `color-mix(in srgb, ${color} 25%, transparent)`;
  cursorRing.style.left = `${event.clientX}px`;
  cursorRing.style.top = `${event.clientY}px`;
}

// The pointer moved: Tilde gets its place, and the rings show.
export function pointerMoved(event) {
  postPointer(event.clientX, event.clientY);
  const tool = api?.getAppState().activeTool.type;
  const point = drawingTools.has(tool) || tool === "selection" ? snapPoint(event.clientX, event.clientY, event) : null;
  ring.style.display = point ? "block" : "none";
  if (point) {
    ring.style.left = `${point.x}px`;
    ring.style.top = `${point.y}px`;
  }
  showCursorRing(event, point !== null);
}

export function pointerLeft() {
  cursorRing.style.display = "none";
}

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

// A press: beside the shapes that are edited, it is a click away for Tilde.
export function pointerPressed(event) {
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
}

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

// Excalidraw applies a drag's moves once a frame, and loses a move that came while the frame
// waited if that frame comes before the release: on a slow page a shape would end short of the
// release. So a release away from the press comes after a move to its place, which Excalidraw
// applies with the release. A copy that wireframe mode sends in place of the release has had
// its move.
export function moveToRelease(event) {
  if (!isPressed || isResent(event) || (event.clientX === pressAt.x && event.clientY === pressAt.y)) return;
  event.target.dispatchEvent(new PointerEvent("pointermove", {
    bubbles: true, cancelable: true, composed: true, view: window,
    clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY,
    pointerId: event.pointerId, pointerType: event.pointerType, isPrimary: event.isPrimary, button: -1, buttons: 1,
    pressure: 0.5, width: event.width, height: event.height,
    shiftKey: event.shiftKey, altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey,
  }));
}

// The release: Excalidraw has finished a shape, or the edit of one.
export function pointerReleased(event) {
  isPressed = false;
  if (wireframe) {
    wireframeReleased();
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
}
