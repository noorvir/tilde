// The look of the components: an SVG over the canvas that draws each one from its element, in
// the style, fill, fade and colours of Tilde's settings. Each has square corners, a plain inner
// block in place of its content, which is not known, the lines that make its kind, and a label
// tag at its top left, empty until it has a label, and its text, if it has one, in its middle.
// A free text, of kind "text", is only its text. A component inside another has a white gap
// around its border. Under a component with a fill, the screen is faded here, and blurred by
// Tilde, which gets the shapes to blur from the `under:` message.

import { api, live, post, taken } from "../scene.js";
import { clamp, newData, rowsOf } from "./components.js";
import { wireframe } from "./mode.js";

// Each group of kinds has a colour, and a dark one for its edges, its inner block and its
// active tag.
const palettes = {
  blue: { name: "blue", main: "#2F7BF6", dark: "#1D5BD8" },
  teal: { name: "teal", main: "#0E9384", dark: "#0A6E63" },
  orange: { name: "orange", main: "#E0660F", dark: "#B34E08" },
};
const paletteOfKind = { table: palettes.teal, list: palettes.teal, button: palettes.orange, dropdown: palettes.orange };

// `style`: technical, hatched, construction or blueprint; `fill` and `fade` from 0 to 1;
// `colours`: byKind, or oneColour for all in blue.
let look = { style: "construction", fill: 0.06, fade: 0.58, colours: "byKind" };

// A kind's colours in the look now.
export function paletteOf(kind) {
  if (look.colours === "oneColour") return palettes.blue;
  return paletteOfKind[kind] ?? palettes.blue;
}

function node(name, attributes = {}) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  return element;
}

