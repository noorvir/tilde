// What the pointer does in wireframe mode: a drag draws a component, also in another, or with
// no tool moves one; the chip and the top grip move one too, a corner handle resizes one from
// that corner, and ⌥ and a drag copies one. A click selects one, and a double-click or a click on its tag edits its label.

import { moveCursor, cursorRing, isSelectMode } from "../cursor.js";
import { editing, isPressed } from "../draw-mode.js";
import { api, postPointer, live } from "../scene.js";
import { typeMenu, bordersMenu, selection, isHandle, deleteComponent, selectGroup, showHandles, hideHandles, toggleMenu } from "./chip.js";
import { newData, changedKind, changedData, wireframeElements, frameOf, componentAt, rebuild } from "./components.js";
import { commentBox, commented, openComment, closeComment } from "./comment.js";
import { record } from "./history.js";
import { labelField, labelled, editLabel, endLabel, isDoubleClick } from "./labels.js";
import { tagAt } from "./look.js";
import { wireframe } from "./mode.js";
import { snapLines, nearest, nearestOf, hideGuides, showGuides } from "./snap.js";

// The press that may draw a component: the elements before it, and its place.
let wireframePress = null;
// The move or resize under way.
export let adjusting = null;
// The pointer is over a component that moves, or over a tag: a press there draws nothing.
export let isOverComponent = false;

// The mode ended: no move is under way.
export function stopAdjusting() {
  adjusting = null;
}

// With no tool, whether a press at this point is for the page: on a component, its label tag
// or its handles, or anywhere while a label or a comment is typed or a component moves. Tilde
// lets every other press through to the app behind.
export function takesPointer(x, y) {
  return Boolean(labelled || commented || adjusting || componentAt(x, y) || tagAt(x, y) || isHandle(document.elementFromPoint(x, y)));
}

// The pointer went through to the app behind, which gets its moves meanwhile: as over empty
// space here, no component is under it, and a press there ends the selection.
export function pointerWentThrough(isPress) {
  if (!wireframe) return;
  isOverComponent = false;
  // Where the pointer is now, the page does not know.
  lastPointer = null;
  if (isPress) selection.selected = null;
  hideHandles();
}

// After Excalidraw has finished the rectangle of a drag: it becomes the component of the tool.
// A click instead selects the component under it, and a double-click edits its label.
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

// `corner` of a resize: "nw", "ne", "sw" or "se", the one that the pointer moves.
function startAdjusting(event, frame, mode, from, corner = null) {
  selection.hovered = frame.groupIds[0];
  const menuBefore = selection.menu;
  selection.menu = null;
  const rect = { x: frame.x, y: frame.y, width: frame.width, height: frame.height };
  adjusting = {
    mode, from, corner, group: selection.hovered, start: { x: event.clientX, y: event.clientY }, rect, data: frame.customData, moved: false, menuBefore,
    before: api.getSceneElementsIncludingDeleted(), isCopy: mode === "move" && event.altKey,
  };
  event.target.setPointerCapture?.(event.pointerId);
  cursorRing.style.display = "none";
  showHandles();
}

