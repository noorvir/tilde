// The Excalidraw scene: its shapes, what Tilde gets of them, and what the page posts to Tilde.

export let api = null;

// Excalidraw is ready: `value` is its API.
export function setAPI(value) {
  api = value;
}

// The shapes that Tilde took for a note: they stay on the canvas until the note is saved, and
// no longer count as new.
export const taken = new Set();
export const post = (message) => window.webkit?.messageHandlers?.tilde?.postMessage(message);

// The pointer's place for Tilde, at most 20 times a second. A place that comes sooner is
// posted when the 50 ms are up, unless a newer one came: Tilde always gets where the pointer
// stopped.
let pointerAt = 0;
let pendingPointer = null;

export function postPointer(x, y) {
  const wait = pointerAt + 50 - performance.now();
  if (wait >= 0) {
    if (!pendingPointer) {
      setTimeout(() => {
        const [lastX, lastY] = pendingPointer;
        pendingPointer = null;
        postPointer(lastX, lastY);
      }, wait + 1);
    }
    pendingPointer = [x, y];
    return;
  }
  pointerAt = performance.now();
  post(`pointer:${x},${y}`);
}

export function live() {
  return api.getSceneElements().filter((element) => !element.isDeleted);
}

export function changeElements(ids, change) {
  const wanted = new Set(ids);
  const elements = api.getSceneElementsIncludingDeleted().map((element) => {
    if (!wanted.has(element.id)) return element;
    return { ...element, ...change(element), version: element.version + 1, versionNonce: Math.floor(Math.random() * 2 ** 31) };
  });
  api.updateScene({ elements, captureUpdate: "NEVER" });
}

export function describe(element) {
  const points = element.points?.map(([x, y]) => [Math.round(element.x + x), Math.round(element.y + y)]);
  const shape = { id: element.id, color: element.strokeColor, type: element.type === "freedraw" ? "freehand" : element.type };
  if (element.customData?.tildeWireframe) {
    shape.type = element.customData.tildeWireframe;
    delete shape.color;
    for (const key of ["label", "comment", "borders", "rows", "columns", "filled", "radius"]) {
      if (element.customData[key] !== undefined) shape[key] = element.customData[key];
    }
  }
  if (element.type === "text") shape.text = element.text;
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

export function withGroups(ids) {
  const wanted = new Set(ids);
  const groups = new Set(live().filter((element) => wanted.has(element.id)).flatMap((element) => element.groupIds));
  return live().filter((element) => wanted.has(element.id) || element.groupIds.some((group) => groups.has(group))).map((element) => element.id);
}

// A text field of the page has the keyboard: Tilde's keys are for its text.
export const isTextField = (element) => element?.matches?.("textarea, input, [contenteditable]") ?? false;
