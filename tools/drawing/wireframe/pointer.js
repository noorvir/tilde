// What the pointer does in wireframe mode: a drag draws a component, moves one, resizes one
// or, with ⌥, copies one; a click selects one, and a double-click edits its label.

import { moveCursor, cursorRing, isSelectMode } from "../cursor.js";
import { editing, isPressed } from "../draw-mode.js";
import { api, postPointer, live } from "../scene.js";
import { resizer, typeMenu, selection, isHandle, deleteComponent, selectGroup, showHandles, hideHandles } from "./chip.js";
import { newData, changedKind, changedData, wireframeElements, frameOf, componentAt, rebuild } from "./components.js";
import { record } from "./history.js";
import { labelField, labelled, editLabel, endLabel, isDoubleClick } from "./labels.js";
import { wireframe } from "./mode.js";
import { snapLines, nearest, nearestOf, hideGuides, showGuides } from "./snap.js";

// The press that may draw a component: the elements before it, and its place.
let wireframePress = null;
// The move or resize under way.
export let adjusting = null;
export let isOverMovable = false;

// The mode ended: no move is under way.
export function stopAdjusting() {
  adjusting = null;
}

// After Excalidraw has finished the rectangle of a drag: it becomes the component of the tool.
// A click instead labels the component under it.
export function finishWireframeShape() {
  const press = wireframePress;
  wireframePress = null;
  if (!press || !wireframe) return;
  const created = live().filter((element) => !press.ids.has(element.id));
  const box = created.find((element) => element.type === "rectangle" && !element.customData);
  const rest = api.getSceneElementsIncludingDeleted().filter((element) => element.id !== box?.id);
  // Excalidraw keeps no rectangle for a click.
  if (!box || box.width < 4 || box.height < 4) {
    api.updateScene({ elements: rest, appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
    const component = live().filter((element) => {
      const { x, y } = press;
      return element.customData?.tildeWireframe && x >= element.x && x <= element.x + element.width && y >= element.y && y <= element.y + element.height;
    }).pop();
    selectGroup(component?.groupIds[0] ?? null);
    if (component && isDoubleClick(component.groupIds[0])) editLabel(component);
    return;
  }
  const elements = wireframeElements(wireframe.tool, box, newData(wireframe.tool));
  record(rest);
  api.updateScene({ elements: [...rest, ...elements], appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
}

function startAdjusting(event, frame, mode, from) {
  selection.hovered = frame.groupIds[0];
  selection.isMenuOpen = false;
  const rect = { x: frame.x, y: frame.y, width: frame.width, height: frame.height };
  adjusting = {
    mode, from, group: selection.hovered, start: { x: event.clientX, y: event.clientY }, rect, data: frame.customData, moved: false,
    before: api.getSceneElementsIncludingDeleted(), isCopy: mode === "move" && event.altKey,
  };
  event.target.setPointerCapture?.(event.pointerId);
  cursorRing.style.display = "none";
  showHandles();
}

// The component a press on it moves, or with ⌥ copies: not a section without ⌥ while a tool
// is chosen, as a drag draws in it then.
function movableAt(event) {
  const component = componentAt(event.clientX, event.clientY);
  return component && (component.customData.tildeWireframe !== "section" || event.altKey || isSelectMode) ? component : null;
}

function adjust(event) {
  const { mode, start, rect, data } = adjusting;
  const pointer = { x: event.clientX, y: event.clientY };
  const dx = pointer.x - start.x;
  const dy = pointer.y - start.y;
  if (!adjusting.moved && Math.hypot(dx, dy) >= 3) {
    adjusting.moved = true;
    record(adjusting.before);
    // The copy goes on top, and moves; the original stays.
    if (adjusting.isCopy) {
      const copy = wireframeElements(data.tildeWireframe, rect, data);
      api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...copy], captureUpdate: "NEVER" });
      adjusting.group = copy[0].groupIds[0];
      selection.hovered = adjusting.group;
    }
  }
  if (!adjusting.moved) return;
  const { group } = adjusting;
  postPointer(pointer.x, pointer.y);
  const lines = event.metaKey ? { x: [], y: [] } : snapLines(pointer, group);
  let next;
  let snapX;
  let snapY;
  let point;
  if (mode === "move") {
    next = { ...rect, x: rect.x + dx, y: rect.y + dy };
    snapX = nearestOf(lines.x, [next.x, next.x + next.width / 2, next.x + next.width]);
    snapY = nearestOf(lines.y, [next.y, next.y + next.height / 2, next.y + next.height]);
    next.x += snapX?.shift ?? 0;
    next.y += snapY?.shift ?? 0;
    point = { x: snapX?.value ?? pointer.x, y: snapY?.value ?? pointer.y };
  } else {
    const corner = { x: rect.x + rect.width + dx, y: rect.y + rect.height + dy };
    snapX = nearest(lines.x, corner.x);
    snapY = nearest(lines.y, corner.y);
    point = { x: snapX?.value ?? corner.x, y: snapY?.value ?? corner.y };
    next = { ...rect, width: Math.max(16, point.x - rect.x), height: Math.max(12, point.y - rect.y) };
  }
  showGuides(snapX, snapY, point);
  rebuild(group, next, data);
  showHandles();
}

// Takes the pointer events of the handles and of a move or resize under way; over the canvas,
// shows the handles of the component under the pointer.
function editWireframe(event) {
  if (adjusting) {
    event.stopImmediatePropagation();
    event.preventDefault();
    if (event.type === "pointermove") adjust(event);
    if (event.type === "pointerup") {
      const { from, moved } = adjusting;
      const frame = frameOf(adjusting.group);
      adjusting = null;
      hideGuides();
      if (!moved && frame && from === "body") {
        selectGroup(frame.groupIds[0]);
        if (isDoubleClick(frame.groupIds[0])) editLabel(frame);
      }
      if (!moved && from === "chip") selection.isMenuOpen = !selection.isMenuOpen;
      showHandles();
    }
    return true;
  }
  if (event.type === "pointerdown" && labelled && event.target !== labelField) endLabel(true);
  if (!isHandle(event.target)) {
    if (event.type === "pointerdown") {
      const component = movableAt(event);
      if (component) {
        event.stopImmediatePropagation();
        event.preventDefault();
        startAdjusting(event, component, "move", "body");
        return true;
      }
      hideHandles();
    }
    if (event.type === "pointermove" && !isPressed) {
      const group = componentAt(event.clientX, event.clientY)?.groupIds[0] ?? null;
      if (group !== selection.hovered) selection.isMenuOpen = false;
      selection.hovered = group;
      isOverMovable = Boolean(movableAt(event)) && !labelled;
      const cursor = isOverMovable ? (event.altKey ? "copy" : "move") : isSelectMode ? "default" : "";
      moveCursor.textContent = cursor ? `canvas { cursor: ${cursor} !important; }` : "";
      showHandles();
    }
    return false;
  }
  event.stopImmediatePropagation();
  event.preventDefault();
  cursorRing.style.display = "none";
  hideGuides();
  const group = selection.hovered ?? selection.selected;
  const frame = group ? frameOf(group) : null;
  if (event.type !== "pointerdown" || !frame) return true;
  const action = event.target.closest("[data-action]")?.dataset.action;
  if (action === "delete") {
    deleteComponent(group);
    return true;
  }
  if (action) {
    record();
    rebuild(group, frame, changedData(frame, action));
    showHandles();
    return true;
  }
  const kind = event.target.closest("[data-kind]")?.dataset.kind;
  if (kind) {
    record();
    rebuild(group, frame, changedKind(frame, kind));
    selection.isMenuOpen = false;
    showHandles();
    return true;
  }
  if (typeMenu.contains(event.target)) return true;
  startAdjusting(event, frame, resizer.contains(event.target) ? "resize" : "move", resizer.contains(event.target) ? "resizer" : "chip");
  return true;
}

// The pointer itself snaps: Excalidraw gets the event again at the snapped point, so the
// shape follows the guides while it is drawn. ⌘ turns all snapping off: Excalidraw gets the
// event again without ⌘, which would turn its own snapping to other shapes on.
const retargeted = new WeakSet();

// Sends Excalidraw a copy of a pointer event at `point`, without ⌘, in place of the event.
function resend(event, point) {
  event.stopImmediatePropagation();
  const copy = new PointerEvent(event.type, {
    bubbles: true, cancelable: true, composed: true, view: window,
    clientX: point.x, clientY: point.y, screenX: event.screenX + point.x - event.clientX, screenY: event.screenY + point.y - event.clientY,
    pointerId: event.pointerId, pointerType: event.pointerType, isPrimary: event.isPrimary, button: event.button, buttons: event.buttons,
    pressure: event.pressure, width: event.width, height: event.height,
    shiftKey: event.shiftKey, altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: false,
  });
  retargeted.add(copy);
  event.target.dispatchEvent(copy);
}

export function snapPointer(event) {
  if (!wireframe || retargeted.has(event)) return;
  if (editWireframe(event)) return;
  if (isSelectMode) {
    // No tool: a press on empty space draws nothing, and deselects.
    if (event.type === "pointerdown") selectGroup(null);
    hideGuides();
    event.stopImmediatePropagation();
    event.preventDefault();
    return;
  }
  if (event.type === "pointerdown") {
    wireframePress = { ids: new Set(api.getSceneElementsIncludingDeleted().map((element) => element.id)), x: event.clientX, y: event.clientY };
  }
  const tool = api?.getAppState().activeTool.type;
  const pointer = { x: event.clientX, y: event.clientY };
  if (tool !== "rectangle" || editing || labelled || isOverMovable) {
    hideGuides();
    return;
  }
  if (event.metaKey) {
    hideGuides();
    resend(event, pointer);
    return;
  }
  const lines = snapLines(pointer);
  const x = nearest(lines.x, pointer.x);
  const y = nearest(lines.y, pointer.y);
  const point = { x: x?.value ?? pointer.x, y: y?.value ?? pointer.y };
  showGuides(x, y, point);
  if (x || y) resend(event, point);
}
