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
    delete shape.color;
    for (const key of ["label", "borders", "rows", "columns", "filled", "radius"]) {
      if (element.customData[key] !== undefined) shape[key] = element.customData[key];
    }
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
    if (labelled) endLabel(true);
    selectedGroup = null;
    hideHandles();
    hideGuides();
    windowOutline.style.display = "none";
    const elements = live().filter((element) => !taken.has(element.id));
    if (!elements.length) return "";
    elements.forEach((element) => taken.add(element.id));
    api.history.clear();
    clearHistory();
    return JSON.stringify(elements.filter((element) => !isPart(element)).map(describe));
  },
  // With the parts of each shape: a wireframe box is several elements in one group.
  remove(ids) {
    changeElements(withGroups(ids), () => ({ isDeleted: true }));
  },
  // `state`: { tool, icons } while in wireframe mode, null to leave it; its shapes not taken go.
  setWireframe(state) {
    const wasOn = wireframe !== null;
    wireframe = state;
    if (state?.icons) kindIcons = state.icons;
    hideGuides();
    if (!state) {
      if (!wasOn) return;
      adjusting = null;
      selectedGroup = null;
      if (labelled) endLabel(false);
      hideHandles();
      setWireframeWindow(null);
      moveCursor.textContent = "";
      changeElements(live().filter((element) => !taken.has(element.id)).map((element) => element.id), () => ({ isDeleted: true }));
      clearHistory();
      api.updateScene({ appState: { currentItemStrokeStyle: "solid", currentItemStrokeWidth: 2, currentItemRoundness: "round", selectedElementIds: {} }, captureUpdate: "NEVER" });
      return;
    }
    api.updateScene({
      appState: {
        currentItemStrokeColor: "#8A8D95", currentItemStrokeStyle: "dashed", currentItemStrokeWidth: 1, currentItemBackgroundColor: "transparent",
        currentItemRoundness: "sharp", selectedElementIds: {},
      },
      captureUpdate: "NEVER",
    });
    drawingTool = "rectangle";
    if (!editing) api.setActiveTool({ type: drawingTool, locked: true });
  },
  undoWireframe() {
    restoreScene(wireframeHistory.undo, wireframeHistory.redo);
  },
  redoWireframe() {
    restoreScene(wireframeHistory.redo, wireframeHistory.undo);
  },
  // The components of a wireframe note, to edit it again: its shapes as the report gives them,
  // and their origin in points from the top left of the canvas.
  restoreWireframe({ shapes, origin: [left, top] }) {
    const elements = shapes.filter((shape) => kindNames[shape.type]).flatMap((shape) => {
      const [x, y, width, height] = shape.rect;
      const data = Object.fromEntries(["label", "borders", "rows", "columns", "filled", "radius"].filter((key) => shape[key] !== undefined).map((key) => [key, shape[key]]));
      return wireframeElements(shape.type, { x: x + left, y: y + top, width, height }, data);
    });
    api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...elements], captureUpdate: "NEVER" });
    clearHistory();
  },
  setWireframeWindow,
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

// Wireframe mode: skeletons of components (section, card, table, button, dropdown, list, and
// plain rectangles and ellipses) over
// the screen, sent together as one note. Its shapes stay until Done takes them all. Each
// component is a group of flat elements, made again whole when its label changes.
let wireframe = null;
let wireframePress = null;

// Undo and redo in wireframe mode: the whole scene as it was before each change.
const wireframeHistory = { undo: [], redo: [] };

function record(scene = api.getSceneElementsIncludingDeleted()) {
  wireframeHistory.undo.push(scene);
  if (wireframeHistory.undo.length > 200) wireframeHistory.undo.shift();
  wireframeHistory.redo.length = 0;
}

