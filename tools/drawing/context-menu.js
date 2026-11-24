// Tilde's context menu on the canvas, in place of Excalidraw's: Add comment, in wireframe mode
// Group and Ungroup, then the Excalidraw actions that Tilde keeps. Excalidraw's own menu opens hidden; an item here clicks
// its item there, so each action runs as Excalidraw runs it.

import { deleteSelected, hasGroup } from "./draw-mode.js";
import { api, post } from "./scene.js";
import { deleteComponent, selectedFrames, showHandles, trashIcon } from "./wireframe/chip.js";
import { componentAt } from "./wireframe/components.js";
import { canGroup, groupTogether, ungroup } from "./wireframe/groups.js";
import { wireframe } from "./wireframe/mode.js";
import { openComponentComment } from "./wireframe/pointer.js";

const icons = {
  comment: '<path d="M3 3.5h10v7.5H7.5L4.5 14v-3H3z"/>',
  cut: '<circle cx="4.5" cy="11.5" r="2"/><circle cx="11.5" cy="11.5" r="2"/><path d="M6 10 12 2M10 10 4 2"/>',
  copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M3 10.5v-7a1 1 0 0 1 1-1h6.5"/>',
  paste: '<rect x="3" y="3" width="10" height="11" rx="1.5"/><path d="M6 1.8h4v2.4H6z"/>',
  image: '<rect x="2.5" y="3" width="11" height="10" rx="1.5"/><circle cx="6" cy="6.5" r="1.2"/><path d="m3 12 3.5-3.5 2.5 2.5 2-2 2.5 2.5"/>',
  code: '<path d="M6 4 2.5 8 6 12M10 4l3.5 4-3.5 4"/>',
  forward: '<path d="M8 13V4M4.5 7.5 8 4l3.5 3.5"/>',
  backward: '<path d="M8 3v9M4.5 8.5 8 12l3.5-3.5"/>',
  front: '<path d="M3 2.5h10M8 14V6M4.5 9.5 8 6l3.5 3.5"/>',
  back: '<path d="M3 13.5h10M8 2v8M4.5 6.5 8 10l3.5-3.5"/>',
  flipH: '<path d="M8 2v12M6 4.5 2.5 12H6zM10 4.5l3.5 7.5H10z"/>',
  flipV: '<path d="M2 8h12M4.5 6 12 2.5V6zM4.5 10l7.5 3.5V10z"/>',
  duplicate: '<rect x="2.5" y="2.5" width="8" height="8" rx="1.5"/><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/>',
  trash: trashIcon,
  group: '<rect x="2.5" y="2.5" width="11" height="11" rx="1.5"/><rect x="5" y="5" width="3" height="3"/><rect x="8" y="8" width="3" height="3"/>',
  ungroup: '<rect x="2.5" y="2.5" width="11" height="11" rx="1.5" stroke-dasharray="2 2"/><rect x="5" y="5" width="3" height="3"/><rect x="8" y="8" width="3" height="3"/>',
};

// Excalidraw's actions that Tilde keeps, by its name for each, in groups.
const kept = [
  [["cut", "Cut", "cut"], ["copy", "Copy", "copy"], ["paste", "Paste", "paste"]],
  [["copyAsPng", "Copy as PNG", "image"], ["copyAsSvg", "Copy as SVG", "code"]],
  [["bringForward", "Bring forward", "forward"], ["sendBackward", "Send backward", "backward"], ["bringToFront", "Bring to front", "front"], ["sendToBack", "Send to back", "back"]],
  [["flipHorizontal", "Flip horizontal", "flipH"], ["flipVertical", "Flip vertical", "flipV"]],
  [["duplicateSelection", "Duplicate", "duplicate"], ["deleteSelectedElements", "Delete", "trash"]],
];

export const contextMenu = document.createElement("div");
contextMenu.id = "tilde-context-menu";
contextMenu.style.cssText = "position:fixed;z-index:10001;display:none;flex-direction:column;min-width:200px;padding:4px;border-radius:10px;background:rgba(26,26,26,.96);color:#fff;font:500 12px -apple-system,sans-serif;user-select:none;box-shadow:0 6px 24px rgba(0,0,0,.3)";

export const contextMenuStyle = document.createElement("style");
contextMenuStyle.textContent = `
.popover:has(.context-menu) { visibility: hidden !important; }
#tilde-context-menu [data-item] { display: flex; align-items: center; gap: 8px; padding: 5px 10px 5px 8px; border-radius: 6px; cursor: default; }
#tilde-context-menu [data-item]:hover { background: rgba(255,255,255,.14); }
#tilde-context-menu svg { width: 14px; height: 14px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.3; stroke-linecap: round; stroke-linejoin: round; }
#tilde-context-menu kbd { margin-left: auto; padding-left: 16px; color: rgba(255,255,255,.5); font: 500 11px -apple-system,sans-serif; }
#tilde-context-menu hr { width: 100%; margin: 4px 0; border: 0; border-top: 1px solid rgba(255,255,255,.12); }
`;