export const lookLayer = node("svg", { id: "tilde-look", "aria-hidden": "true" });
lookLayer.style.cssText = "position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:3;overflow:visible";
// Hatched's lines, in each colour: #tilde-hatch-blue, -teal and -orange.
const definitions = node("defs");
for (const { name, main } of Object.values(palettes)) {
  const hatch = node("pattern", { id: `tilde-hatch-${name}`, width: 7, height: 7, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" });
  hatch.append(node("line", { x1: 0, y1: 0, x2: 0, y2: 7, stroke: main, "stroke-width": 1.4 }));
  definitions.append(hatch);
}
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

// A component's tag as it shows now: its text, whether that is the placeholder, whether it is
// active, and whether it shows. Once Done took the component, its empty tag no longer shows:
// the pictures that the agent gets would only have it as noise.
function tagText(frame) {
  const label = frame.customData.label;
  const isActive = frame.groupIds[0] === activeGroup;
  if (label) return { text: label, isPlaceholder: false, isActive, isShown: true };
  if (isActive) return { text: placeholder, isPlaceholder: true, isActive, isShown: true };
  return { text: "", isPlaceholder: false, isActive, isShown: !taken.has(frame.id) };
}

export function shownTagWidth(frame) {
  return tagWidth(tagText(frame).text);
}

// The component whose tag is at a point; not one that Done took.
export function tagAt(x, y) {
  return live().filter((element) => isComponent(element) && !taken.has(element.id) && element.customData.typing !== "label").reverse().find((frame) => {
    const top = tagTop(frame);
    return x >= frame.x && x <= frame.x + shownTagWidth(frame) && y >= top && y <= top + 15;
  });
}

const isComponent = (element) => element.customData?.tildeWireframe && element.customData.tildeWireframe !== "text";

// Text, on a component or free, in one font, with a white halo that keeps it legible over any
// line or fill.
const textFont = { size: 13, family: "-apple-system,system-ui,sans-serif" };
const measure = document.createElement("canvas").getContext("2d");
measure.font = `${textFont.size}px ${textFont.family}`;
export const textHeight = 18;

export function textWidth(text) {
  return Math.ceil(measure.measureText(text).width);
}

// Where a component's text is: in its middle, or a table's in the middle of its header.
export function textCentre({ x, y, width, height, customData }) {
  if (customData.tildeWireframe !== "table") return { x: x + width / 2, y: y + height / 2 };
  const { header } = rowsOf("table", { width, height }, customData);
  return { x: x + width / 2, y: y + header / 2 };
}

// The box of a component's text, as large as the text.
export function textBox(frame) {
  const centre = textCentre(frame);
  const width = textWidth(frame.customData.text) + 4;
  return { x: centre.x - width / 2, y: centre.y - textHeight / 2, width, height: textHeight };
}

// The component whose text is at a point; not one that Done took, nor one whose text is typed.
export function textAt(x, y) {
  return live().filter((element) => isComponent(element) && element.customData.text && !taken.has(element.id) && element.customData.typing !== "text").reverse().find((frame) => {
    const box = textBox(frame);
    return x >= box.x && x <= box.x + box.width && y >= box.y && y <= box.y + box.height;
  });
}

function textNode({ x, y, anchor, colour }, text) {
  const textElement = node("text", {
    x, y, "text-anchor": anchor, "dominant-baseline": "central", "font-size": textFont.size, "font-family": textFont.family, fill: colour,
    stroke: "#FFFFFF", "stroke-width": 3, "stroke-linejoin": "round", "paint-order": "stroke",
  });
  textElement.textContent = text;
  return textElement;
}

// What each component looks like now, by element id: the version, look and tag it was drawn
// for.
let shown = [];

// Draws the components that changed since the last time; Excalidraw calls it on every change.
export function drawLook() {
  if (!api) return;
  const lookKey = `${look.style} ${look.fill} ${look.fade} ${look.colours}`;
  const components = live().filter((element) => element.customData?.tildeWireframe).map((element) => ({
    id: element.id, version: element.version, kind: element.customData.tildeWireframe, rect: element, data: element.customData,
    tag: tagText(element),
  }));
  // The rectangle being drawn, which Excalidraw draws in no colour, shows as the component.
  const drawing = api.getAppState().newElement;
  if (wireframe?.tool && drawing?.type === "rectangle" && !drawing.customData) {
    components.push({ id: drawing.id, version: drawing.version, kind: wireframe.tool, rect: drawing, data: newData(wireframe.tool), tag: { text: "", isPlaceholder: false, isActive: false, isShown: true } });
  }

  const next = components.map((component) => {
    const old = shown.find((entry) => entry.id === component.id);
    const isNested = components.some((other) => other.kind !== "text" && contains(other.rect, component.rect));
    const tagKey = `${component.tag.text} ${component.tag.isActive} ${component.tag.isShown}`;
    if (old?.version === component.version && old.lookKey === lookKey && old.tagKey === tagKey && old.isNested === isNested) return old;
    return { id: component.id, version: component.version, lookKey, tagKey, isNested, ...componentNodes(component, isNested) };
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

// Whether `outer` holds all of `inner` and is larger: `inner` is a part of it.
function contains(outer, inner) {
  const isLarger = outer.width * outer.height > inner.width * inner.height;
  return isLarger && outer.x <= inner.x && outer.y <= inner.y && outer.x + outer.width >= inner.x + inner.width && outer.y + outer.height >= inner.y + inner.height;
}

// The shapes that Tilde blurs the screen under: each component with a fill, as
// [x, y, width, height, 1 for an ellipse else 0], in points from the top left of the canvas.
let sentUnder = "[]";

function postUnder(components) {
  const shapes = components.filter(({ kind, data }) => kind !== "text" && data.filled !== false).map(({ kind, rect }) => {
    const values = [rect.x, rect.y, rect.width, rect.height].map((value) => Math.round(value * 10) / 10);
    return [...values, kind === "ellipse" ? 1 : 0];
  });
  const text = JSON.stringify(shapes);
  if (text === sentUnder) return;
  sentUnder = text;
  post(`under:${text}`);
}

// A component's two parts: the faded screen under it, and its look. A part of another
// component has a white gap outside its border, so that the two borders do not run together.
function componentNodes({ kind, rect: { x, y, width, height }, data, tag }, isNested) {
  const { style, fill, fade } = look;
  const { name: colour, main, dark } = paletteOf(kind);
  const under = node("g");
  const top = node("g");
  const add = (name, attributes) => top.appendChild(node(name, attributes));
  if (kind === "text") {
    if (data.typing !== "text") top.append(textNode({ x: x + 2, y: y + height / 2, anchor: "start", colour: dark }, data.text));
    return { under, top };
  }
  const isEllipse = kind === "ellipse";
  const isFilled = data.filled !== false;
  const borders = data.borders ?? [];
  const strokeWidth = style === "technical" ? 2 : 1.4;
  const dash = style === "construction" ? "5 4" : "none";
  const shape = (attributes) => {
    if (isEllipse) return node("ellipse", { cx: x + width / 2, cy: y + height / 2, rx: width / 2, ry: height / 2, ...attributes });
    return node("rect", { x, y, width, height, ...attributes });
  };
  const line = (x1, y1, x2, y2, lineWidth = 1) => add("line", { x1, y1, x2, y2, stroke: main, "stroke-width": lineWidth, "stroke-dasharray": dash });
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
  if (isNested) drawGap({ x, y, width, height }, borders, isEllipse, { add, strokeWidth });
  if (style === "technical") {
    const edge = technicalEdge({ x, y, width, height }, borders, isEllipse);
    if (edge) add("path", { d: edge, fill: "none", stroke: dark, "stroke-width": 3 });
  }
  if (isFilled) {
    top.append(shape({ fill: main, "fill-opacity": style === "hatched" ? fill * 0.4 : fill }));
    if (style === "hatched") top.append(shape({ fill: `url(#tilde-hatch-${colour})`, "fill-opacity": Math.min(1, 0.35 + fill * 1.5) }));
  }
  drawBorders({ x, y, width, height }, borders, isEllipse, { top, add, line, shape, style, strokeWidth, dash, main });

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
    if (width > 12 && height > 12) add("rect", { x: x + 6, y: y + 6, width: width - 12, height: height - 12, fill: main, "fill-opacity": Math.min(1, 0.25 + fill * 2) });
  } else {
    innerBox(width - 2 * pad);
  }

  if (data.text && data.typing !== "text") {
    const centre = textCentre({ x, y, width, height, customData: data });
    top.append(textNode({ ...centre, anchor: "middle", colour: dark }, data.text));
  }

  // While the label is typed, the field stands in for the tag.
  if (data.typing !== "label" && tag.isShown) {
    const labelTop = tagTop({ y });
    add("rect", { x, y: labelTop, width: tagWidth(tag.text), height: 15, fill: tag.isActive ? dark : main });
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

// A white line 2.5 pt wide just outside each border that is on, round an ellipse.
function drawGap({ x, y, width, height }, borders, isEllipse, { add, strokeWidth }) {
  if (!borders.length) return;
  const gap = { fill: "none", stroke: "#FFFFFF", "stroke-width": 2.5 };
  const out = strokeWidth / 2 + 1.25;
  const left = x - out;
  const top = y - out;
  const right = x + width + out;
  const bottom = y + height + out;
  if (isEllipse) {
    add("ellipse", { cx: x + width / 2, cy: y + height / 2, rx: width / 2 + out, ry: height / 2 + out, ...gap });
  } else if (borders.length === 4) {
    add("rect", { x: left, y: top, width: right - left, height: bottom - top, ...gap });
  } else {
    // Each side as long as the gap's corners, which it shares with the sides next to it.
    const end = 1.25;
    const sides = { top: [left - end, top, right + end, top], bottom: [left - end, bottom, right + end, bottom], left: [left, top - end, left, bottom + end], right: [right, top - end, right, bottom + end] };
    for (const side of borders) {
      const [x1, y1, x2, y2] = sides[side];
      add("line", { x1, y1, x2, y2, ...gap });
    }
  }
}

// The borders that are on: Blueprint's lines run 7 pt past the corners, Construction's dashes
// have ticks at the corners. An ellipse has no sides: any border outlines it.
function drawBorders({ x, y, width, height }, borders, isEllipse, { top, add, line, shape, style, strokeWidth, dash, main }) {
  if (!borders.length) return;
  const right = x + width;
  const bottom = y + height;
  const over = style === "blueprint" ? 7 : 0;
  if (isEllipse) {
    top.append(shape({ fill: "none", stroke: main, "stroke-width": strokeWidth, "stroke-dasharray": dash }));
    if (style === "blueprint") {
      line(x - over, y + height / 2, right + over, y + height / 2, strokeWidth);
      line(x + width / 2, y - over, x + width / 2, bottom + over, strokeWidth);
    }
  } else if (borders.length === 4 && style !== "blueprint") {
    add("rect", { x, y, width, height, fill: "none", stroke: main, "stroke-width": strokeWidth, "stroke-dasharray": dash });
  } else {
    const sides = { top: [x - over, y, right + over, y], bottom: [x - over, bottom, right + over, bottom], left: [x, y - over, x, bottom + over], right: [right, y - over, right, bottom + over] };
    for (const side of borders) line(...sides[side], strokeWidth);
  }
  if (style !== "construction") return;
  const corners = [[x, y, 1, 1, "top", "left"], [right, y, -1, 1, "top", "right"], [x, bottom, 1, -1, "bottom", "left"], [right, bottom, -1, -1, "bottom", "right"]];
  for (const [cornerX, cornerY, signX, signY, sideY, sideX] of corners) {
    if (!isEllipse && !(borders.includes(sideY) && borders.includes(sideX))) continue;
    const d = `M${cornerX - 6 * signX} ${cornerY}H${cornerX + 10 * signX}M${cornerX} ${cornerY - 6 * signY}V${cornerY + 10 * signY}`;
    add("path", { d, stroke: main, "stroke-width": 1.5, fill: "none" });
  }
}
