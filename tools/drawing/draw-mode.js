// Draw mode: the tool, the group of shapes that one comment gets (Esc ends it), the shapes
// that are edited while their comment is open, the arrow that a click starts, and snapping to
// the element under the pointer.

import { cursorRing, isSelectMode, setSelectMode } from "./cursor.js";
import { ringStyle } from "./rings.js";
import { api, taken, post, postPointer, live, changeElements, isTextField } from "./scene.js";
import { isHandle } from "./wireframe/chip.js";
import { wireframe } from "./wireframe/mode.js";
import { isOverComponent, isResent, wireframeReleased } from "./wireframe/pointer.js";
import { isWireframeSnapped } from "./wireframe/snap.js";

let drawingTool = "arrow";
// The shapes being edited while their comment is open; nothing else can change meanwhile.
export let editing = null;
let isPressOnShape = false;
let pressAt = null;
// The elements that were there at the press: the others are what the press drew.
let idsAtPress = new Set();
// An arrow started by a click, whose end follows the pointer until the next click.
export let clickArrow = null;

export function cancelClickArrow() {
  if (!clickArrow) return;
  const { id } = clickArrow;
  clickArrow = null;
  changeElements([id], () => ({ isDeleted: true }));
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
  editing = new Set(ids);
  changeElements(live().filter((element) => !editing.has(element.id)).map((element) => element.id), () => ({ locked: true }));
  api.setActiveTool({ type: "selection" });
  selectEdited();
}

export function endEditing() {
  if (!editing) return;
  editing = null;
  changeElements(live().map((element) => element.id), () => ({ locked: false }));
  api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
  api.setActiveTool({ type: drawingTool, locked: true });
}

// The session ended: no shape is edited.
export function resetEditing() {
  editing = null;
}

// Whether Draw has shapes that no comment has taken yet: Esc then ends the group and opens
// its comment. Tilde gets each change.
export let hasGroup = false;

export function groupChanged() {
  if (!api) return;
  const appState = api.getAppState();
  const unfinished = new Set([clickArrow?.id, appState.newElement?.id, appState.multiElement?.id, appState.editingTextElement?.id]);
  const isGroup = !wireframe && !editing && live().some((element) => !taken.has(element.id) && !unfinished.has(element.id));
  if (isGroup === hasGroup) return;
  hasGroup = isGroup;
  post(isGroup ? "group" : "noGroup");
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

// Delete and Backspace in Draw: the selected shapes, with their text, as one change that Undo
// brings back. The shapes of saved notes stay.
export function deleteSelected() {
  const selected = api.getAppState().selectedElementIds;
  const ids = new Set(live().filter((element) => selected[element.id] && !taken.has(element.id)).map((element) => element.id));
  if (!ids.size) return;
  const elements = api.getSceneElementsIncludingDeleted().map((element) => {
    if (!ids.has(element.id) && !ids.has(element.containerId)) return element;
    return { ...element, isDeleted: true, version: element.version + 1, versionNonce: Math.floor(Math.random() * 2 ** 31) };
  });
  api.updateScene({ elements, appState: { selectedElementIds: {} }, captureUpdate: "IMMEDIATELY" });
}

export function deleteKey(event) {
  if (wireframe || isTextField(event.target) || (event.key !== "Backspace" && event.key !== "Delete")) return;
  event.stopPropagation();
  event.preventDefault();
  deleteSelected();
}

export function deselect() {
  cancelClickArrow();
  api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
}

// The element under the pointer, for snapping; nil clears it.
export function setSnapFrame(frame) {
  snapFrame = frame;
}

// In Draw with no tool nothing draws: a press on a shape selects it, and ⇧ adds it to the selection.
export function blockPressWithNoTool(event) {
  if (!isSelectMode || wireframe) return;
  event.stopImmediatePropagation();
  event.preventDefault();
  if (event.type !== "pointerdown") return;
  const shape = shapeAt(event.clientX, event.clientY);
  const selectedElementIds = event.shiftKey ? { ...api.getAppState().selectedElementIds } : {};
  if (shape) selectedElementIds[shape.id] = true;
  api.updateScene({ appState: { selectedElementIds }, captureUpdate: "NEVER" });
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
const cursorTools = new Set([...drawingTools, "freedraw", "text"]);

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
  const selectedLinearElement = element?.type === "arrow" && editing.size === 1 ? new globalThis.TildeLinearElementEditor(element) : null;
  const selectedElementIds = Object.fromEntries([...editing].map((id) => [id, true]));
  api.updateScene({ appState: { selectedElementIds, selectedLinearElement }, captureUpdate: "NEVER" });
}

function distanceToSegment(x, y, [ax, ay], [bx, by]) {
  const lengthSquared = (bx - ax) ** 2 + (by - ay) ** 2;
  const along = lengthSquared ? Math.max(0, Math.min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / lengthSquared)) : 0;
  return Math.hypot(x - ax - along * (bx - ax), y - ay - along * (by - ay));
}