// The component a press on it moves, or with ⌥ copies. While a tool is chosen a press draws,
// also on a component, so that one can be drawn in another: a component then moves by its chip.
function movableAt(event) {
  const component = componentAt(event.clientX, event.clientY);
  return component && (isSelectMode || event.altKey) ? component : null;
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
    // The corner follows the pointer, and the opposite one stays: the component is never
    // smaller than 16 × 12, and never turns over.
    const isLeft = adjusting.corner.includes("w");
    const isTop = adjusting.corner.includes("n");
    const fixed = { x: isLeft ? rect.x + rect.width : rect.x, y: isTop ? rect.y + rect.height : rect.y };
    const corner = { x: (isLeft ? rect.x : rect.x + rect.width) + dx, y: (isTop ? rect.y : rect.y + rect.height) + dy };
    snapX = nearest(lines.x, corner.x);
    snapY = nearest(lines.y, corner.y);
    point = { x: snapX?.value ?? corner.x, y: snapY?.value ?? corner.y };
    const width = Math.max(16, isLeft ? fixed.x - point.x : point.x - fixed.x);
    const height = Math.max(12, isTop ? fixed.y - point.y : point.y - fixed.y);
    next = { ...rect, x: isLeft ? fixed.x - width : fixed.x, y: isTop ? fixed.y - height : fixed.y, width, height };
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
      const { from, moved, menuBefore } = adjusting;
      const frame = frameOf(adjusting.group);
      adjusting = null;
      hideGuides();
      if (!moved && frame && from === "body") {
        selectGroup(frame.groupIds[0]);
        if (isDoubleClick(frame.groupIds[0])) editLabel(frame);
      }
      // A click on the grip selects the component, as one on it does.
      if (!moved && frame && from === "grip") selectGroup(frame.groupIds[0]);
      // A click on the chip's name opens the kinds, or closes them.
      if (!moved && from === "chip") selection.menu = menuBefore === "kinds" ? null : "kinds";
      showHandles();
    }
    return true;
  }
  // The comment box takes its own presses, which place the caret.
  if (commentBox.contains(event.target)) {
    event.stopImmediatePropagation();
    return true;
  }
  if (event.type === "pointerdown" && commented && !event.target.closest?.("[data-menu=comment]")) closeComment(true);
  if (event.type === "pointerdown" && labelled && event.target !== labelField) endLabel(true);
  if (!isHandle(event.target)) {
    // A click on a component's tag types its label.
    const tagged = tagAt(event.clientX, event.clientY);
    if (event.type === "pointerdown" && tagged) {
      event.stopImmediatePropagation();
      event.preventDefault();
      selectGroup(tagged.groupIds[0]);
      editLabel(tagged);
      return true;
    }
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
      // Over a tag is over its component.
      const group = (componentAt(event.clientX, event.clientY) ?? tagged)?.groupIds[0] ?? null;
      if (group !== selection.hovered && !commented) selection.menu = null;
      selection.hovered = group;
      const isMovable = Boolean(movableAt(event)) && !labelled;
      isOverComponent = isMovable || (Boolean(tagged) && !labelled);
      let cursor = isSelectMode ? "default" : "";
      if (isMovable) cursor = event.altKey ? "copy" : "move";
      if (tagged && !labelled) cursor = "text";
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
  if (event.target.closest("[data-menu=borders]")) {
    toggleMenu("borders");
    return true;
  }
  // The Comment button opens the component's comment, or closes it, keeping what was typed.
  if (event.target.closest("[data-menu=comment]")) {
    if (commented) {
      closeComment(true);
      return true;
    }
    // The component is selected while its comment is typed, and as it was after: a comment
    // adds no step to Esc.
    const selectedBefore = selection.selected;
    selection.selected = group;
    selection.menu = "comment";
    showHandles();
    openComment(frame, () => {
      selection.selected = selectedBefore;
      selection.menu = null;
      showHandles();
    });
    return true;
  }
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
    selection.menu = null;
    showHandles();
    return true;
  }
  if (typeMenu.contains(event.target) || bordersMenu.contains(event.target)) return true;
  const corner = event.target.closest("[data-corner]")?.dataset.corner;
  if (corner) {
    startAdjusting(event, frame, "resize", "corner", corner);
    return true;
  }
  startAdjusting(event, frame, "move", event.target.closest("#tilde-grip") ? "grip" : "chip");
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

// The pointer's place and buttons from its last event on the page, a press and a release too,
// sent again by `snapAgain` as a move. None while the pointer is over the app behind.
let lastPointer = null;

// New lines to snap to apply to the pointer where it is, also when it rests: a move to where
// it is goes to the element that had its last event. Tilde finds the lines after the pointer got
// there, so they can come after a press: the move is then to the press, and a drag that started
// there stays there until the pointer moves.
export function snapAgain() {
  if (!wireframe || !lastPointer?.target.isConnected) return;
  lastPointer.target.dispatchEvent(new PointerEvent("pointermove", lastPointer.init));
}

export function snapPointer(event) {
  if (!wireframe || retargeted.has(event)) return;
  lastPointer = {
    target: event.target,
    init: {
      bubbles: true, cancelable: true, composed: true, view: window,
      clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY,
      pointerId: event.pointerId, pointerType: event.pointerType, isPrimary: event.isPrimary, button: event.button, buttons: event.buttons,
      pressure: event.pressure, width: event.width, height: event.height,
      shiftKey: event.shiftKey, altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey,
    },
  };
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
  if (tool !== "rectangle" || editing || labelled || isOverComponent) {
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
