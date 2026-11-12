// The label typed in place: on the component's label tag, in the tag's own font, as wide as its
// text. Return or a click elsewhere keeps it, Esc does not.

import { api } from "../scene.js";
import { hideHandles } from "./chip.js";
import { frameOf, rebuild } from "./components.js";
import { record } from "./history.js";
import { tagTop, tagWidth } from "./look.js";

export const labelField = document.createElement("input");
labelField.id = "tilde-label";
labelField.placeholder = "Label";
labelField.style.cssText = "position:fixed;z-index:10000;box-sizing:border-box;height:15px;margin:0;padding:0 5px;border:0;border-radius:0;background:#2F7BF6;color:#fff;font:11px ui-monospace,Menlo,monospace;outline:1.5px solid #1D5BD8;caret-color:#fff;display:none";
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
  Object.assign(labelField.style, { left: `${component.x}px`, top: `${tagTop(component)}px`, display: "block" });
  labelField.value = data.label ?? "";
  sizeLabelField();
  labelField.focus();
  labelField.select();
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
let lastClick = null;

export function isDoubleClick(group) {
  const now = performance.now();
  const isDouble = lastClick?.group === group && now - lastClick.time < 400;
  lastClick = isDouble ? null : { group, time: now };
  return isDouble;
}

labelField.addEventListener("keydown", (event) => {
  if (event.key === "Enter") endLabel(true);
  if (event.key === "Escape") endLabel(false);
  event.stopPropagation();
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
