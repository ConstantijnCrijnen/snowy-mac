import {
  cp,
  mkdir,
  readFile,
  writeFile,
  readdir,
  rm,
  lstat,
  realpath,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = resolve(root, "dist");
await mkdir(dist, { recursive: true });
// Refuse redirected or unowned output before removing any previous build.
if ((await lstat(dist)).isSymbolicLink() || (await realpath(dist)) !== dist)
  throw new Error("dist must be a real directory inside website.");
const marker = resolve(dist, ".snowy-build");
const entries = await readdir(dist);
if (
  entries.length &&
  (await readFile(marker, "utf8").catch(() => "")) !== "Snowy static output\n"
) {
  throw new Error(
    "Refusing to replace an existing dist directory without a Snowy build marker.",
  );
}
for (const file of entries)
  await rm(resolve(dist, file), { recursive: true, force: true });
await writeFile(marker, "Snowy static output\n");
for (const file of [
  "index.html",
  "styles.css",
  "src",
  "assets",
  "windows",
  "_headers",
  ".assetsignore",
]) {
  await cp(resolve(root, file), resolve(dist, file), { recursive: true });
}
console.log("Built website/dist (no runtime dependencies).");
