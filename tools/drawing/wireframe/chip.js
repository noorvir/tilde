// Editing a component after it is drawn. Over one, it shows as selected: with no tool a drag
// anywhere on it moves it (with a tool a drag draws in it, and its chip or grip moves it), ⌥ and
// a drag moves a copy, and a double-click edits its text. A chip above its top right moves it too:
// a click on its name changes the kind, its Borders button opens the borders, its Comment
// button its comment, its other controls set the rows and columns of a table or list or the
// fill of an ellipse, and × deletes it. A handle at each corner resizes it, and
// its opposite corner stays; a grip at the middle of its top edge moves it. Moves and resizes
// snap. Only components not sent yet can change; each change can be undone.

import { editing } from "../draw-mode.js";
import { commentBox } from "./comment.js";
import { live, changeElements } from "../scene.js";
import { rowsOf, allBorders, kindNames, frameOf, clamp } from "./components.js";
import { record } from "./history.js";
import { labelled } from "./labels.js";
import { paletteOf, setActiveTag, shownTagWidth, tagTop } from "./look.js";
import { wireframe } from "./mode.js";

const menuStyle = "position:fixed;z-index:10000;display:none;flex-direction:column;padding:4px;border-radius:10px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;user-select:none";

export const handleOutline = document.createElement("div");
handleOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:1px solid #2F76FF";
export const chip = document.createElement("div");
chip.id = "tilde-chip";
chip.dataset.wireframeHandle = "";
chip.style.cssText = "position:fixed;z-index:9999;display:none;align-items:center;gap:2px;height:22px;padding:0 4px 0 8px;border-radius:11px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif;cursor:move;user-select:none;white-space:nowrap";
// A square on each corner, with the cursor of its diagonal. Over the grip: where the two meet on
// a narrow component, the corners win.
export const corners = ["nw", "ne", "sw", "se"].map((corner) => {
  const handle = document.createElement("div");
  handle.dataset.wireframeHandle = "";
  handle.dataset.corner = corner;
  const cursor = corner === "nw" || corner === "se" ? "nwse-resize" : "nesw-resize";
  handle.style.cssText = `position:fixed;z-index:9999;display:none;width:10px;height:10px;margin:-6px 0 0 -6px;border:1.5px solid #2F76FF;border-radius:2px;background:#fff;cursor:${cursor}`;
  return handle;
});
// The grip that moves a component: a short bar in the component's colour, with square corners
// as its tag has, on the middle of its top edge.
export const grip = document.createElement("div");
grip.id = "tilde-grip";
grip.dataset.wireframeHandle = "";
grip.title = "Move";
grip.style.cssText = "position:fixed;z-index:9998;display:none;box-sizing:border-box;width:24px;height:8px;padding:2px 6px;flex-direction:column;justify-content:space-between;cursor:move";
grip.innerHTML = '<span style="height:1px;background:#fff"></span><span style="height:1px;background:#fff"></span>';
const gripSize = { width: 24, height: 8 };
export const typeMenu = document.createElement("div");
typeMenu.id = "tilde-kinds";
typeMenu.dataset.wireframeHandle = "";
typeMenu.style.cssText = menuStyle;
export const bordersMenu = document.createElement("div");
bordersMenu.id = "tilde-borders";
bordersMenu.dataset.wireframeHandle = "";
bordersMenu.setAttribute("role", "menu");
bordersMenu.style.cssText = menuStyle;
export const selectionOutline = document.createElement("div");
selectionOutline.style.cssText = "position:fixed;pointer-events:none;z-index:9997;display:none;border:2px solid #2F76FF;margin:-1px 0 0 -1px";
// The chip stands a little away from the component, clear of Technical's offset edge; a strip
// as wide as the chip fills the gap, so the pointer reaches the chip without leaving the
// component, and its handles stay.
export const chipStyle = document.createElement("style");
chipStyle.textContent = `
#tilde-chip::before { content: ""; position: absolute; left: 0; right: 0; }
#tilde-chip[data-side="below"]::before { top: -6px; height: 6px; }
#tilde-chip[data-side="above"]::before { bottom: -6px; height: 6px; }
`;
const gap = { below: 6, above: 6 };

// The component under the pointer, the component that a click selected (its handles show
// while the pointer is not over another one), and the chip's menu that is open: "kinds",
// "borders", "comment" or null.
export const selection = { hovered: null, selected: null, menu: null };

export const isHandle = (target) => Boolean(target?.closest?.("[data-wireframe-handle]"));
// The bar's symbol for each kind, as image URLs from Tilde.
let kindIcons = {};