function clearHistory() {
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
const skeleton = { block: "#EEEFF2", bar: "#DADCE1", darkBar: "#C9CCD2", line: "#D3D5DA", surface: "#FAFAFB", border: "#A9ADB5", text: "#4A4D55" };

const isPart = (element) => element.customData?.tildePart === true;

function withGroups(ids) {
  const wanted = new Set(ids);
  const groups = new Set(live().filter((element) => wanted.has(element.id)).flatMap((element) => element.groupIds));
  return live().filter((element) => wanted.has(element.id) || element.groupIds.some((group) => groups.has(group))).map((element) => element.id);
}

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const flat = { roughness: 0, strokeWidth: 1, fillStyle: "solid", strokeStyle: "solid" };
const block = (x, y, width, height, backgroundColor, more = {}) => ({
  type: "rectangle", x, y, width, height, ...flat, strokeColor: "transparent", backgroundColor, roundness: null, ...more,
});
const bar = (x, y, width, height, backgroundColor = skeleton.bar) => block(x, y, width, height, backgroundColor, { roundness: { type: 2 } });
const rule = (x, y, width) => ({ type: "line", x, y, width, height: 0, points: [[0, 0], [width, 0]], ...flat, strokeColor: skeleton.line });

// The rows (and a table's header and columns) of a component: as many as `data` says, else as
// many as fit its size. They always fill it.
function rowsOf(kind, { width, height }, data) {
  if (kind === "table") {
    const header = clamp(height * 0.14, 18, 34);
    const rows = data.rows ?? clamp(Math.round((height - header) / 32), 1, 30);
    return { header, rows, columns: data.columns ?? clamp(Math.floor(width / 110), 2, 5) };
  }
  return { rows: data.rows ?? clamp(Math.round(height / 40), 1, 30) };
}

// The parts of a component in its rect, behind its label; with a label, the bars it stands in
// for are left out. `data`: the label, the `borders` it has, the `rows` and `columns` of a table
// or list, whether a rectangle or ellipse is `filled`. All four borders outline its main part,
// rounded where it is; some of them are straight lines on those sides.
function componentParts(kind, { x, y, width, height }, data) {
  const hasLabel = Boolean(data.label) || data.isLabelling;
  const pad = clamp(Math.min(width, height) * 0.12, 6, 16);
  const barHeight = clamp(height * 0.08, 5, 10);
  const parts = [];
  switch (kind) {
    case "section":
      parts.push(block(x, y, width, height, skeleton.surface));
      break;
    case "card": {
      parts.push(block(x, y, width, height, skeleton.block));
      break;
    }
    case "table": {
      const { header, rows, columns } = rowsOf(kind, { width, height }, data);
      const row = (height - header) / rows;
      const column = width / columns;
      const cell = clamp(row * 0.28, 3, 8);
      parts.push(block(x, y, width, height, skeleton.surface));
      parts.push(block(x, y, width, header, skeleton.block));
      for (let column_ = 0; column_ < columns; column_++) {
        parts.push(bar(x + column_ * column + pad, y + (header - cell) / 2, column * 0.5, cell, skeleton.darkBar));
      }
      for (let index = 0; index < rows; index++) {
        const top = y + header + index * row;
        if (index > 0) parts.push(rule(x, top, width));
        for (let column_ = 0; column_ < columns; column_++) {
          parts.push(bar(x + column_ * column + pad, top + (row - cell) / 2, column * [0.6, 0.45, 0.55][(index + column_) % 3], cell));
        }
      }
      break;
    }
    case "button":
      parts.push(block(x, y, width, height, skeleton.bar));
      if (!hasLabel) parts.push(bar(x + width * 0.3, y + (height - barHeight) / 2, width * 0.4, barHeight, skeleton.darkBar));
      break;
    case "dropdown": {
      const chevron = clamp(height * 0.18, 3, 7);
      parts.push(block(x, y, width, height, "#FFFFFF"));
      parts.push({
        type: "line", x: x + width - pad - chevron * 2, y: y + height / 2 - chevron * 0.4, width: chevron * 2, height: chevron,
        points: [[0, 0], [chevron, chevron], [chevron * 2, 0]], ...flat, strokeWidth: 2, strokeColor: "#8A8D95",
      });
      if (!hasLabel) parts.push(bar(x + pad, y + (height - barHeight) / 2, width * 0.45, barHeight));
      break;
    }
    case "list": {
      const { rows } = rowsOf(kind, { width, height }, data);
      const row = height / rows;
      const line = clamp(row * 0.3, 4, 12);
      parts.push(block(x, y, width, height, skeleton.surface));
      for (let index = 0; index < rows; index++) {
        const top = y + index * row;
        if (index > 0) parts.push(rule(x + pad, top, width - 2 * pad));
        parts.push(bar(x + pad, top + (row - line) / 2, width - 2 * pad, line));
      }
      break;
    }
    case "rectangle":
      parts.push(block(x, y, width, height, data.filled ? skeleton.block : "transparent"));
      break;
    case "ellipse":
      parts.push({ type: "ellipse", x, y, width, height, ...flat, strokeColor: "transparent", backgroundColor: data.filled ? skeleton.block : "transparent" });
      break;
  }
  const borders = data.borders ?? [];
  const radius = cornerRadius({ width, height }, data);
  if (kind === "ellipse") {
    // An ellipse has no sides: any border outlines it.
    if (borders.length) Object.assign(parts[0], { strokeColor: skeleton.border, strokeWidth: 1.5 });
  } else {
    if (radius) parts[0].roundness = { type: 3, value: radius };
    parts.push(...borderLines({ x, y, width, height }, borders, radius));
  }
  return parts;
}

// A component's corner radius, a size by name.
const radii = { none: 0, small: 4, medium: 8, large: 16 };

// The radius Excalidraw draws for a rect of this size: a quarter of its short side when that
// is smaller.
function cornerRadius({ width, height }, data) {
  const radius = radii[data.radius ?? "medium"] ?? 0;
  return Math.min(radius, Math.min(width, height) * 0.25);
}

// The borders on: lines along those sides that follow the rounded corners, with a corner drawn
// only where two of them meet. Each run of sides that meet is one line.
function borderLines({ x, y, width, height }, borders, radius) {
  const r = radius;
  const arc = (centreX, centreY, from) => Array.from({ length: 7 }, (_, index) => {
    const angle = from + (Math.PI / 2) * (index / 6);
    return [centreX + r * Math.cos(angle), centreY + r * Math.sin(angle)];
  });
  // Clockwise from the top left: each side, then the corner after it.
  const segments = [
    { sides: ["top"], points: [[x + r, y], [x + width - r, y]] },
    { sides: ["top", "right"], points: arc(x + width - r, y + r, -Math.PI / 2) },
    { sides: ["right"], points: [[x + width, y + r], [x + width, y + height - r]] },
    { sides: ["right", "bottom"], points: arc(x + width - r, y + height - r, 0) },
    { sides: ["bottom"], points: [[x + width - r, y + height], [x + r, y + height]] },
    { sides: ["bottom", "left"], points: arc(x + r, y + height - r, Math.PI / 2) },
    { sides: ["left"], points: [[x, y + height - r], [x, y + r]] },
    { sides: ["left", "top"], points: arc(x + r, y + r, Math.PI) },
  ];
  const isOn = segments.map((segment) => segment.sides.every((side) => borders.includes(side)));
  const runs = [];
  if (isOn.every(Boolean)) {
    runs.push([...segments.flatMap((segment) => segment.points), segments[0].points[0]]);
  } else {
    const start = isOn.indexOf(false);
    let run = [];
    for (let step = 1; step <= segments.length; step++) {
      const index = (start + step) % segments.length;
      if (isOn[index]) {
        run.push(...segments[index].points);
      } else if (run.length) {
        runs.push(run);
        run = [];
      }
    }
  }
  return runs.map((points) => {
    const [left, top] = points[0];
    const xs = points.map(([pointX]) => pointX);
    const ys = points.map(([, pointY]) => pointY);
    return {
      type: "line", x: left, y: top, width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys),
      points: points.map(([pointX, pointY]) => [pointX - left, pointY - top]), ...flat, strokeWidth: 1.5, strokeColor: skeleton.border,
    };
  });
}

