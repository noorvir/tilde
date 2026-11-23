// What a wireframe component is: its kinds, its data, and the components in the scene. Each
// component is one element in a group of its own, made again whole when its place, its label or
// its data changes; wireframe/look.js draws it.

import { convertToExcalidrawElements } from "@excalidraw/excalidraw";
import { api, taken, live } from "../scene.js";

// In the bar's order. Rectangle is only for older notes, which show it as Card.
export const kindNames = {
  section: "Section", card: "Card", ellipse: "Circle", button: "Button", table: "Table", list: "List", dropdown: "Dropdown", rectangle: "Rectangle",
};

export const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

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

export const allBorders = ["top", "right", "bottom", "left"];
// A new rectangle or ellipse is filled as the last one set.
let isFilled = true;

export function newData(kind) {
  const data = { borders: allBorders };
  if (kind === "rectangle" || kind === "ellipse") data.filled = isFilled;
  return data;
}

// A component in the scene: one element as large as it, which nothing of Excalidraw draws, with
// its kind and `data` (label, text, borders, rows, columns, fill). The look layer draws it. A
// free text is one too, of kind "text", as large as its text.
export function wireframeElements(kind, { x, y, width, height }, data, groupIds = [`wireframe-${Math.random().toString(36).slice(2)}`]) {
  const [frame] = convertToExcalidrawElements([{
    type: "rectangle", x, y, width, height, roughness: 0, strokeWidth: 1, fillStyle: "solid", strokeStyle: "solid",
    strokeColor: "transparent", backgroundColor: "transparent", roundness: null,
  }]);
  return [{ ...frame, groupIds, customData: { ...data, tildeWireframe: kind } }];
}

// A new kind keeps the rect, the label and the text, and the fill or rows where the new kind has
// them.
export function changedKind(frame, kind) {
  const old = frame.customData;
  const data = { ...newData(kind), tildeWireframe: kind, label: old.label, text: old.text, comment: old.comment };
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
