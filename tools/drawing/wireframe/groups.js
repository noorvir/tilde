// Groups: a parent component and its children, which have the parent's `key` in their data as
// `parent`. A component drawn fully inside another is its child, and Group in the context menu
// makes the selected components children of the one under the pointer. A parent moves with
// its children and theirs, and is deleted with them; a child moves and is deleted alone.
// Ungroup takes a component from its parent and its own children from it.

import { live, taken, changeElements } from "../scene.js";
import { record } from "./history.js";

const isComponent = (element) => Boolean(element.customData?.tildeWireframe) && !taken.has(element.id);
const components = () => live().filter(isComponent);

export const newKey = () => `component-${Math.random().toString(36).slice(2)}`;

export function childrenOf(frame) {
  const { key } = frame.customData;
  return key ? components().filter((element) => element.customData.parent === key) : [];
}

// The children of `frame`, and theirs: what moves and goes with it.
export function descendantsOf(frame) {
  return childrenOf(frame).flatMap((child) => [child, ...descendantsOf(child)]);
}

function changeData(frames, change) {
  changeElements(frames.map((frame) => frame.id), (element) => ({ customData: change(element.customData) }));
}

// A parent's key, which its children have.
export function setKey(frame, key) {
  if (frame.customData.key !== key) changeData([frame], (data) => ({ ...data, key }));
}

// Makes `frames` children of the component with `key`; with none, of no component.
function setParent(frames, key) {
  const changed = frames.filter((frame) => frame.customData.parent !== key);
  changeData(changed, ({ parent: _, ...data }) => (key ? { ...data, parent: key } : data));
}

// The smallest component that `rect` is fully inside, if any. A free text holds nothing.
export function outerOf(rect) {
  const holds = (outer) => rect.x >= outer.x && rect.y >= outer.y && rect.x + rect.width <= outer.x + outer.width && rect.y + rect.height <= outer.y + outer.height;
  const outers = components().filter((element) => element.customData.tildeWireframe !== "text" && holds(element));
  return outers.sort((a, b) => a.width * a.height - b.width * b.height)[0];
}

// Group has something to do: one of `frames` is not a child of `parent` yet.
export function canGroup(parent, frames) {
  const { key } = parent.customData;
  return frames.some((frame) => frame.id !== parent.id && (!key || frame.customData.parent !== key));
}

// The other components of `frames` become children of `parent`. One of them that `parent` was
// in no longer has it: no component is in itself.
export function groupUnder(parent, frames) {
  record();
  const key = parent.customData.key ?? newKey();
  const children = frames.filter((frame) => frame.id !== parent.id);
  setKey(parent, key);
  if (children.some((child) => descendantsOf(child).some((inner) => inner.id === parent.id))) setParent([parent]);
  setParent(children, key);
}

export const canUngroup = (frame) => Boolean(frame.customData.parent) || childrenOf(frame).length > 0;

export function ungroup(frame) {
  record();
  setParent([frame, ...childrenOf(frame)]);
}
