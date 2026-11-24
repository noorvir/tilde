// A still picture of components for Tilde's Settings, drawn by the same code as the canvas:
// the scene becomes `shapes` (as a note's report has them, from the top left of the page) in
// `look`, and the first of them shows `state`: "normal", "hovered", "selected" (with its chip),
// "several" (selected with the two after it), "borders" (with its borders menu open) or
// "dragging" (with the guides it snaps to).
// `background`: the screen under the components, as Tilde blurs it, `size` points large; the
// promise settles once it shows.

import { api } from "../scene.js";
import { selection, showHandles } from "./chip.js";
import { frameOf } from "./components.js";
import { drawLook, setWireframeLook } from "./look.js";
import { setWireframe, restoreWireframe } from "./mode.js";
import { hideGuides, showGuides } from "./snap.js";

const background = document.createElement("img");
background.style.cssText = "position:fixed;left:0;top:0;z-index:1;pointer-events:none";

export async function showPreview({ look, shapes, state, background: url, size: [width, height] }) {
  setWireframe({ tool: "", icons: {} });
  api.updateScene({ elements: [], captureUpdate: "NEVER" });
  setWireframeLook(look);
  restoreWireframe({ shapes, origin: [0, 0] });
  const [first, ...rest] = api.getSceneElements().filter((element) => element.customData?.tildeWireframe);
  const group = first?.groupIds[0] ?? null;
  const frame = group ? frameOf(group) : null;

  selection.menu = state === "borders" ? "borders" : null;
  selection.hovered = state === "hovered" || state === "dragging" ? group : null;
  selection.selected = state === "selected" || state === "several" || state === "borders" ? group : null;
  selection.more = state === "several" ? rest.slice(0, 2).map((element) => element.groupIds[0]) : [];
  hideGuides();
  if (state === "dragging" && frame) {
    const corner = { x: frame.x, y: frame.y };
    showGuides({ value: frame.x, own: true }, { value: frame.y }, corner);
  }
  showHandles();
  drawLook();

  const next = new Image();
  next.src = url;
  await next.decode();
  Object.assign(background.style, { width: `${width}px`, height: `${height}px` });
  background.src = url;
  if (!background.isConnected) document.body.prepend(background);
}