// Buttons, dropdowns, cards and plain shapes show a label on themselves; the rest on a chip,
// over their rows.
const plainLabels = new Set(["button", "dropdown", "card", "rectangle", "ellipse"]);

const allBorders = ["top", "right", "bottom", "left"];
// A new rectangle or ellipse is filled as the last one set.
let isFilled = true;

function newData(kind) {
  const data = { borders: allBorders };
  if (kind === "rectangle" || kind === "ellipse") data.filled = isFilled;
  return data;
}

function wireframeElements(kind, rect, data, groupIds = [`wireframe-${Math.random().toString(36).slice(2)}`]) {
  const { label } = data;
  const parts = componentParts(kind, rect, data);
  parts[0].customData = { ...data, tildeWireframe: kind };
  const elements = convertToExcalidrawElements(parts);
  if (label) {
    const fontSize = plainLabels.has(kind) ? clamp(rect.height * 0.32, 12, 20) : 15;
    const [text] = convertToExcalidrawElements([{ type: "text", x: 0, y: 0, text: label, fontSize, fontFamily: 2, strokeColor: skeleton.text, textAlign: "center", roughness: 0 }]);
    const centre = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    if (!plainLabels.has(kind)) {
      elements.push(...convertToExcalidrawElements([block(centre.x - text.width / 2 - 10, centre.y - text.height / 2 - 5, text.width + 20, text.height + 10, "#FFFFFF", { strokeColor: skeleton.line, roundness: { type: 3 } })]));
    }
    elements.push({ ...text, x: centre.x - text.width / 2, y: centre.y - text.height / 2 });
  }
  return elements.map((element) => ({
    ...element,
    groupIds,
    customData: element.customData?.tildeWireframe ? element.customData : { tildePart: true },
  }));
}

