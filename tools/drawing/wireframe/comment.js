// A component's comment: optional, one for each component, typed in a box that its chip's
// Comment button opens, and sent with the component to the agent. ⌘Return or a click elsewhere
// keeps it; Esc closes only the box, and keeps the comment as it was.

import { frameOf, rebuild } from "./components.js";
import { record } from "./history.js";

export const commentBox = document.createElement("div");
commentBox.id = "tilde-comment";
commentBox.dataset.wireframeHandle = "";
commentBox.style.cssText = "position:fixed;z-index:10000;display:none;flex-direction:column;gap:6px;width:260px;padding:8px;border-radius:10px;background:rgba(26,26,26,.96);color:#fff;font:600 11px -apple-system,sans-serif";
export const commentField = document.createElement("textarea");
commentField.id = "tilde-comment-field";
commentField.placeholder = "Add a comment…";
commentField.rows = 3;
commentField.setAttribute("aria-label", "Comment");
commentField.style.cssText = "box-sizing:border-box;width:100%;margin:0;padding:6px 8px;border:1px solid rgba(255,255,255,.18);border-radius:6px;background:rgba(255,255,255,.08);color:#fff;font:400 12px -apple-system,sans-serif;resize:none;outline:none";
const hint = document.createElement("span");
hint.textContent = "⌘↩ keeps it · Esc closes";
hint.style.cssText = "color:rgba(255,255,255,.55);font-weight:500";
commentBox.append(commentField, hint);

// The group of the component whose comment is typed.
export let commented = null;
let onClose = () => {};

// Opens the box for a component; `closed` runs once it closes.
export function openComment(frame, closed) {
  commented = frame.groupIds[0];
  onClose = closed;
  commentField.value = frame.customData.comment ?? "";
  commentBox.style.display = "flex";
  commentField.focus();
}

export function closeComment(isKept) {
  const group = commented;
  commented = null;
  commentBox.style.display = "none";
  commentField.blur();
  const frame = group && frameOf(group);
  if (frame) {
    const comment = commentField.value.trim() || undefined;
    if (isKept && comment !== frame.customData.comment) {
      record();
      rebuild(group, frame, { ...frame.customData, comment });
    }
  }
  onClose();
}

commentField.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.metaKey) closeComment(true);
  if (event.key === "Escape") closeComment(false);
  event.stopPropagation();
});
commentField.addEventListener("blur", () => {
  if (commented) closeComment(true);
});
