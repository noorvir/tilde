// Builds the drawing canvas into Sources/TildeUI/DrawingWeb. The result is committed: building
// the app needs no Node.
import { build } from "esbuild";
import { readFile } from "node:fs/promises";

// Excalidraw offers no option for these. A new version of it fails here until they are looked at.
const patches = [
  {
    file: /prod\/index\.js$/,
    changes: [
      // The rectangle around the selection: only its handles stay.
      { from: ",E.forEach(S=>$1(d,a,S))}if(d.save(),d.translate(a.scrollX,a.scrollY),r.length===1){", to: "}if(d.save(),d.translate(a.scrollX,a.scrollY),r.length===1){" },
      // The trails of other users' laser pointers ask for a frame for ever, and each frame
      // wakes the page and Tilde. The canvas has no other users: the first frame is the last.
      { from: "onFrame(){this.updateCollabTrails()}", to: "onFrame(){return!0}" },
    ],
  },
  {
    file: /prod\/chunk-K2UTITRG\.js$/,
    // The rotation handle.
    changes: [{ from: "{e:!0,s:!0,n:!0,w:!0}", to: "{e:!0,s:!0,n:!0,w:!0,rotation:!0}" }],
  },
];

const patchExcalidraw = {
  name: "patch-excalidraw",
  setup({ onLoad }) {
    for (const { file, changes } of patches) {
      onLoad({ filter: file }, async ({ path }) => {
        let patched = await readFile(path, "utf8");
        for (const { from, to } of changes) {
          if (!patched.includes(from)) {
            throw new Error(`Excalidraw changed: ${from}`);
          }
          patched = patched.replaceAll(from, to);
        }
        // The class that gives an arrow the handles of its points, for selecting one from code.
        const editor = patched.match(/selectedLinearElement:new ([\w$]+)\(/)?.[1];
        if (file.source.includes("index")) {
          if (!editor) {
            throw new Error("Excalidraw changed: selectedLinearElement");
          }
          patched += `;globalThis.TildeLinearElementEditor=${editor};`;
        }
        return { contents: patched, loader: "js" };
      });
    }
  },
};

await build({
  entryPoints: ["draw.jsx"],
  bundle: true,
  jsx: "automatic",
  minify: true,
  loader: { ".woff2": "dataurl" },
  define: { "process.env.NODE_ENV": '"production"' },
  outfile: "../../Sources/TildeUI/DrawingWeb/draw.js",
  plugins: [patchExcalidraw],
});