let isOpen = false;
// Where the menu opened: Add comment there is for the component under it.
let openedAt = null;

// Excalidraw's shortcut text, as macOS writes it.
function macShortcut(text) {
  if (text === "Delete") return "⌫";
  const symbols = { Cmd: "⌘", Shift: "⇧", Option: "⌥", Alt: "⌥", Ctrl: "⌃" };
  return text.split("+").map((part) => symbols[part] ?? part).join("");
}

function item(name, label, icon, shortcut) {
  const keys = shortcut ? `<kbd>${shortcut}</kbd>` : "";
  return `<div data-item="${name}"><svg viewBox="0 0 16 16">${icons[icon]}</svg><span>${label}</span>${keys}</div>`;
}

const componentHere = () => componentAt(openedAt.x, openedAt.y);

function canComment() {
  if (wireframe) return Boolean(componentHere());
  return hasGroup;
}

// The selected components, when the menu opened on one of them and Group has something to do.
function groupable() {
  const here = wireframe && componentHere();
  const frames = selectedFrames();
  return here && frames.some((frame) => frame.id === here.id) && canGroup(frames) ? frames : null;
}

// Group for a selection of several components, and Ungroup for a component in a group.
function groupItems() {
  const items = [];
  if (groupable()) items.push(item("group", "Group", "group"));
  if (wireframe && componentHere()?.customData.group) items.push(item("ungroup", "Ungroup", "ungroup"));
  return items;
}

// After Excalidraw has opened its menu, Tilde's shows the same actions that it keeps.
export function contextMenuRequested(event) {
  openedAt = { x: event.clientX, y: event.clientY };
  requestAnimationFrame(() => {
    const shown = new Map([...document.querySelectorAll(".excalidraw .context-menu li[data-testid]")].map((entry) => [
      entry.dataset.testid, entry.querySelector(".context-menu-item__shortcut")?.textContent ?? "",
    ]));
    // Delete in wireframe mode is for the component under the pointer.
    if (wireframe) {
      shown.delete("deleteSelectedElements");
      if (componentHere()) shown.set("deleteSelectedElements", "Delete");
    }
    const groups = kept
      .map((group) => group.filter(([name]) => shown.has(name)).map(([name, label, icon]) => item(name, label, icon, macShortcut(shown.get(name)))))
      .filter((group) => group.length);
    const grouping = groupItems();
    if (grouping.length) groups.unshift(grouping);
    if (canComment()) groups.unshift([item("addComment", "Add comment", "comment", "↩")]);
    if (!groups.length) return;
    contextMenu.innerHTML = groups.map((group) => group.join("")).join("<hr>");
    contextMenu.style.display = "flex";
    const { width, height } = contextMenu.getBoundingClientRect();
    contextMenu.style.left = `${Math.min(openedAt.x, window.innerWidth - width - 4)}px`;
    contextMenu.style.top = `${Math.min(openedAt.y, window.innerHeight - height - 4)}px`;
    isOpen = true;
    // Tilde's keys wait while the menu is open: Esc closes it.
    post("typing");
  });
}

// A click outside the page, such as on the HUD, closes the menu: else its keys would wait.
window.addEventListener("blur", () => close());

function close() {
  if (!isOpen) return;
  isOpen = false;
  contextMenu.style.display = "none";
  // Excalidraw's own menu, hidden under Tilde's, closes too: else it takes the next click.
  api.updateScene({ appState: { contextMenu: null }, captureUpdate: "NEVER" });
  post("notTyping");
}

// The items that Tilde runs itself.
const ownItems = new Set(["deleteSelectedElements", "addComment", "group", "ungroup"]);

function run(name) {
  // Excalidraw's item runs while its menu is still there; closing Tilde's then closes that one.
  if (!ownItems.has(name)) {
    document.querySelector(`.excalidraw .context-menu li[data-testid="${name}"]`)?.click();
    close();
    return;
  }
  close();
  if (name === "group" || name === "ungroup") {
    const frames = groupable();
    const component = wireframe && componentHere();
    if (name === "group" && frames) groupTogether(frames);
    if (name === "ungroup" && component) ungroup(component);
    showHandles();
    return;
  }
  if (name === "deleteSelectedElements") {
    const component = wireframe && componentHere();
    if (component) deleteComponent(component.groupIds[0]);
    else if (!wireframe) deleteSelected();
    return;
  }
  if (!wireframe) {
    post("addComment");
    return;
  }
  const component = componentHere();
  if (component) openComponentComment(component.groupIds[0]);
}

// Before every other listener: a press in the menu is for it alone, one outside closes it.
export function contextMenuPointer(event) {
  if (!isOpen) return;
  if (!contextMenu.contains(event.target)) {
    if (event.type === "pointerdown") close();
    return;
  }
  event.stopImmediatePropagation();
  event.preventDefault();
  const name = event.target.closest("[data-item]")?.dataset.item;
  if (event.type === "pointerup" && name) run(name);
}

export function contextMenuKey(event) {
  if (!isOpen || event.key !== "Escape") return;
  event.stopImmediatePropagation();
  event.preventDefault();
  close();
}