// After Excalidraw has finished the rectangle of a drag: it becomes the component of the tool.
// A click instead labels the component under it.
function finishWireframeShape() {
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

// The label typed in place: at the centre of the component, in the label's own font and size,
// as wide as its text, on the label's chip where the component has one. Return or a click
// elsewhere keeps it, Esc does not.
const labelField = document.createElement("input");
labelField.id = "tilde-label";
labelField.placeholder = "Label";
labelField.style.cssText = "position:fixed;z-index:10000;transform:translate(-50%,-50%);box-sizing:content-box;margin:0;color:#4A4D55;font-family:Helvetica,sans-serif;text-align:center;outline:none;caret-color:#2F76FF;display:none";
const labelStyle = document.createElement("style");
labelStyle.textContent = "#tilde-label::placeholder { color: #A9ADB5; } [data-kind]:hover, [data-action]:hover { background: rgba(255,255,255,.14); }";
document.addEventListener("DOMContentLoaded", () => document.body.append(labelField, labelStyle));
const measure = document.createElement("canvas").getContext("2d");
// { group, label } of the component whose label is typed.
let labelled = null;
let labelBefore = null;

function sizeLabelField() {
  measure.font = `${labelField.style.fontSize} Helvetica, sans-serif`;
  labelField.style.width = `${Math.ceil(measure.measureText(labelField.value || labelField.placeholder).width) + 2}px`;
}
labelField.addEventListener("input", sizeLabelField);

function editLabel(component) {
  const data = component.customData;
  const group = component.groupIds[0];
  labelBefore = api.getSceneElementsIncludingDeleted();
  labelled = { group, label: data.label };
  hideHandles();
  // The component without its label meanwhile: the field shows it in its place.
  rebuild(group, component, { ...data, label: undefined, isLabelling: true });
  const isPlain = plainLabels.has(data.tildeWireframe);
  Object.assign(labelField.style, {
    left: `${component.x + component.width / 2}px`, top: `${component.y + component.height / 2}px`,
    fontSize: `${isPlain ? clamp(component.height * 0.32, 12, 20) : 15}px`, padding: isPlain ? "0" : "5px 10px",
    background: isPlain ? "transparent" : "#fff", border: isPlain ? "0" : `1px solid ${skeleton.line}`, borderRadius: "6px", display: "block",
  });
  labelField.value = data.label ?? "";
  sizeLabelField();
  labelField.focus();
  labelField.select();
}

function endLabel(isKept) {
  const editingLabel = labelled;
  labelled = null;
  labelField.style.display = "none";
  labelField.blur();
  const frame = editingLabel && frameOf(editingLabel.group);
  if (!frame) return;
  const label = isKept ? labelField.value.trim() || undefined : editingLabel.label;
  rebuild(editingLabel.group, frame, { ...frame.customData, label, isLabelling: undefined });
  if (label !== editingLabel.label) record(labelBefore);
}

// The second click on a component within 400 ms is a double-click, which edits its label.
let lastClick = null;

function isDoubleClick(group) {
  const now = performance.now();
  const isDouble = lastClick?.group === group && now - lastClick.time < 400;
  lastClick = isDouble ? null : { group, time: now };
  return isDouble;
}

// A component made again whole in `rect`, with `data` (kind, label, borders), at the same place
// in the stack.
function rebuild(group, rect, data) {
  const all = api.getSceneElementsIncludingDeleted();
  const index = all.findIndex((element) => element.groupIds.includes(group));
  const rest = all.filter((element) => !element.groupIds.includes(group));
  rest.splice(index, 0, ...wireframeElements(data.tildeWireframe, rect, data, [group]));
  api.updateScene({ elements: rest, captureUpdate: "NEVER" });
}

function frameOf(group) {
  return live().find((element) => element.customData?.tildeWireframe && element.groupIds[0] === group);
}

labelField.addEventListener("keydown", (event) => {
  if (event.key === "Enter") endLabel(true);
  if (event.key === "Escape") endLabel(false);
  event.stopPropagation();
});
labelField.addEventListener("blur", () => {
  if (labelled) endLabel(true);
});

// Editing a component after it is drawn. Over one, it shows as selected: a drag anywhere on it
// moves it (a section only by its chip: a drag on a section draws in it), ⌥ and a drag moves a
// copy, and a double-click edits its label. A chip at its top left moves it too; a click on its
// name changes the kind, and its controls set the borders, the rows and columns of a table or
// list, the fill of a rectangle or ellipse, or delete it. A handle at its bottom right resizes it. Moves
// and resizes snap. Only components not sent yet can change; each change can be undone.
const handleOutline = document.createElement("div");
handleOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:1px solid #2F76FF";
const chip = document.createElement("div");
chip.dataset.wireframeHandle = "";
chip.style.cssText = "position:fixed;z-index:9999;display:none;align-items:center;gap:2px;height:22px;padding:0 4px 0 8px;border-radius:11px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;cursor:move;user-select:none;white-space:nowrap";
const resizer = document.createElement("div");
resizer.dataset.wireframeHandle = "";
resizer.style.cssText = "position:fixed;z-index:9999;display:none;width:10px;height:10px;margin:-6px 0 0 -6px;border:1.5px solid #2F76FF;border-radius:2px;background:#fff;cursor:nwse-resize";
const typeMenu = document.createElement("div");
typeMenu.dataset.wireframeHandle = "";
typeMenu.style.cssText = "position:fixed;z-index:10000;display:none;flex-direction:column;padding:4px;border-radius:10px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;user-select:none";
const moveCursor = document.createElement("style");
const selectionOutline = document.createElement("div");
selectionOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:2px solid #2F76FF;margin:-1px 0 0 -1px";
document.addEventListener("DOMContentLoaded", () => document.body.append(handleOutline, selectionOutline, chip, resizer, typeMenu, moveCursor));
let hoveredGroup = null;
// The component a click selected: its handles show while the pointer is not over another one.
let selectedGroup = null;
let adjusting = null;
let isTypeMenuOpen = false;
let isOverMovable = false;

const isHandle = (target) => Boolean(target?.closest?.("[data-wireframe-handle]"));
const kindNames = {
  section: "Section", card: "Card", table: "Table", button: "Button", dropdown: "Dropdown", list: "List", rectangle: "Rectangle", ellipse: "Circle",
};
// The bar's symbol for each kind, as image URLs from Tilde.
let kindIcons = {};
const chipButton = "display:flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 2px;border-radius:5px;cursor:pointer";

function componentAt(x, y) {
  return live().filter((element) => {
    const isInside = x >= element.x && x <= element.x + element.width && y >= element.y && y <= element.y + element.height;
    return element.customData?.tildeWireframe && !taken.has(element.id) && isInside;
  }).pop();
}

// A border toggle: the square with the side it sets drawn bold while it is on.
function borderToggle(side, isOn) {
  const lines = { top: "M3 3H13", right: "M13 3V13", bottom: "M3 13H13", left: "M3 3V13" };
  const title = `${side[0].toUpperCase()}${side.slice(1)} border`;
  return `<span data-action="border:${side}" title="${title}" style="${chipButton}"><svg width="16" height="16"><rect x="3" y="3" width="10" height="10" fill="none" stroke="rgba(255,255,255,.3)"/><path d="${lines[side]}" stroke="${isOn ? "#fff" : "rgba(255,255,255,.3)"}" stroke-width="${isOn ? 2.5 : 1}" stroke-linecap="round"/></svg></span>`;
}

// − and + around a count of rows or columns.
function stepper(name, value) {
  const unit = name === "rows" ? "rows" : "cols";
  return `<span data-action="${name}:-1" title="Fewer ${name}" style="${chipButton};margin-left:6px">−</span><span style="min-width:40px;text-align:center">${value} ${unit}</span><span data-action="${name}:1" title="More ${name}" style="${chipButton}">+</span>`;
}

function fillToggle(isOn) {
  const square = `<svg width="12" height="12"><rect x="1" y="1" width="10" height="10" rx="2" fill="${isOn ? "#fff" : "none"}" stroke="#fff" stroke-width="1.5"/></svg>`;
  return `<span data-action="filled" title="Filled or outline" style="${chipButton};gap:4px;margin-left:6px;padding:0 6px;background:rgba(255,255,255,.12)">${square}${isOn ? "Filled" : "Outline"}</span>`;
}

// All borders on, or off when they all are on.
function allBordersToggle(isOn) {
  const stroke = isOn ? `stroke="#fff" stroke-width="2.5"` : `stroke="rgba(255,255,255,.3)"`;
  return `<span data-action="border:all" title="All borders" style="${chipButton}"><svg width="16" height="16"><rect x="3" y="3" width="10" height="10" fill="none" ${stroke}/></svg></span>`;
}

function chipControls(frame) {
  const data = frame.customData;
  const kind = data.tildeWireframe;
  const borders = data.borders ?? [];
  let controls = allBordersToggle(borders.length === 4) + allBorders.map((side) => borderToggle(side, borders.includes(side))).join("");
  if (kind === "table" || kind === "list") {
    const counts = rowsOf(kind, frame, data);
    controls += stepper("rows", counts.rows) + (kind === "table" ? stepper("columns", counts.columns) : "");
  }
  if (kind === "rectangle" || kind === "ellipse") controls += fillToggle(data.filled);
  return controls;
}

const deleteButton = `<span data-action="delete" title="Delete" style="${chipButton};margin-left:6px"><svg width="12" height="12"><path d="M3 3L9 9M9 3L3 9" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/></svg></span>`;

// A new kind keeps the rect and the label, and the fill or rows where the new kind has them.
function changedKind(frame, kind) {
  const old = frame.customData;
  const data = { ...newData(kind), tildeWireframe: kind, label: old.label };
  if (old.borders) data.borders = old.borders;
  if (old.radius) data.radius = old.radius;
  if ("filled" in data && old.filled !== undefined) data.filled = old.filled;
  if ((kind === "table" || kind === "list") && old.rows !== undefined) data.rows = old.rows;
  return data;
}

function deleteComponent(group) {
  record();
  changeElements(live().filter((element) => element.groupIds.includes(group)).map((element) => element.id), () => ({ isDeleted: true }));
  hideHandles();
}

// The data of a component after a press on one of its chip's controls.
function changedData(frame, action) {
  const data = { ...frame.customData };
  const [name, value] = action.split(":");
  if (name === "border" && value === "all") {
    data.borders = data.borders?.length === 4 ? [] : allBorders;
  } else if (name === "border") {
    const current = data.borders ?? [];
    const borders = current.includes(value) ? current.filter((border) => border !== value) : [...current, value];
    data.borders = allBorders.filter((border) => borders.includes(border));
  } else if (name === "filled") {
    data.filled = !data.filled;
    isFilled = data.filled;
  } else {
    const count = rowsOf(data.tildeWireframe, frame, data)[name];
    data[name] = clamp(count + Number(value), 1, name === "columns" ? 8 : 30);
  }
  return data;
}

function selectGroup(group) {
  selectedGroup = group;
  showHandles();
}

function showHandles() {
  const selected = selectedGroup ? frameOf(selectedGroup) : null;
  const isSelectionShown = Boolean(selected && wireframe && !labelled && !editing);
  selectionOutline.style.display = isSelectionShown ? "block" : "none";
  if (isSelectionShown) {
    Object.assign(selectionOutline.style, { left: `${selected.x}px`, top: `${selected.y}px`, width: `${selected.width}px`, height: `${selected.height}px` });
  }
  const group = hoveredGroup ?? selectedGroup;
  const frame = group ? frameOf(group) : null;
  const isShown = Boolean(frame && wireframe && !labelled && !editing);
  handleOutline.style.display = isShown ? "block" : "none";
  chip.style.display = isShown ? "flex" : "none";
  resizer.style.display = isShown ? "block" : "none";
  typeMenu.style.display = isShown && isTypeMenuOpen ? "flex" : "none";
  if (!isShown) return;
  const kind = frame.customData.tildeWireframe;
  Object.assign(handleOutline.style, { left: `${frame.x}px`, top: `${frame.y}px`, width: `${frame.width}px`, height: `${frame.height}px` });
  // Over the component's top edge, so the pointer reaches it without leaving the component.
  const chipTop = frame.y >= 24 ? frame.y - 20 : frame.y + 4;
  Object.assign(chip.style, { left: `${frame.x}px`, top: `${chipTop}px` });
  Object.assign(resizer.style, { left: `${frame.x + frame.width}px`, top: `${frame.y + frame.height}px` });
  Object.assign(typeMenu.style, { left: `${frame.x}px`, top: `${chipTop + 25}px` });
  const content = `<span title="Change the kind" style="margin-right:4px">⠿ ${kindNames[kind]} ▾</span>${chipControls(frame)}${deleteButton}`;
  if (chip.innerHTML !== content) chip.innerHTML = content;
  const items = Object.entries(kindNames).map(([value, name]) => {
    const background = value === kind ? "background:rgba(255,255,255,.2);" : "";
    const icon = kindIcons[value] ? `<img src="${kindIcons[value]}" style="max-width:16px;max-height:14px;pointer-events:none">` : "";
    const iconSlot = `<span style="display:flex;justify-content:center;width:18px">${icon}</span>`;
    return `<span data-kind="${value}" style="${background}display:flex;align-items:center;gap:8px;padding:5px 12px 5px 8px;border-radius:6px;cursor:pointer">${iconSlot}${name}</span>`;
  }).join("");
  if (typeMenu.innerHTML !== items) typeMenu.innerHTML = items;
}

function hideHandles() {
  hoveredGroup = null;
  isTypeMenuOpen = false;
  showHandles();
}

function startAdjusting(event, frame, mode, from) {
  hoveredGroup = frame.groupIds[0];
  isTypeMenuOpen = false;
  const rect = { x: frame.x, y: frame.y, width: frame.width, height: frame.height };
  adjusting = {
    mode, from, group: hoveredGroup, start: { x: event.clientX, y: event.clientY }, rect, data: frame.customData, moved: false,
    before: api.getSceneElementsIncludingDeleted(), isCopy: mode === "move" && event.altKey,
  };
  event.target.setPointerCapture?.(event.pointerId);
  cursorRing.style.display = "none";
  showHandles();
}

// The component a press on it moves, or with ⌥ copies: not a section without ⌥, which a drag
// draws in.
function movableAt(event) {
  const component = componentAt(event.clientX, event.clientY);
  return component && (component.customData.tildeWireframe !== "section" || event.altKey) ? component : null;
}

// The nearest snap of any of `values` (a component's edges and centre on one axis), with the
// shift that puts that value on its line.
function nearestOf(lines, values) {
  let best = null;
  for (const value of values) {
    const line = nearest(lines, value);
    if (line && (!best || line.score < best.score)) best = { ...line, shift: line.value - value };
  }
  return best;
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
      hoveredGroup = adjusting.group;
    }
  }
  if (!adjusting.moved) return;
  const { group } = adjusting;
  const now = performance.now();
  if (now - pointerAt > 50) {
    pointerAt = now;
    post(`pointer:${pointer.x},${pointer.y}`);
  }
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
      if (!moved && from === "chip") isTypeMenuOpen = !isTypeMenuOpen;
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
      if (group !== hoveredGroup) isTypeMenuOpen = false;
      hoveredGroup = group;
      isOverMovable = Boolean(movableAt(event)) && !labelled;
      moveCursor.textContent = isOverMovable ? `canvas { cursor: ${event.altKey ? "copy" : "move"} !important; }` : "";
      showHandles();
    }
    return false;
  }
  event.stopImmediatePropagation();
  event.preventDefault();
  cursorRing.style.display = "none";
  hideGuides();
  const group = hoveredGroup ?? selectedGroup;
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
    isTypeMenuOpen = false;
    showHandles();
    return true;
  }
  if (typeMenu.contains(event.target)) return true;
  startAdjusting(event, frame, resizer.contains(event.target) ? "resize" : "move", resizer.contains(event.target) ? "resizer" : "chip");
  return true;
}

