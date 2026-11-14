// The label typed in place: on the component's label tag, in the tag's own font, as wide as its
// text. Return or a click elsewhere keeps it, Esc does not.

import { api } from "../scene.js";
import { hideHandles } from "./chip.js";
import { frameOf, rebuild } from "./components.js";
import { record } from "./history.js";
import { paletteOf, tagTop, tagWidth } from "./look.js";

export const labelField = document.createElement("input");
labelField.id = "tilde-label";
labelField.placeholder = "Add label";
labelField.style.cssText = "position:fixed;z-index:10000;box-sizing:border-box;height:15px;margin:0;padding:0 5px;border:0;border-radius:0;color:#fff;font:11px ui-monospace,Menlo,monospace;caret-color:#fff;display:none";
export const labelStyle = document.createElement("style");
labelStyle.textContent = "#tilde-label::placeholder { color: rgba(255,255,255,.7); } [data-kind]:hover, [data-action]:hover { background: rgba(255,255,255,.14); }";
// { group, label } of the component whose label is typed.
export let labelled = null;
let labelBefore = null;

// As wide as the tag of the same text.
function sizeLabelField() {
  labelField.style.width = `${tagWidth(labelField.value || labelField.placeholder)}px`;
}
labelField.addEventListener("input", sizeLabelField);

export function editLabel(component) {
  const data = component.customData;
  const group = component.groupIds[0];
  labelBefore = api.getSceneElementsIncludingDeleted();
  labelled = { group, label: data.label };
  hideHandles();
  // The component without its label meanwhile: the field shows it in its place.
  rebuild(group, component, { ...data, label: undefined, isLabelling: true });
  // In the colours of the tag it stands in for.
  const { main, dark } = paletteOf(data.tildeWireframe);
  Object.assign(labelField.style, { left: `${component.x}px`, top: `${tagTop(component)}px`, background: main, outline: `1.5px solid ${dark}`, display: "block" });
  labelField.value = data.label ?? "";
  sizeLabelField();
  // After the press that opened it: the press itself moves the focus when it ends.
  setTimeout(() => {
    if (!labelled) return;
    labelField.focus();
    labelField.select();
  }, 0);
}

export function endLabel(isKept) {
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

// The window moved under a label that is typed: the field, and the scene that Undo goes back
// to, go with it. `shift` moves a scene.
export function moveLabel(dx, dy, shift) {
  if (labelBefore) labelBefore = shift(labelBefore);
  if (!labelled) return;
  labelField.style.left = `${parseFloat(labelField.style.left) + dx}px`;
  labelField.style.top = `${parseFloat(labelField.style.top) + dy}px`;
}
