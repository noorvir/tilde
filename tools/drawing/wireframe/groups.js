// Groups: components that move together. Each has its group's id in its data, as `group`. A
// component drawn fully inside another joins that one's group, and Group in the context menu
// makes one group of the selected components and of their groups; Ungroup takes every
// component out of the group. A component's own `groupIds` are Excalidraw's, one for each.

import { live, taken, changeElements } from "../scene.js";
import { record } from "./history.js";

const isComponent = (element) => Boolean(element.customData?.tildeWireframe) && !taken.has(element.id);

export const newGroup = () => `group-${Math.random().toString(36).slice(2)}`;

// The components that move with `frame`: those of its group, or itself alone.
export function membersOf(frame) {
  const { group } = frame.customData;
  if (!group) return [frame];
  return live().filter((element) => isComponent(element) && element.customData.group === group);
}

// Puts `frames` in `group`; with none, in no group.
export function setGroup(frames, group) {
  const changed = frames.filter((frame) => frame.customData.group !== group);
  changeElements(changed.map((frame) => frame.id), ({ customData: { group: _, ...data } }) => ({ customData: group ? { ...data, group } : data }));
}

// The smallest component that `rect` is fully inside, if any. A free text holds nothing.
export function outerOf(rect) {
  const holds = (outer) => rect.x >= outer.x && rect.y >= outer.y && rect.x + rect.width <= outer.x + outer.width && rect.y + rect.height <= outer.y + outer.height;
  const outers = live().filter((element) => isComponent(element) && element.customData.tildeWireframe !== "text" && holds(element));
  return outers.sort((a, b) => a.width * a.height - b.width * b.height)[0];
}

// Group has something to do: more than one component, not all in one group already.
export function canGroup(frames) {
  const [{ customData: { group } = {} } = {}] = frames;
  return frames.length > 1 && !(group && frames.every((frame) => frame.customData.group === group));
}

export function groupTogether(frames) {
  record();
  setGroup(frames.flatMap(membersOf), newGroup());
}

export function ungroup(frame) {
  record();
  setGroup(membersOf(frame));
}
