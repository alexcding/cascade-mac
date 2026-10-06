#!/usr/bin/env node
// Type-checks Cascade's own source (src/) against the vendored Synara modules it uses.
// Errors inside vendor/synara are not ours to fix: they come from ambient types Synara's
// Vite/Electron build provides (import.meta.env, window.desktopBridge, Node globals) and are
// left out, so only src/ errors fail the check.
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = join(dirname(fileURLToPath(import.meta.url)), "..");
const result = spawnSync(join(here, "node_modules/.bin/tsc"), ["-p", here], { cwd: here, encoding: "utf8" });
if (result.error) {
  console.error(`Could not run tsc: ${result.error.message}`);
  process.exit(1);
}
const lines = `${result.stdout ?? ""}${result.stderr ?? ""}`.split("\n");
// Ours: any diagnostic in src/, and any other outside vendor/synara (tsconfig.json's, or one
// tied to no file, as TS5xxx/TS6xxx for options and inputs are), which would otherwise pass as
// "no src/ errors".
const ours = lines.filter(
  (line) => line.startsWith("src/") || (/error TS\d+/.test(line) && !line.startsWith("vendor/")),
);
const vendored = lines.filter((line) => line.startsWith("vendor/") && line.includes("error TS")).length;
if (ours.length) {
  console.error(ours.join("\n"));
  process.exit(1);
}
if (result.status !== 0 && vendored === 0) {
  // tsc failed without a diagnostic we can place: show everything rather than pass.
  console.error(lines.join("\n") || `tsc exited with ${result.status ?? result.signal}`);
  process.exit(1);
}
if (result.status === null) {
  console.error(`tsc was stopped by ${result.signal}`);
  process.exit(1);
}
console.log(`src/ type-checks (${vendored} errors inside vendor/synara, from Synara's own ambient build types, ignored).`);