// Whether a point is on a shape, within `reach`: near an arrow's line, or in a box around another shape.
function isOnShape(element, x, y, reach) {
  if (element.type === "arrow") {
    const points = element.points.map(([px, py]) => [element.x + px, element.y + py]);
    return points.slice(1).some((point, index) => distanceToSegment(x, y, points[index], point) <= reach);
  }
  const [left, top, right, bottom] = boundsOf(element);
  return x >= left - reach && x <= right + reach && y >= top - reach && y <= bottom + reach;
}

// Left, top, right and bottom of a shape, with the points of a line.
function boundsOf(element) {
  const xs = element.points?.map(([px]) => element.x + px) ?? [element.x, element.x + element.width];
  const ys = element.points?.map(([, py]) => element.y + py) ?? [element.y, element.y + element.height];
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
}

// The wings of a line's arrowheads, as Excalidraw draws them: about 25 pt back from the tip,
// 20° to each side, shorter on a short last segment.
function arrowheadPoints(element) {
  const points = element.points.map(([px, py]) => [element.x + px, element.y + py]);
  const ends = [];
  if (element.endArrowhead) ends.push([points[points.length - 1], points[points.length - 2]]);
  if (element.startArrowhead) ends.push([points[0], points[1]]);
  return ends.flatMap(([tip, before]) => {
    if (!before) return [];
    const angle = Math.atan2(before[1] - tip[1], before[0] - tip[0]);
    const length = Math.min(25, Math.hypot(before[0] - tip[0], before[1] - tip[1]) / 2);
    return [-1, 1].map((side) => [tip[0] + length * Math.cos(angle + side * Math.PI / 9), tip[1] + length * Math.sin(angle + side * Math.PI / 9)]);
  });
}

// Tilde's dashed outline around each selected shape in Draw, so the user sees what Delete
// removes. Excalidraw outlines a selection only with its selection tool. The box holds the
// drawn shape, with arrowheads and stroke, and a margin; a flat shape gets a minimum size.
export const selectionLayer = document.createElement("div");
selectionLayer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:9997";
let shownOutlines = "";

function outlineOf(element) {
  let [left, top, right, bottom] = boundsOf(element);
  for (const [x, y] of element.type === "arrow" ? arrowheadPoints(element) : []) {
    left = Math.min(left, x);
    top = Math.min(top, y);
    right = Math.max(right, x);
    bottom = Math.max(bottom, y);
  }
  const reach = element.strokeWidth / 2 + 6;
  const minimum = 28;
  const centre = [(left + right) / 2, (top + bottom) / 2];
  const width = Math.max(right - left + 2 * reach, minimum);
  const height = Math.max(bottom - top + 2 * reach, minimum);
  return [centre[0] - width / 2, centre[1] - height / 2, width, height].map(Math.round);
}

export function drawSelection() {
  const selected = !api || wireframe || editing ? {} : api.getAppState().selectedElementIds;
  const boxes = live().filter((element) => selected[element.id]).map(outlineOf);
  const key = JSON.stringify(boxes);
  if (key === shownOutlines) return;
  shownOutlines = key;
  selectionLayer.replaceChildren(...boxes.map(([left, top, width, height]) => {
    const outline = document.createElement("div");
    outline.style.cssText = `position:absolute;left:${left}px;top:${top}px;width:${width}px;height:${height}px;border:1.5px dashed #2F76FF;border-radius:4px;box-sizing:border-box`;
    return outline;
  }));
}

// Whether a press at this point belongs to the shapes being edited, with room for their handles.
function isOnEditedShape(x, y) {
  return live().some((element) => editing.has(element.id) && isOnShape(element, x, y, 18));
}

