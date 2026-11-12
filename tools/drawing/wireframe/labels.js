// The label typed in place: at the centre of the component, in the label's own font and size,
// as wide as its text, on the label's chip where the component has one. Return or a click
// elsewhere keeps it, Esc does not.

import { api } from "../scene.js";
import { hideHandles } from "./chip.js";
import { skeleton, clamp, plainLabels, frameOf, rebuild } from "./components.js";
import { record } from "./history.js";

export const labelField = document.createElement("input");
labelField.id = "tilde-label";
labelField.placeholder = "Label";
labelField.style.cssText = "position:fixed;z-index:10000;transform:translate(-50%,-50%);box-sizing:content-box;margin:0;color:#4A4D55;font-family:Helvetica,sans-serif;text-align:center;outline:none;caret-color:#2F76FF;display:none";
export const labelStyle = document.createElement("style");
labelStyle.textContent = "#tilde-label::placeholder { color: #A9ADB5; } [data-kind]:hover, [data-action]:hover { background: rgba(255,255,255,.14); }";
const measure = document.createElement("canvas").getContext("2d");
// { group, label } of the component whose label is typed.
export let labelled = null;
let labelBefore = null;

function sizeLabelField() {
  measure.font = `${labelField.style.fontSize} Helvetica, sans-serif`;
  labelField.style.width = `${Math.ceil(measure.measureText(labelField.value || labelField.placeholder).width) + 2}px`;
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
  const isPlain = plainLabels.has(data.tildeWireframe);
  Object.assign(labelField.style, {
    left: `${component.x + component.width / 2}px`, top: `${component.y + component.height / 2}px`,
    fontSize: `${isPlain ? clamp(component.height * 0.32, 12, 20) : 15}px`, padding: isPlain ? "0" : "5px 10px",
    background: isPlain ? "transparent" : "#fff", border: isPlain ? "0" : `1px solid ${skeleton.line}`, borderRadius: "6px", display: "block",
  });
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