export function setKindIcons(icons) {
  kindIcons = icons;
}

const chipButton = "display:flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 2px;border-radius:5px;cursor:pointer";

// A square with the sides that are on drawn bold.
function bordersIcon(borders, size = 16) {
  const lines = { top: "M3 3H13", right: "M13 3V13", bottom: "M3 13H13", left: "M3 3V13" };
  const sides = allBorders.map((side) => {
    const isOn = borders.includes(side);
    return `<path d="${lines[side]}" stroke="${isOn ? "#fff" : "rgba(255,255,255,.3)"}" stroke-width="${isOn ? 2.5 : 1}" stroke-linecap="round"/>`;
  }).join("");
  return `<svg width="${size}" height="${size}" viewBox="0 0 16 16" aria-hidden="true">${sides}</svg>`;
}

// The button that opens the borders, with the borders that are on.
function bordersButton(borders) {
  const isOpen = selection.menu === "borders";
  const background = isOpen ? "background:rgba(255,255,255,.2);" : "";
  return `<span data-menu="borders" role="button" aria-haspopup="menu" aria-expanded="${isOpen}" aria-label="Borders" title="Borders" style="${chipButton};${background}gap:2px;margin-left:4px;padding:0 4px">${bordersIcon(borders)}<span aria-hidden="true">▾</span></span>`;
}

