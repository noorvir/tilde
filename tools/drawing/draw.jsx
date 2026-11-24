// The drawing canvas: Excalidraw with its own interface hidden, driven from Tilde's HUD.
// Build it with tools/drawing/build.sh.
//
// The modules, each with one job:
//   scene.js                 the Excalidraw scene, and what the page posts to Tilde
//   bridge.js                what Tilde calls (window.tildeDraw), and the keys Tilde must know of
//   cursor.js, rings.js      the cursor on the canvas and the rings at the pointer
//   draw-mode.js             Draw mode
//   wireframe/mode.js        wireframe mode on and off, a note's components shown again, its keys
//   wireframe/components.js  what a component is: its kinds and its data
//   wireframe/look.js        what a component looks like, in the style of Tilde's settings
//   wireframe/preview.js     still pictures of components in each state, for Tilde's Settings
//   wireframe/pointer.js     drawing, moving, resizing and copying with the pointer
//   wireframe/chip.js        a component's handles: the chip, its kinds and borders, the corners and the grip
//   wireframe/labels.js      a label or a text typed in place
//   wireframe/comment.js     a component's comment
//   wireframe/snap.js        the lines to snap to, and the guides
//   wireframe/history.js     undo and redo
//   wireframe/window.js      the window that the components are on
//
// This file puts their elements in the page and their listeners on it. The order counts: a
// listener that comes first can keep an event from the next ones, and elements with the same
// z-index stack in the order they go in.
import { Excalidraw } from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";
import { createRoot } from "react-dom/client";
import { post, setAPI } from "./scene.js";
import { contextMenu, contextMenuKey, contextMenuPointer, contextMenuRequested, contextMenuStyle } from "./context-menu.js";
import { escapePressed, focusChanged, swallowToolKey } from "./bridge.js";
import { cursorRing, labelCursor, moveCursor } from "./cursor.js";
import { blockPressWithNoTool, deleteKey, drawSelection, selectionLayer, enterEndsGroup, enterEndsText, groupChanged, hideShapesForText, moveToRelease, showShapesAgain, pointerLeft, pointerMoved, pointerPressed, pointerReleased } from "./draw-mode.js";
import { bordersMenu, chip, chipStyle, corners, grip, handleOutline, selectionOutline, typeMenu } from "./wireframe/chip.js";
import { commentBox } from "./wireframe/comment.js";
import { labelField, labelStyle } from "./wireframe/labels.js";
import { drawLook, lookLayer } from "./wireframe/look.js";
import { keyPressed, postChange } from "./wireframe/mode.js";
import { snapPointer } from "./wireframe/pointer.js";
import { guideLabel, guideX, guideY, snapRing } from "./wireframe/snap.js";
import { windowOutline } from "./wireframe/window.js";

document.addEventListener("DOMContentLoaded", () => {
  document.head.appendChild(labelCursor);
  document.body.append(
    lookLayer, labelField, labelStyle, chipStyle, handleOutline, selectionOutline, chip, grip, ...corners, typeMenu, bordersMenu, commentBox, moveCursor, windowOutline,
    guideX, guideY, guideLabel, snapRing, cursorRing, selectionLayer, contextMenu, contextMenuStyle,
  );
});

const pointerEvents = ["pointerdown", "pointermove", "pointerup"];
// Tilde's context menu takes its presses before every other listener.
for (const type of pointerEvents) window.addEventListener(type, contextMenuPointer, true);
window.addEventListener("contextmenu", contextMenuRequested);
document.addEventListener("keydown", contextMenuKey, true);
// Before every other listener sees the release.
window.addEventListener("pointerup", moveToRelease, true);
for (const type of pointerEvents) window.addEventListener(type, blockPressWithNoTool, true);
// Wireframe mode takes the pointer before Draw mode and Excalidraw.
for (const type of pointerEvents) window.addEventListener(type, snapPointer, true);

// A scroll would move the scene; the canvas has nothing to scroll.
window.addEventListener("wheel", (event) => {
  event.stopPropagation();
  event.preventDefault();
}, { capture: true, passive: false });

document.addEventListener("focusin", focusChanged);
document.addEventListener("focusout", focusChanged);
document.addEventListener("keydown", swallowToolKey, true);
document.addEventListener("keydown", keyPressed, true);
document.addEventListener("keydown", deleteKey, true);
document.addEventListener("keydown", escapePressed, true);
document.addEventListener("keydown", enterEndsText, true);
document.addEventListener("keydown", enterEndsGroup, true);

window.addEventListener("pointermove", pointerMoved, true);
document.addEventListener("pointerleave", pointerLeft);
window.addEventListener("pointerdown", pointerPressed, true);
window.addEventListener("pointerup", pointerReleased, true);
// Last before Excalidraw, which takes the press between these two.
window.addEventListener("pointerdown", hideShapesForText, true);
window.addEventListener("pointerdown", showShapesAgain);

const initialData = {
  appState: {
    viewBackgroundColor: "transparent",
    currentItemStrokeColor: "#2F76FF",
    currentItemRoughness: 0,
    currentItemStrokeWidth: 2,
    // Helvetica, for text.
    currentItemFontFamily: 2,
    activeTool: { type: "arrow", locked: true },
  },
};

createRoot(document.getElementById("root")).render(
  <Excalidraw
    initialData={initialData}
    onChange={() => {
      drawLook();
      drawSelection();
      groupChanged();
      postChange();
    }}
    excalidrawAPI={(value) => {
      setAPI(value);
      post("ready");
    }}
  />
);
