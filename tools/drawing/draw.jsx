// The drawing canvas: Excalidraw with its own interface hidden, driven from Tilde's HUD.
// Build it with tools/drawing/build.sh.
import { Excalidraw, convertToExcalidrawElements } from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";
import { createRoot } from "react-dom/client";

let api = null;
const taken = new Set();
const post = (message) => window.webkit?.messageHandlers?.tilde?.postMessage(message);

function live() {
  return api.getSceneElements().filter((element) => !element.isDeleted);
}

function pressKey(key, shiftKey) {
  document.dispatchEvent(new KeyboardEvent("keydown", { key, code: "KeyZ", metaKey: true, shiftKey, bubbles: true }));
}

function changeElements(ids, change) {
  const wanted = new Set(ids);
  const elements = api.getSceneElementsIncludingDeleted().map((element) => {
    if (!wanted.has(element.id)) return element;
    return { ...element, ...change(element), version: element.version + 1, versionNonce: Math.floor(Math.random() * 2 ** 31) };
  });
  api.updateScene({ elements, captureUpdate: "NEVER" });
}

function describe(element) {
  const points = element.points?.map(([x, y]) => [Math.round(element.x + x), Math.round(element.y + y)]);
  const shape = { id: element.id, color: element.strokeColor, type: element.type === "freedraw" ? "freehand" : element.type };
  if (element.type === "arrow") {
    shape.from = points[0];
    shape.to = points[points.length - 1];
  } else if (element.type === "freedraw") {
    shape.points = points.filter((_, index) => index % 4 === 0 || index === points.length - 1);
  } else {
    shape.rect = [element.x, element.y, element.width, element.height].map(Math.round);
  }
  return shape;
}

window.tildeDraw = {
  setTool(type) {
    api.setActiveTool({ type, locked: true });
  },
  setColor(color) {
    api.updateScene({ appState: { currentItemStrokeColor: color }, captureUpdate: "NEVER" });
  },
  undo: () => pressKey("z", false),
  redo: () => pressKey("z", true),
  clear() {
    taken.clear();
    api.updateScene({ elements: [], captureUpdate: "NEVER" });
    api.history.clear();
  },
  // The shapes drawn since the last call, in points from the top left of the canvas.
  takeNewShapes() {
    const elements = live().filter((element) => !taken.has(element.id));
    if (!elements.length) return "";
    elements.forEach((element) => taken.add(element.id));
    api.history.clear();
    return JSON.stringify(elements.map(describe));
  },
  remove(ids) {
    changeElements(ids, () => ({ isDeleted: true }));
  },
  move(ids, dx, dy) {
    changeElements(ids, (element) => ({ x: element.x + dx, y: element.y + dy }));
  },
  setVisible(ids, isVisible) {
    changeElements(ids, () => ({ opacity: isVisible ? 100 : 0 }));
  },
  // Draws saved shapes again, and returns their new ids.
  add(shapes) {
    const skeletons = shapes.map((shape) => {
      const common = { strokeColor: shape.color, roughness: 0, strokeWidth: 2 };
      if (shape.type === "arrow") {
        return { ...common, type: "arrow", x: shape.from[0], y: shape.from[1], points: [[0, 0], [shape.to[0] - shape.from[0], shape.to[1] - shape.from[1]]] };
      }
      if (shape.type === "freehand") {
        const [x, y] = shape.points[0];
        return { ...common, type: "freedraw", x, y, points: shape.points.map((point) => [point[0] - x, point[1] - y]) };
      }
      const [x, y, width, height] = shape.rect;
      return { ...common, type: shape.type, x, y, width, height };
    });
    const elements = convertToExcalidrawElements(skeletons, { regenerateIds: true });
    elements.forEach((element) => taken.add(element.id));
    api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...elements], captureUpdate: "NEVER" });
    return elements.map((element) => element.id);
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
