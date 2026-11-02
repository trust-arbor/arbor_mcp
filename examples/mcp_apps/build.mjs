import { build } from "esbuild";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const result = await build({
  entryPoints: [path.join(root, "view.ts")], bundle: true, write: false,
  platform: "browser", format: "iife", target: "es2022", minify: true,
  legalComments: "none",
});
const template = await readFile(path.join(root, "view.html"), "utf8");
if (template.split("<!-- APP_SCRIPT -->").length !== 2) throw new Error("Expected one script placeholder");
const script = result.outputFiles[0].text.replace(/<\/script/gi, "<\\/script");
await mkdir(path.join(root, "dist"), { recursive: true });
await writeFile(path.join(root, "dist/view.html"), template.replace("<!-- APP_SCRIPT -->", () => `<script>${script}</script>`));
console.log("Built dist/view.html (self-contained; no CDN or external assets)");