// The window the wireframe is on: its components keep their place on it when it moves.
let wireframeWindow = null;
const windowOutline = document.createElement("div");
windowOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9996;display:none;border:1.5px solid rgba(47,118,255,.6);border-radius:10px";
document.addEventListener("DOMContentLoaded", () => document.body.append(windowOutline));

function setWireframeWindow(rect) {
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
  if (labelBefore) labelBefore = shift(labelBefore);
  if (adjusting) adjusting.before = shift(adjusting.before);
  // The lines seen near the pointer were where the window was.
  snapRects.clear();
  if (labelled) {
    labelField.style.left = `${parseFloat(labelField.style.left) + dx}px`;
    labelField.style.top = `${parseFloat(labelField.style.top) + dy}px`;
  }
  showHandles();
}

// Wireframe snapping: x and y each go to the nearest line within reach: edges of the elements
// seen near the pointer, thirds and halves of the screen, the window and the containers under
// the pointer (blue guides), and edges and centres of the shapes drawn (orange guides), which
// win over the page's lines within reach so that shapes line up with each other.
const wireframeReach = 8;
const snapRects = new Map();
let snapAreas = [];
const fractions = [[0, ""], [1 / 3, "⅓"], [1 / 2, "½"], [2 / 3, "⅔"], [1, ""]];

