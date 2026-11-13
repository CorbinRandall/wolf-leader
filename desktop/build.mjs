// Builds the app: the main process, the preload bridge and the screens, each into dist/.
import { build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
const common = { bundle: true, sourcemap: true, logLevel: "info" };
await build({ ...common, entryPoints: ["src/main/main.ts"], outfile: "dist/main.js", platform: "node", format: "cjs", external: ["electron"] });
await build({ ...common, entryPoints: ["src/main/preload.ts"], outfile: "dist/preload.js", platform: "node", format: "cjs", external: ["electron"] });
await build({ ...common, entryPoints: ["src/ui/app.tsx"], outfile: "dist/ui.js", platform: "browser", format: "iife", jsx: "automatic",
              define: { "process.env.NODE_ENV": '"production"' }, minify: true });
copyFileSync("src/ui/index.html", "dist/index.html");
copyFileSync("src/ui/styles.css", "dist/styles.css");