// The button that opens the comment, filled while the component has one.
function commentButton(hasComment) {
  const isOpen = selection.menu === "comment";
  const background = isOpen ? "background:rgba(255,255,255,.2);" : "";
  const bubble = `<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M2.5 3.5h9v6h-5l-3 2.5v-2.5h-1z" fill="${hasComment ? "#fff" : "none"}" stroke="#fff" stroke-width="1.3" stroke-linejoin="round"/></svg>`;
  return `<span data-menu="comment" role="button" aria-label="Comment" aria-expanded="${isOpen}" title="Comment" style="${chipButton};${background}margin-left:2px">${bubble}</span>`;
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

function chipControls(frame) {
  const data = frame.customData;
  const kind = data.tildeWireframe;
  if (kind === "text") return commentButton(Boolean(data.comment));
  let controls = bordersButton(data.borders ?? []) + commentButton(Boolean(data.comment));
  if (kind === "table" || kind === "list") {
    const counts = rowsOf(kind, frame, data);
    controls += stepper("rows", counts.rows) + (kind === "table" ? stepper("columns", counts.columns) : "");
  }
  if (kind === "ellipse") controls += fillToggle(data.filled);
  return controls;
}

// All borders, then each side, each on or off.
function borderItems(borders) {
  const rows = [
    { action: "border:all", name: "All borders", isOn: borders.length === 4, icon: bordersIcon(borders.length === 4 ? allBorders : [], 14) },
    ...allBorders.map((side) => ({
      action: `border:${side}`, name: `${side[0].toUpperCase()}${side.slice(1)}`, isOn: borders.includes(side), icon: bordersIcon([side], 14),
    })),
  ];
  const items = rows.map(({ action, name, isOn, icon }) => {
    const check = `<span aria-hidden="true" style="width:12px;margin-left:auto;text-align:right">${isOn ? "✓" : ""}</span>`;
    return `<span data-action="${action}" role="menuitemcheckbox" aria-checked="${isOn}" style="display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:6px;cursor:pointer;min-width:116px">${icon}${name}${check}</span>`;
  });
  const separator = `<span role="separator" style="height:1px;margin:3px 6px;background:rgba(255,255,255,.14)"></span>`;
  return [items[0], separator, ...items.slice(1)].join("");
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

// A press on a chip's button that opens a menu: it opens that menu, or closes it when it is open.
export function toggleMenu(menu) {
  selection.menu = selection.menu === menu ? null : menu;
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
  // A free text has no size of its own to change, and moves by a drag on it.
  const isFreeText = frame?.customData.tildeWireframe === "text";
  setActiveTag(isShown && selection.hovered ? selection.hovered : null);
  handleOutline.style.display = isShown ? "block" : "none";
  chip.style.display = isShown ? "flex" : "none";
  for (const handle of corners) handle.style.display = isShown && !isFreeText ? "block" : "none";
  grip.style.display = isShown && !isFreeText ? "flex" : "none";
  typeMenu.style.display = isShown && selection.menu === "kinds" ? "flex" : "none";
  bordersMenu.style.display = isShown && selection.menu === "borders" ? "flex" : "none";
  if (!isShown) return;
  const kind = frame.customData.tildeWireframe;
  Object.assign(handleOutline.style, { left: `${frame.x}px`, top: `${frame.y}px`, width: `${frame.width}px`, height: `${frame.height}px` });
  for (const handle of corners) {
    const { corner } = handle.dataset;
    const x = corner.includes("w") ? frame.x : frame.x + frame.width;
    const y = corner.includes("n") ? frame.y : frame.y + frame.height;
    Object.assign(handle.style, { left: `${x}px`, top: `${y}px` });
  }
  let name = `<span data-menu="kinds" title="Change the kind" style="margin-right:4px">⠿ ${kindNames[kind]} ▾</span>`;
  if (isFreeText) name = `<span style="margin-right:4px">⠿ Text</span>`;
  const content = `${name}${chipControls(frame)}${deleteButton}`;
  if (chip.innerHTML !== content) chip.innerHTML = content;
  placeChip(frame);
  placeGrip(frame);

  if (selection.menu === "kinds") {
    // The bar's kinds; an older note's kind stays in the list while it has it.
    const items = Object.entries(kindNames).filter(([value]) => kindIcons[value] || value === kind).map(([value, name]) => {
      const background = value === kind ? "background:rgba(255,255,255,.2);" : "";
      const icon = kindIcons[value] ? `<img src="${kindIcons[value]}" style="max-width:16px;max-height:14px;pointer-events:none">` : "";
      const iconSlot = `<span style="display:flex;justify-content:center;width:18px">${icon}</span>`;
      return `<span data-kind="${value}" style="${background}display:flex;align-items:center;gap:8px;padding:5px 12px 5px 8px;border-radius:6px;cursor:pointer">${iconSlot}${name}</span>`;
    }).join("");
    if (typeMenu.innerHTML !== items) typeMenu.innerHTML = items;
    placeMenu(typeMenu, chip.querySelector("[data-menu=kinds]"));
  }
  if (selection.menu === "borders") {
    const items = borderItems(frame.customData.borders ?? []);
    if (bordersMenu.innerHTML !== items) bordersMenu.innerHTML = items;
    placeMenu(bordersMenu, chip.querySelector("[data-menu=borders]"));
  }
  if (selection.menu === "comment") placeMenu(commentBox, chip.querySelector("[data-menu=comment]"));
}

// The chip goes just above the component, right-aligned with its right edge, and never over
// the label's tag; where it would leave the screen at the top, just below it. It stays on the
// screen.
function placeChip(frame) {
  const { width, height } = chip.getBoundingClientRect();
  let side = "above";
  const left = Math.max(frame.x + frame.width - width, frame.x + shownTagWidth(frame) + 4);
  let top = frame.y - gap.above - height;
  if (top < 0) {
    side = "below";
    top = frame.y + frame.height + gap.below;
  }
  chip.dataset.side = side;
  Object.assign(chip.style, {
    left: `${clamp(left, 0, window.innerWidth - width)}px`,
    top: `${clamp(top, 0, window.innerHeight - height)}px`,
  });
}

// The grip sits on the top edge, at its middle, from 2 points above it, where the tag and a chip
// above the component end, so it never covers them. A tag inside the component, at the top of
// the screen, pushes it right, or under the tag where there is no room.
function placeGrip(frame) {
  grip.style.background = paletteOf(frame.customData.tildeWireframe).main;
  let left = frame.x + frame.width / 2 - gripSize.width / 2;
  let top = frame.y - 2;
  const tag = { left: frame.x, right: frame.x + shownTagWidth(frame), top: tagTop(frame), bottom: tagTop(frame) + 15 };
  const isOverTag = (x, y) => x < tag.right && x + gripSize.width > tag.left && y < tag.bottom && y + gripSize.height > tag.top;
  if (isOverTag(left, top)) {
    const afterTag = tag.right + 4;
    if (afterTag + gripSize.width <= frame.x + frame.width - 8) left = afterTag;
    else top = tag.bottom + 2;
  }
  Object.assign(grip.style, { left: `${left}px`, top: `${top}px` });
}

// A chip's menu opens under its button, or over it where there is no room under it, and stays
// on the screen.
function placeMenu(menu, button) {
  const box = button.getBoundingClientRect();
  const { width, height } = menu.getBoundingClientRect();
  let top = box.bottom + 6;
  if (top + height > window.innerHeight) top = box.top - 6 - height;
  Object.assign(menu.style, {
    left: `${clamp(box.left, 0, window.innerWidth - width)}px`,
    top: `${clamp(top, 0, window.innerHeight - height)}px`,
  });
}

export function hideHandles() {
  selection.hovered = null;
  selection.menu = null;
  showHandles();
}
