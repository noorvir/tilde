// What a wireframe component is: its kinds, the flat elements it is made of, and the
// components in the scene. Each component is a group of elements, made again whole when its
// place, its label or its data changes.

import { convertToExcalidrawElements } from "@excalidraw/excalidraw";
import { api, taken, live } from "../scene.js";

export const kindNames = {
  section: "Section", card: "Card", table: "Table", button: "Button", dropdown: "Dropdown", list: "List", rectangle: "Rectangle", ellipse: "Circle",
};

export const skeleton = { block: "#EEEFF2", bar: "#DADCE1", darkBar: "#C9CCD2", line: "#D3D5DA", surface: "#FAFAFB", border: "#A9ADB5", text: "#4A4D55" };

export const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const flat = { roughness: 0, strokeWidth: 1, fillStyle: "solid", strokeStyle: "solid" };
const block = (x, y, width, height, backgroundColor, more = {}) => ({
  type: "rectangle", x, y, width, height, ...flat, strokeColor: "transparent", backgroundColor, roundness: null, ...more,
});
const bar = (x, y, width, height, backgroundColor = skeleton.bar) => block(x, y, width, height, backgroundColor, { roundness: { type: 2 } });
const rule = (x, y, width) => ({ type: "line", x, y, width, height: 0, points: [[0, 0], [width, 0]], ...flat, strokeColor: skeleton.line });

// The rows (and a table's header and columns) of a component: as many as `data` says, else as
// many as fit its size. They always fill it.
export function rowsOf(kind, { width, height }, data) {
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
export const plainLabels = new Set(["button", "dropdown", "card", "rectangle", "ellipse"]);

export const allBorders = ["top", "right", "bottom", "left"];
// A new rectangle or ellipse is filled as the last one set.
let isFilled = true;

export function newData(kind) {
  const data = { borders: allBorders };
  if (kind === "rectangle" || kind === "ellipse") data.filled = isFilled;
  return data;
}

export function wireframeElements(kind, rect, data, groupIds = [`wireframe-${Math.random().toString(36).slice(2)}`]) {
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

// A new kind keeps the rect and the label, and the fill or rows where the new kind has them.
export function changedKind(frame, kind) {
  const old = frame.customData;
  const data = { ...newData(kind), tildeWireframe: kind, label: old.label };
  if (old.borders) data.borders = old.borders;
  if (old.radius) data.radius = old.radius;
  if ("filled" in data && old.filled !== undefined) data.filled = old.filled;
  if ((kind === "table" || kind === "list") && old.rows !== undefined) data.rows = old.rows;
  return data;
}

// The data of a component after a press on one of its chip's controls.
export function changedData(frame, action) {
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

export function frameOf(group) {
  return live().find((element) => element.customData?.tildeWireframe && element.groupIds[0] === group);
}

export function componentAt(x, y) {
  return live().filter((element) => {
    const isInside = x >= element.x && x <= element.x + element.width && y >= element.y && y <= element.y + element.height;
    return element.customData?.tildeWireframe && !taken.has(element.id) && isInside;
  }).pop();
}

// A component made again whole in `rect`, with `data` (kind, label, borders), at the same place
// in the stack.
export function rebuild(group, rect, data) {
  const all = api.getSceneElementsIncludingDeleted();
  const index = all.findIndex((element) => element.groupIds.includes(group));
  const rest = all.filter((element) => !element.groupIds.includes(group));
  rest.splice(index, 0, ...wireframeElements(data.tildeWireframe, rect, data, [group]));
  api.updateScene({ elements: rest, captureUpdate: "NEVER" });
}