// The shape not taken yet under a point, the top one, for a click with no tool.
export function shapeAt(x, y) {
  return live().filter((element) => !taken.has(element.id) && isOnShape(element, x, y, 8)).pop();
}

// Excalidraw puts the text of a click inside the shape under it; a label starts at the click
// instead. The shapes are out of the scene only while Excalidraw takes the press.
const containerTypes = new Set(["rectangle", "ellipse", "diamond", "arrow"]);
let hiddenForText = [];

export function hideShapesForText(event) {
  const appState = api?.getAppState();
  if (event.button !== 0 || appState?.activeTool.type !== "text" || appState.editingTextElement || editing) return;
  hiddenForText = live().filter((element) => containerTypes.has(element.type)).map((element) => element.id);
  if (!hiddenForText.length) return;
  changeElements(hiddenForText, () => ({ isDeleted: true }));
  api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
  // Also when Excalidraw stops the press from going on.
  setTimeout(showShapesAgain, 0);
}

export function showShapesAgain() {
  if (!hiddenForText.length) return;
  const ids = hiddenForText;
  hiddenForText = [];
  changeElements(ids, () => ({ isDeleted: false }));
}

// ↩ ends the label being typed, as a click away does; ⇧↩ is a new line.
export function enterEndsText(event) {
  if (event.key !== "Enter" || event.shiftKey || event.metaKey || !event.target.classList?.contains("excalidraw-wysiwyg")) return;
  event.stopPropagation();
  event.preventDefault();
  event.target.blur();
}

// A press: beside the shapes that are edited, it is a click away for Tilde.
export function pointerPressed(event) {
  isPressed = true;
  cursorRing.style.display = "none";
  startSnap = snapPoint(event.clientX, event.clientY, event);
  pressAt = { x: event.clientX, y: event.clientY };
  idsAtPress = new Set(api?.getSceneElementsIncludingDeleted().map((element) => element.id));
  isPressOnShape = true;
  if (editing && !isOnEditedShape(event.clientX, event.clientY)) {
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
  // The new arrow is selected, so Delete removes it.
  api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: { [element.id]: true } }, captureUpdate: "NEVER" });
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

// The release: Excalidraw has finished a shape, or the edit of one. A new shape joins the group,
// and the tool stays for the next one.
export function pointerReleased(event) {
  isPressed = false;
  if (wireframe) {
    wireframeReleased();
    return;
  }
  if (!isPressOnShape) return;
  ring.style.display = "none";
  // A click with the text tool opens Excalidraw's text field, which Esc or a click away ends.
  if (!editing && api.getAppState().activeTool.type === "text") return;
  // After Excalidraw has finished the shape.
  setTimeout(() => {
    const created = live().filter((element) => !taken.has(element.id) && !idsAtPress.has(element.id));
    if (clickArrow) {
      const arrow = live().find((element) => element.id === clickArrow.id);
      if (arrow) finishClickArrow(arrow, event);
      else clickArrow = null;
      return;
    }
    const isClick = Math.hypot(event.clientX - pressAt.x, event.clientY - pressAt.y) < 4;
    if (created.length && isClick && api.getAppState().activeTool.type === "arrow") {
      clickArrow = { start: startSnap, id: created[created.length - 1].id };
      return;
    }
    // With the other tools, a click without a drag draws nothing.
    if (created.length && isClick) {
      changeElements(created.map((element) => element.id), () => ({ isDeleted: true }));
      api.updateScene({ appState: { multiElement: null, newElement: null, selectedLinearElement: null, selectedElementIds: {} }, captureUpdate: "NEVER" });
      return;
    }
    if (created.length) {
      snapNewShape(created[created.length - 1], event);
      // The new shape is selected, so Delete removes it.
      const selectedElementIds = Object.fromEntries(created.map((element) => [element.id, true]));
      api.updateScene({ appState: { selectedElementIds }, captureUpdate: "NEVER" });
      groupChanged();
    } else if (api.getAppState().activeTool.type === "selection") {
      snapSelectedArrow(event);
      // A press beside the handles clears the selection; the shape stays in edit mode.
      if (editing && !api.getAppState().selectedElementIds[[...editing][0]]) selectEdited();
      post("edited");
    }
  }, 0);
}
