// The label and the text typed in place. A label on the component's label tag, in the tag's own
// font, as wide as its text; a text where it shows, on the component or free, in its own font.
// Return or a click elsewhere keeps it, Esc does not.

import { api } from "../scene.js";
import { hideHandles } from "./chip.js";
import { frameOf, rebuild } from "./components.js";
import { record } from "./history.js";
import { paletteOf, tagTop, tagWidth, textCentre, textHeight, textWidth } from "./look.js";

export const labelField = document.createElement("input");
labelField.id = "tilde-label";
labelField.style.cssText = "position:fixed;z-index:10000;box-sizing:border-box;margin:0;border:0;border-radius:0;display:none";
const fieldStyles = {
  label: { height: "15px", padding: "0 5px", color: "#fff", caretColor: "#fff", font: "11px ui-monospace,Menlo,monospace" },
  text: { height: `${textHeight + 2}px`, padding: "0 4px", color: "", caretColor: "", font: "13px -apple-system,system-ui,sans-serif" },
};
export const labelStyle = document.createElement("style");
labelStyle.textContent = "#tilde-label[data-key=label]::placeholder { color: rgba(255,255,255,.7); } [data-kind]:hover, [data-action]:hover { background: rgba(255,255,255,.14); }";
// What is typed: { group, key, value, isNew }. `key` is "label" or "text"; `value` is the one
// before; `isNew`: a free text that the typing made, which goes if it ends empty.
export let labelled = null;
let labelBefore = null;
// Where the field is: its left edge, or the middle of a text on a component.
let anchor = null;

// A label's field is as wide as the tag of the same text, a text's as the text.
function sizeLabelField() {
  const text = labelField.value || labelField.placeholder;
  const width = labelled?.key === "label" ? tagWidth(text) : textWidth(text) + 10;
  labelField.style.width = `${width}px`;
  labelField.style.left = `${anchor.isCentred ? anchor.x - width / 2 : anchor.x}px`;
}
labelField.addEventListener("input", sizeLabelField);

export function editLabel(component) {
  const { main, dark } = paletteOf(component.customData.tildeWireframe);
  // In the colours of the tag it stands in for.
  openField(component, "label", { x: component.x, y: tagTop(component), isCentred: false }, { background: main, outline: `1.5px solid ${dark}` });
}

// A component's text, or a free text's. `scene`: the scene before a new free text was made,
// which Undo goes back to.
export function editText(component, scene = null) {
  const isFree = component.customData.tildeWireframe === "text";
  const { main, dark } = paletteOf(component.customData.tildeWireframe);
  let place = { x: component.x - 2, y: component.y - 1, isCentred: false };
  if (!isFree) {
    const centre = textCentre(component);
    place = { x: centre.x, y: centre.y - textHeight / 2 - 1, isCentred: true };
  }
  openField(component, "text", place, { background: "#fff", color: dark, caretColor: dark, outline: `1.5px solid ${main}` }, scene);
}

function openField(component, key, place, colours, scene = null) {
  const data = component.customData;
  const group = component.groupIds[0];
  labelBefore = scene ?? api.getSceneElementsIncludingDeleted();
  labelled = { group, key, value: data[key], isNew: Boolean(scene) };
  anchor = place;
  hideHandles();
  // The component without what is typed meanwhile: the field shows it in its place.
  rebuild(group, component, { ...data, typing: key });
  labelField.dataset.key = key;
  labelField.placeholder = key === "label" ? "Add label" : "Add text";
  Object.assign(labelField.style, fieldStyles[key], { top: `${place.y}px`, ...colours, display: "block" });
  labelField.value = data[key] ?? "";
  sizeLabelField();
  // After the press that opened it: the press itself moves the focus when it ends.
  setTimeout(() => {
    if (!labelled) return;
    labelField.focus();
    labelField.select();
  }, 0);
}

export function endLabel(isKept) {
  const typed = labelled;
  labelled = null;
  labelField.style.display = "none";
  labelField.blur();
  const frame = typed && frameOf(typed.group);
  if (!frame) return;
  const value = isKept ? labelField.value.trim() || undefined : typed.value;
  const data = { ...frame.customData, [typed.key]: value, typing: undefined };
  const isFree = data.tildeWireframe === "text";
  // A free text with no text goes.
  if (isFree && !value) {
    api.updateScene({ elements: api.getSceneElementsIncludingDeleted().filter((element) => !element.groupIds.includes(typed.group)), captureUpdate: "NEVER" });
    if (!typed.isNew) record(labelBefore);
    return;
  }
  const rect = isFree ? { x: frame.x, y: frame.y, width: textWidth(value) + 4, height: textHeight } : frame;
  rebuild(typed.group, rect, data);
  if (value !== typed.value) record(labelBefore);
}

// The second click on a component within 400 ms is a double-click, which edits its text.
// `time` is the press's own time, as the event has it: a slow page can finish two clicks
// further apart than they were pressed.
let lastClick = null;

export function isDoubleClick(group, time) {
  const isDouble = lastClick?.group === group && time - lastClick.time < 400;
  lastClick = isDouble ? null : { group, time };
  return isDouble;
}

// Enter and Esc are the field's: marked as used, they go no further, to Tilde or to macOS.
labelField.addEventListener("keydown", (event) => {
  event.stopPropagation();
  if (event.key !== "Enter" && event.key !== "Escape") return;
  event.preventDefault();
  endLabel(event.key === "Enter");
});
labelField.addEventListener("blur", () => {
  if (labelled) endLabel(true);
});

// The window moved under what is typed: the field, and the scene that Undo goes back to, go
// with it. `shift` moves a scene.
export function moveLabel(dx, dy, shift) {
  if (labelBefore) labelBefore = shift(labelBefore);
  if (!labelled) return;
  anchor = { ...anchor, x: anchor.x + dx, y: anchor.y + dy };
  labelField.style.top = `${anchor.y}px`;
  sizeLabelField();
}
