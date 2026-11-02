import { build } from "esbuild";
import { mkdir, copyFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const here = fileURLToPath(new URL("./", import.meta.url));
const outdir = here + "priv/static/assets";
await mkdir(outdir, { recursive: true });
await build({
  entryPoints: { host: here + "assets/host.js", sandbox: here + "assets/vendor/sandbox.ts" },
  outdir, bundle: true, minify: true, format: "iife", target: "es2022", legalComments: "none",
  alias: {
    phoenix: here + "deps/phoenix/priv/static/phoenix.mjs",
    phoenix_live_view: here + "deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js",
  },
});
await copyFile(here + "assets/host.css", outdir + "/host.css");
console.log("Built Phoenix host and upstream sandbox assets.");
