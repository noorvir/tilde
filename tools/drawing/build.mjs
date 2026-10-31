// Builds the drawing canvas into Sources/TildeUI/DrawingWeb. The result is committed: building
// the app needs no Node.
import { build } from "esbuild";
import { readFile } from "node:fs/promises";

// Excalidraw offers no option for these. A new version of it fails here until they are looked at.
const patches = [
  // The rectangle around the selection: only its handles stay.
  { file: /prod\/index\.js$/, from: ",E.forEach(S=>$1(d,a,S))}if(d.save(),d.translate(a.scrollX,a.scrollY),r.length===1){", to: "}if(d.save(),d.translate(a.scrollX,a.scrollY),r.length===1){" },
  // The rotation handle.
  { file: /prod\/chunk-K2UTITRG\.js$/, from: "{e:!0,s:!0,n:!0,w:!0}", to: "{e:!0,s:!0,n:!0,w:!0,rotation:!0}" },
];

const patchExcalidraw = {
  name: "patch-excalidraw",
  setup({ onLoad }) {
    for (const patch of patches) {
      onLoad({ filter: patch.file }, async ({ path }) => {
        const contents = await readFile(path, "utf8");
        if (!contents.includes(patch.from)) {
          throw new Error(`Excalidraw changed: ${patch.from}`);
        }
        let patched = contents.replaceAll(patch.from, patch.to);
        // The class that gives an arrow the handles of its points, for selecting one from code.
        const editor = patched.match(/selectedLinearElement:new ([\w$]+)\(/)?.[1];
        if (patch.file.source.includes("index")) {
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
