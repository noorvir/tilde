// The drawing canvas: Excalidraw with its own interface hidden, driven from Tilde's HUD.
// Build it with tools/drawing/build.sh.
import { Excalidraw } from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";
import { createRoot } from "react-dom/client";

let api = null;
let sent = 0;
const post = (message) => window.webkit?.messageHandlers?.tilde?.postMessage(message);

function live() {
  return api.getSceneElements().filter((element) => !element.isDeleted);
}

window.tildeDraw = {
  setTool(type) {
    api.setActiveTool({ type, locked: true });
  },
  clear() {
    api.updateScene({ elements: [] });
    api.history.clear();
    sent = 0;
  },
  undo() {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "z", code: "KeyZ", metaKey: true, bubbles: true }));
  },
  // The shapes drawn since the last call, in points from the top left of the canvas.
  takeNewShapes() {
    const elements = live().slice(sent);
    sent += elements.length;
    if (!elements.length) return "";
    let [left, top, right, bottom] = [Infinity, Infinity, -Infinity, -Infinity];
    const shapes = elements.map((element) => {
      const points = element.points?.map(([x, y]) => [Math.round(element.x + x), Math.round(element.y + y)]);
      const xs = points ? points.map((point) => point[0]) : [element.x, element.x + element.width];
      const ys = points ? points.map((point) => point[1]) : [element.y, element.y + element.height];
      left = Math.min(left, ...xs);
      right = Math.max(right, ...xs);
      top = Math.min(top, ...ys);
      bottom = Math.max(bottom, ...ys);
      const shape = { type: element.type === "freedraw" ? "freehand" : element.type };
      if (element.type === "arrow") {
        shape.from = points[0];
        shape.to = points[points.length - 1];
      } else if (element.type === "freedraw") {
        shape.points = points.filter((_, index) => index % 8 === 0);
      } else {
        shape.rect = [element.x, element.y, element.width, element.height].map(Math.round);
      }
      return shape;
    });
    return JSON.stringify({ shapes, bounds: [left, top, right - left, bottom - top] });
  },
};

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") post("escape");
}, true);

const initialData = {
  appState: {
    viewBackgroundColor: "transparent",
    currentItemStrokeColor: "#2F76FF",
    currentItemRoughness: 0,
    currentItemStrokeWidth: 2,
    activeTool: { type: "arrow", locked: true },
  },
};

createRoot(document.getElementById("root")).render(
  <Excalidraw
    initialData={initialData}
    excalidrawAPI={(value) => {
      api = value;
      post("ready");
    }}
  />
);
