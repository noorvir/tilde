// The drawing canvas: Excalidraw with its own interface hidden, driven from Tilde's HUD.
// Build it with tools/drawing/build.sh.
import { Excalidraw, convertToExcalidrawElements } from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";
import { createRoot } from "react-dom/client";

let api = null;
const taken = new Set();
let drawingTool = "arrow";
// The shapes being edited while their comment is open; nothing else can change meanwhile.
let editing = null;
let isWaitingForEdit = false;
let isPressOnShape = false;
const post = (message) => window.webkit?.messageHandlers?.tilde?.postMessage(message);

function live() {
  return api.getSceneElements().filter((element) => !element.isDeleted);
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
    drawingTool = type;
    if (!editing) api.setActiveTool({ type, locked: true });
  },
  // Only these shapes can change, with the handles of the selection tool, and no shape can be drawn.
  editShapes(ids) {
    isWaitingForEdit = false;
    editing = new Set(ids);
    changeElements(live().filter((element) => !editing.has(element.id)).map((element) => element.id), () => ({ locked: true }));
    api.setActiveTool({ type: "selection" });
    selectEdited();
  },
  endEditing() {
    isWaitingForEdit = false;
    if (!editing) return;
    editing = null;
    changeElements(live().map((element) => element.id), () => ({ locked: false }));
    api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
    api.setActiveTool({ type: drawingTool, locked: true });
  },
  setColor(color) {
    api.updateScene({ appState: { currentItemStrokeColor: color }, captureUpdate: "NEVER" });
  },
  deselect() {
    api.updateScene({ appState: { selectedElementIds: {} }, captureUpdate: "NEVER" });
  },
  // The element under the pointer, for snapping; nil clears it.
  setSnapFrame(frame) {
    snapFrame = frame;
  },
  shapesOf(ids) {
    const wanted = new Set(ids);
    return JSON.stringify(live().filter((element) => wanted.has(element.id)).map(describe));
  },
  clear() {
    editing = null;
    isWaitingForEdit = false;
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

// Snapping: to the corners, edge midpoints and centre of the element under the pointer.
const snapDistance = 16;
let snapFrame = null;
let startSnap = null;
let pointerAt = 0;
const ring = document.createElement("div");
ring.style.cssText = "position:fixed;width:12px;height:12px;margin:-8px 0 0 -8px;border:2px solid #2F76FF;border-radius:50%;background:rgba(47,118,255,.25);pointer-events:none;z-index:9999;display:none";
document.addEventListener("DOMContentLoaded", () => document.body.appendChild(ring));

function snapPoint(x, y, event) {
  if (!snapFrame || event.metaKey) return null;
  const [left, top, width, height] = snapFrame;
  const xs = [left, left + width / 2, left + width];
  const ys = [top, top + height / 2, top + height];
  let best = null;
  for (const px of xs) {
    for (const py of ys) {
      const distance = Math.hypot(px - x, py - y);
      if (distance <= snapDistance && (!best || distance < best.distance)) best = { x: px, y: py, distance };
    }
  }
  return best;
}

const drawingTools = new Set(["arrow", "rectangle", "ellipse"]);

window.addEventListener("pointermove", (event) => {
  const now = performance.now();
  if (now - pointerAt > 50) {
    pointerAt = now;
    post(`pointer:${event.clientX},${event.clientY}`);
  }
  const tool = api?.getAppState().activeTool.type;
  const point = drawingTools.has(tool) || tool === "selection" ? snapPoint(event.clientX, event.clientY, event) : null;
  ring.style.display = point ? "block" : "none";
  if (point) {
    ring.style.left = `${point.x}px`;
    ring.style.top = `${point.y}px`;
  }
}, true);

function selectEdited() {
  const element = live().find((candidate) => editing.has(candidate.id));
  const selectedLinearElement = element?.type === "arrow" ? new globalThis.TildeLinearElementEditor(element) : null;
  const selectedElementIds = Object.fromEntries([...editing].map((id) => [id, true]));
  api.updateScene({ appState: { selectedElementIds, selectedLinearElement }, captureUpdate: "NEVER" });
}

function distanceToSegment(x, y, [ax, ay], [bx, by]) {
  const lengthSquared = (bx - ax) ** 2 + (by - ay) ** 2;
  const along = lengthSquared ? Math.max(0, Math.min(1, ((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / lengthSquared)) : 0;
  return Math.hypot(x - ax - along * (bx - ax), y - ay - along * (by - ay));
}

// Whether a press at this point belongs to the shapes being edited, with room for their handles.
function isOnEditedShape(x, y) {
  const reach = 18;
  return live().filter((element) => editing.has(element.id)).some((element) => {
    if (element.type === "arrow") {
      const points = element.points.map(([px, py]) => [element.x + px, element.y + py]);
      return points.slice(1).some((point, index) => distanceToSegment(x, y, points[index], point) <= reach);
    }
    const xs = element.points?.map(([px]) => element.x + px) ?? [element.x, element.x + element.width];
    const ys = element.points?.map(([, py]) => element.y + py) ?? [element.y, element.y + element.height];
    return x >= Math.min(...xs) - reach && x <= Math.max(...xs) + reach && y >= Math.min(...ys) - reach && y <= Math.max(...ys) + reach;
  });
}

window.addEventListener("pointerdown", (event) => {
  startSnap = snapPoint(event.clientX, event.clientY, event);
  isPressOnShape = true;
  if (isWaitingForEdit || (editing && !isOnEditedShape(event.clientX, event.clientY))) {
    isPressOnShape = false;
    event.stopPropagation();
    event.preventDefault();
    if (editing) post("clickAway");
  }
}, true);

function linePoints(start, end) {
  return { x: start.x, y: start.y, width: Math.abs(end.x - start.x), height: Math.abs(end.y - start.y), points: [[0, 0], [end.x - start.x, end.y - start.y]], lastCommittedPoint: null };
}

function snapNewShape(element, event) {
  const end = snapPoint(event.clientX, event.clientY, event);
  if (!startSnap && !end) return;
  if (element.type === "arrow") {
    const last = element.points[element.points.length - 1];
    const from = startSnap ?? { x: element.x, y: element.y };
    const to = end ?? { x: element.x + last[0], y: element.y + last[1] };
    changeElements([element.id], () => linePoints(from, to));
  } else if (element.type === "rectangle" || element.type === "ellipse") {
    const firstX = startSnap?.x ?? element.x;
    const firstY = startSnap?.y ?? element.y;
    const lastX = end?.x ?? element.x + element.width;
    const lastY = end?.y ?? element.y + element.height;
    changeElements([element.id], () => ({
      x: Math.min(firstX, lastX), y: Math.min(firstY, lastY), width: Math.abs(lastX - firstX), height: Math.abs(lastY - firstY),
    }));
  }
}

function snapSelectedArrow(event) {
  const end = snapPoint(event.clientX, event.clientY, event);
  const selected = Object.keys(api.getAppState().selectedElementIds);
  if (!end || selected.length !== 1) return;
  const element = live().find((candidate) => candidate.id === selected[0]);
  if (element?.type !== "arrow") return;
  const last = element.points[element.points.length - 1];
  const start = { x: element.x, y: element.y };
  const stop = { x: element.x + last[0], y: element.y + last[1] };
  const nearStart = Math.hypot(start.x - end.x, start.y - end.y) < Math.hypot(stop.x - end.x, stop.y - end.y);
  // A snap is for an end that was dragged, not for an arrow moved as a whole.
  if (Math.min(Math.hypot(start.x - end.x, start.y - end.y), Math.hypot(stop.x - end.x, stop.y - end.y)) > snapDistance * 2) return;
  changeElements([element.id], () => (nearStart ? linePoints(end, stop) : linePoints(start, end)));
}

window.addEventListener("pointerup", (event) => {
  if (!isPressOnShape) return;
  ring.style.display = "none";
  // After Excalidraw has finished the shape.
  setTimeout(() => {
    const fresh = live().filter((element) => !taken.has(element.id));
    if (fresh.length) {
      snapNewShape(fresh[fresh.length - 1], event);
      isWaitingForEdit = true;
      post("shape");
    } else if (api.getAppState().activeTool.type === "selection") {
      snapSelectedArrow(event);
      // A press beside the handles clears the selection; the shape stays in edit mode.
      if (editing && !api.getAppState().selectedElementIds[[...editing][0]]) selectEdited();
      post("edited");
    }
  }, 0);
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
