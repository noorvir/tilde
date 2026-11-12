// The look of the components: an SVG over the canvas that draws each one from its element, in
// the style, fill and fade of Tilde's settings. Each has square corners, a plain inner block in
// place of its content, which is not known, the lines that make its kind, and a label tag at
// its top left, empty until it has a label. Under a component with a fill, the screen is faded
// here, and blurred by Tilde, which gets the shapes to blur from the `under:` message.

import { api, live, post, taken } from "../scene.js";
import { clamp, newData, rowsOf } from "./components.js";
import { wireframe } from "./mode.js";

const blue = "#2F7BF6";
const dark = "#1D5BD8";

// `style`: technical, hatched, construction or blueprint; `fill` and `fade` from 0 to 1.
let look = { style: "technical", fill: 0.22, fade: 0.45 };

function node(name, attributes = {}) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  return element;
}

export const lookLayer = node("svg", { id: "tilde-look", "aria-hidden": "true" });
lookLayer.style.cssText = "position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:3;overflow:visible";
const hatch = node("pattern", { id: "tilde-hatch", width: 7, height: 7, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" });
hatch.append(node("line", { x1: 0, y1: 0, x2: 0, y2: 7, stroke: blue, "stroke-width": 1.4 }));
const definitions = node("defs");
definitions.append(hatch);
// The faded screen under every component, then every component over it.
const unders = node("g");
const tops = node("g");
lookLayer.append(definitions, unders, tops);

export function setWireframeLook(value) {
  look = value;
  drawLook();
}

// The top of a component's label tag: on its top edge, or inside it at the top of the screen.
export function tagTop({ y }) {
  return y >= 17 ? y - 17 : y + 2;
}

// A tag as wide as its text, or a short empty one.
export function tagWidth(text) {
  return text ? text.length * 7 + 10 : 28;
}

const placeholder = "Add label";

// The tag of the component under the pointer is active: darker, and with "Add label" when it
// has no label.
let activeGroup = null;

export function setActiveTag(group) {
  if (group === activeGroup) return;
  activeGroup = group;
  drawLook();
}

// A component's tag as it shows now: its text, whether that is the placeholder, and whether
// it is active.
function tagText(frame) {
  const label = frame.customData.label;
  const isActive = frame.groupIds[0] === activeGroup;
  if (label) return { text: label, isPlaceholder: false, isActive };
  if (isActive) return { text: placeholder, isPlaceholder: true, isActive };
  return { text: "", isPlaceholder: false, isActive };
}

export function shownTagWidth(frame) {
  return tagWidth(tagText(frame).text);
}

// The component whose tag is at a point; not one that Done took.
export function tagAt(x, y) {
  return live().filter((element) => element.customData?.tildeWireframe && !taken.has(element.id) && !element.customData.isLabelling).reverse().find((frame) => {
    const top = tagTop(frame);
    return x >= frame.x && x <= frame.x + shownTagWidth(frame) && y >= top && y <= top + 15;
  });
}

// What each component looks like now, by element id: the version, look and tag it was drawn
// for.
let shown = [];

// Draws the components that changed since the last time; Excalidraw calls it on every change.
export function drawLook() {
  if (!api) return;
  const lookKey = `${look.style} ${look.fill} ${look.fade}`;
  const components = live().filter((element) => element.customData?.tildeWireframe).map((element) => ({
    id: element.id, version: element.version, kind: element.customData.tildeWireframe, rect: element, data: element.customData,
    tag: tagText(element),
  }));
  // The rectangle being drawn, which Excalidraw draws in no colour, shows as the component.
  const drawing = api.getAppState().newElement;
  if (wireframe?.tool && drawing?.type === "rectangle" && !drawing.customData) {
    components.push({ id: drawing.id, version: drawing.version, kind: wireframe.tool, rect: drawing, data: newData(wireframe.tool), tag: { text: "", isPlaceholder: false, isActive: false } });
  }

  const next = components.map((component) => {
    const old = shown.find((entry) => entry.id === component.id);
    const tagKey = `${component.tag.text} ${component.tag.isActive}`;
    if (old?.version === component.version && old.lookKey === lookKey && old.tagKey === tagKey) return old;
    return { id: component.id, version: component.version, lookKey, tagKey, ...componentNodes(component) };
  });
  const isSameOrder = next.length === shown.length && next.every((entry, index) => entry.id === shown[index].id);
  if (isSameOrder) {
    next.forEach((entry, index) => {
      if (entry === shown[index]) return;
      shown[index].under.replaceWith(entry.under);
      shown[index].top.replaceWith(entry.top);
    });
  } else {
    unders.replaceChildren(...next.map((entry) => entry.under));
    tops.replaceChildren(...next.map((entry) => entry.top));
  }
  shown = next;
  postUnder(components);
}

// The shapes that Tilde blurs the screen under: each component with a fill, as
// [x, y, width, height, 1 for an ellipse else 0], in points from the top left of the canvas.
let sentUnder = "[]";

function postUnder(components) {
  const shapes = components.filter(({ data }) => data.filled !== false).map(({ kind, rect }) => {
    const values = [rect.x, rect.y, rect.width, rect.height].map((value) => Math.round(value * 10) / 10);
    return [...values, kind === "ellipse" ? 1 : 0];
  });
  const text = JSON.stringify(shapes);
  if (text === sentUnder) return;
  sentUnder = text;
  post(`under:${text}`);
}

// A component's two parts: the faded screen under it, and its look.
function componentNodes({ kind, rect: { x, y, width, height }, data, tag }) {
  const { style, fill, fade } = look;
  const under = node("g");
  const top = node("g");
  const add = (name, attributes) => top.appendChild(node(name, attributes));
  const isEllipse = kind === "ellipse";
  const isFilled = data.filled !== false;
  const borders = data.borders ?? [];
  const strokeWidth = style === "technical" ? 2 : 1.4;
  const dash = style === "construction" ? "5 4" : "none";
  const shape = (attributes) => {
    if (isEllipse) return node("ellipse", { cx: x + width / 2, cy: y + height / 2, rx: width / 2, ry: height / 2, ...attributes });
    return node("rect", { x, y, width, height, ...attributes });
  };
  const line = (x1, y1, x2, y2, lineWidth = 1) => add("line", { x1, y1, x2, y2, stroke: blue, "stroke-width": lineWidth, "stroke-dasharray": dash });
  // The block that stands for the content: a darker tint of the fill, a padding in.
  const pad = clamp(Math.min(width, height) * 0.2, 4, 12);
  const innerBox = (boxWidth) => {
    const boxHeight = height - 2 * pad;
    if (!isFilled || boxWidth < 4 || boxHeight < 4) return;
    const tint = { fill: dark, "fill-opacity": fill * 0.6 };
    if (isEllipse) add("ellipse", { cx: x + width / 2, cy: y + height / 2, rx: boxWidth / 2, ry: boxHeight / 2, ...tint });
    else add("rect", { x: x + pad, y: y + pad, width: boxWidth, height: boxHeight, ...tint });
  };

  if (isFilled) under.append(shape({ fill: "#FFFFFF", "fill-opacity": fade }));
  if (style === "technical") {
    const edge = technicalEdge({ x, y, width, height }, borders, isEllipse);
    if (edge) add("path", { d: edge, fill: "none", stroke: dark, "stroke-width": 3 });
  }
  if (isFilled) {
    top.append(shape({ fill: blue, "fill-opacity": style === "hatched" ? fill * 0.4 : fill }));
    if (style === "hatched") top.append(shape({ fill: "url(#tilde-hatch)", "fill-opacity": Math.min(1, 0.35 + fill * 1.5) }));
  }
  drawBorders({ x, y, width, height }, borders, isEllipse, { top, add, line, shape, style, strokeWidth, dash });

  if (kind === "table") {
    const { header, rows, columns } = rowsOf(kind, { width, height }, data);
    const row = (height - header) / rows;
    const column = width / columns;
    line(x, y + header, x + width, y + header, 1.4);
    for (let index = 1; index < rows; index++) line(x, y + header + index * row, x + width, y + header + index * row);
    for (let index = 1; index < columns; index++) line(x + index * column, y, x + index * column, y + height);
  } else if (kind === "list") {
    const { rows } = rowsOf(kind, { width, height }, data);
    const row = height / rows;
    for (let index = 1; index < rows; index++) line(x, y + index * row, x + width, y + index * row);
  } else if (kind === "dropdown") {
    // The value's place, left of the chevron's.
    innerBox(width - 34 - 2 * pad);
    add("path", { d: `M${x + width - 22} ${y + height / 2 - 3}l6 6 6-6`, fill: "none", stroke: dark, "stroke-width": 1.5 });
    line(x + width - 34, y, x + width - 34, y + height);
  } else if (kind === "button") {
    if (width > 12 && height > 12) add("rect", { x: x + 6, y: y + 6, width: width - 12, height: height - 12, fill: blue, "fill-opacity": Math.min(1, 0.25 + fill * 2) });
  } else {
    innerBox(width - 2 * pad);
  }

  // While the label is typed, the field stands in for the tag.
  if (!data.isLabelling) {
    const labelTop = tagTop({ y });
    add("rect", { x, y: labelTop, width: tagWidth(tag.text), height: 15, fill: tag.isActive ? dark : blue });
    if (tag.text) {
      const color = tag.isPlaceholder ? "rgba(255,255,255,.7)" : "#FFFFFF";
      const text = add("text", { x: x + 5, y: labelTop + 11, "font-size": 11, fill: color, "font-family": "ui-monospace,Menlo,monospace" });
      text.textContent = tag.text;
    }
  }
  return { under, top };
}

// Technical's hard offset edge, 3 pt out at the bottom and the right, on the borders there.
function technicalEdge({ x, y, width, height }, borders, isEllipse) {
  if (isEllipse) {
    if (!borders.length) return "";
    // The lower right half of the ellipse, moved 3 pt down and right.
    const rx = width / 2;
    const ry = height / 2;
    const cx = x + rx + 3;
    const cy = y + ry + 3;
    const at = (angle) => `${cx + rx * Math.cos(angle)} ${cy + ry * Math.sin(angle)}`;
    return `M${at(-Math.PI / 4)}A${rx} ${ry} 0 0 1 ${at((3 * Math.PI) / 4)}`;
  }
  const hasBottom = borders.includes("bottom");
  const hasRight = borders.includes("right");
  if (hasBottom && hasRight) return `M${x + 4} ${y + height + 3}H${x + width + 3}V${y + 4}`;
  if (hasBottom) return `M${x + 4} ${y + height + 3}H${x + width + 3}`;
  if (hasRight) return `M${x + width + 3} ${y + height + 3}V${y + 4}`;
  return "";
}

// The borders that are on: Blueprint's lines run 7 pt past the corners, Construction's dashes
// have ticks at the corners. An ellipse has no sides: any border outlines it.
function drawBorders({ x, y, width, height }, borders, isEllipse, { top, add, line, shape, style, strokeWidth, dash }) {
  if (!borders.length) return;
  const right = x + width;
  const bottom = y + height;
  const over = style === "blueprint" ? 7 : 0;
  if (isEllipse) {
    top.append(shape({ fill: "none", stroke: blue, "stroke-width": strokeWidth, "stroke-dasharray": dash }));
    if (style === "blueprint") {
      line(x - over, y + height / 2, right + over, y + height / 2, strokeWidth);
      line(x + width / 2, y - over, x + width / 2, bottom + over, strokeWidth);
    }
  } else if (borders.length === 4 && style !== "blueprint") {
    add("rect", { x, y, width, height, fill: "none", stroke: blue, "stroke-width": strokeWidth, "stroke-dasharray": dash });
  } else {
    const sides = { top: [x - over, y, right + over, y], bottom: [x - over, bottom, right + over, bottom], left: [x, y - over, x, bottom + over], right: [right, y - over, right, bottom + over] };
    for (const side of borders) line(...sides[side], strokeWidth);
  }
  if (style !== "construction") return;
  const corners = [[x, y, 1, 1, "top", "left"], [right, y, -1, 1, "top", "right"], [x, bottom, 1, -1, "bottom", "left"], [right, bottom, -1, -1, "bottom", "right"]];
  for (const [cornerX, cornerY, signX, signY, sideY, sideX] of corners) {
    if (!isEllipse && !(borders.includes(sideY) && borders.includes(sideX))) continue;
    const d = `M${cornerX - 6 * signX} ${cornerY}H${cornerX + 10 * signX}M${cornerX} ${cornerY - 6 * signY}V${cornerY + 10 * signY}`;
    add("path", { d, stroke: blue, "stroke-width": 1.5, fill: "none" });
  }
}