// `except`: the group of a component being moved or resized, which has no lines of its own.
function snapLines(pointer, except) {
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
    if (element.id === drawing || !element.customData?.tildeWireframe || element.groupIds.includes(except)) continue;
    lines.x.push({ value: element.x, own: true }, { value: element.x + element.width / 2, own: true }, { value: element.x + element.width, own: true });
    lines.y.push({ value: element.y, own: true }, { value: element.y + element.height / 2, own: true }, { value: element.y + element.height, own: true });
  }
  return lines;
}

function nearest(lines, value) {
  let best = null;
  for (const line of lines) {
    const distance = Math.abs(line.value - value);
    const score = distance - (line.own ? 3 : 0);
    if (distance <= wireframeReach && (!best || score < best.score)) best = { ...line, distance, score };
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

const guideColours = { page: "#2F76FF", own: "#FF8A00" };

function showGuides(x, y, point) {
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

// The pointer itself snaps: Excalidraw gets the event again at the snapped point, so the
// shape follows the guides while it is drawn. ⌘ turns snapping off.
const retargeted = new WeakSet();
function snapPointer(event) {
  if (!wireframe || retargeted.has(event)) return;
  if (editWireframe(event)) return;
  if (event.type === "pointerdown") {
    wireframePress = { ids: new Set(api.getSceneElementsIncludingDeleted().map((element) => element.id)), x: event.clientX, y: event.clientY };
  }
  const tool = api?.getAppState().activeTool.type;
  if (tool !== "rectangle" || event.metaKey || editing || labelled || isOverMovable) {
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

// In wireframe mode ⌘Z and ⇧⌘Z undo and redo its changes, and Delete deletes the component
// under the pointer; Excalidraw's own history knows none of them.
document.addEventListener("keydown", (event) => {
  if (!wireframe || isTextField(event.target)) return;
  const isUndo = event.metaKey && event.key.toLowerCase() === "z";
  const isDelete = (event.key === "Backspace" || event.key === "Delete") && (hoveredGroup ?? selectedGroup);
  if (!isUndo && !isDelete) return;
  event.stopPropagation();
  event.preventDefault();
  if (isDelete) deleteComponent(hoveredGroup ?? selectedGroup);
  else if (event.shiftKey) window.tildeDraw.redoWireframe();
  else window.tildeDraw.undoWireframe();
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
  const isShown = cursorTools.has(tool) && !editing && !clickArrow && !isPressed && !isSnapping && !isWireframeSnapped && !isHandle(event.target)
    && !(wireframe && isOverMovable);
  cursorRing.style.display = isShown ? "block" : "none";
  if (!isShown) return;
  // Wireframe shapes have their own colours: the ring is Tilde's blue.
  const color = wireframe ? "#2F76FF" : api.getAppState().currentItemStrokeColor;
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
