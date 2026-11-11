// Editing a component after it is drawn. Over one, it shows as selected: a drag anywhere on it
// moves it (a section only by its chip: a drag on a section draws in it), ⌥ and a drag moves a
// copy, and a double-click edits its label. A chip at its top left moves it too; a click on its
// name changes the kind, and its controls set the borders, the rows and columns of a table or
// list, the fill of a rectangle or ellipse, or delete it. A handle at its bottom right resizes it. Moves
// and resizes snap. Only components not sent yet can change; each change can be undone.

import { editing } from "../draw-mode.js";
import { live, changeElements } from "../scene.js";
import { rowsOf, allBorders, kindNames, frameOf } from "./components.js";
import { record } from "./history.js";
import { labelled } from "./labels.js";
import { wireframe } from "./mode.js";

export const handleOutline = document.createElement("div");
handleOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:1px solid #2F76FF";
export const chip = document.createElement("div");
chip.dataset.wireframeHandle = "";
chip.style.cssText = "position:fixed;z-index:9999;display:none;align-items:center;gap:2px;height:22px;padding:0 4px 0 8px;border-radius:11px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;cursor:move;user-select:none;white-space:nowrap";
export const resizer = document.createElement("div");
resizer.dataset.wireframeHandle = "";
resizer.style.cssText = "position:fixed;z-index:9999;display:none;width:10px;height:10px;margin:-6px 0 0 -6px;border:1.5px solid #2F76FF;border-radius:2px;background:#fff;cursor:nwse-resize";
export const typeMenu = document.createElement("div");
typeMenu.dataset.wireframeHandle = "";
typeMenu.style.cssText = "position:fixed;z-index:10000;display:none;flex-direction:column;padding:4px;border-radius:10px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;user-select:none";
export const selectionOutline = document.createElement("div");
selectionOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:2px solid #2F76FF;margin:-1px 0 0 -1px";
// The component under the pointer, the component that a click selected (its handles show
// while the pointer is not over another one), and whether the kinds show.
export const selection = { hovered: null, selected: null, isMenuOpen: false };

export const isHandle = (target) => Boolean(target?.closest?.("[data-wireframe-handle]"));
// The bar's symbol for each kind, as image URLs from Tilde.
let kindIcons = {};

export function setKindIcons(icons) {
  kindIcons = icons;
}

const chipButton = "display:flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 2px;border-radius:5px;cursor:pointer";

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

export function deleteComponent(group) {
  record();
  changeElements(live().filter((element) => element.groupIds.includes(group)).map((element) => element.id), () => ({ isDeleted: true }));
  hideHandles();
}

export function selectGroup(group) {
  selection.selected = group;
  showHandles();
}

export function showHandles() {
  const selected = selection.selected ? frameOf(selection.selected) : null;
  const isSelectionShown = Boolean(selected && wireframe && !labelled && !editing);
  selectionOutline.style.display = isSelectionShown ? "block" : "none";
  if (isSelectionShown) {
    Object.assign(selectionOutline.style, { left: `${selected.x}px`, top: `${selected.y}px`, width: `${selected.width}px`, height: `${selected.height}px` });
  }
  const group = selection.hovered ?? selection.selected;
  const frame = group ? frameOf(group) : null;
  const isShown = Boolean(frame && wireframe && !labelled && !editing);
  handleOutline.style.display = isShown ? "block" : "none";
  chip.style.display = isShown ? "flex" : "none";
  resizer.style.display = isShown ? "block" : "none";
  typeMenu.style.display = isShown && selection.isMenuOpen ? "flex" : "none";
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

export function hideHandles() {
  selection.hovered = null;
  selection.isMenuOpen = false;
  showHandles();
}
