#!/usr/bin/env node
// Copies the part of Synara's web client the chat page runs, verbatim, into vendor/synara.
//
//   node scripts/vendor-synara.mjs --from <synara checkout> [--commit <sha>] [--check]
//
// --from defaults to $SYNARA_CHECKOUT (so `SYNARA_CHECKOUT=<clone> npm run vendor:check`).
//
// What is copied is the runtime import closure of our own source (src/, shims included):
// every Synara module the page's code reaches, following imports through Synara's tree,
// except modules a shim in src/shims replaces (a shim's own imports are followed instead).
// Type-only imports are not followed; the build erases them. Besides the closure it copies
// index.css (the theme), the Central icons whose names the closure's source mentions (the
// shim of lib/central-icons.tsx inlines them) and the licence.
//
// The checkout's HEAD must be the commit pinned in vendor/synara/MANIFEST.json, or the one
// given with --commit, which then becomes the pin. --check copies nothing: it verifies that
// vendor/synara holds exactly the closure, byte for byte, and exits non-zero if it does not.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { basename, dirname, extname, join, relative, sep } from "node:path";
import { here, loadShims, resolveSpec, runtimeImports, vendorRoot } from "./synara-paths.mjs";

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const from = option("--from") ?? process.env.SYNARA_CHECKOUT;
const check = args.includes("--check");
if (!from) {
  console.error("usage: vendor-synara.mjs --from <synara checkout> [--commit <sha>] [--check]\n(or set SYNARA_CHECKOUT to the checkout)");
  process.exit(2);
}
const manifestPath = join(vendorRoot, "MANIFEST.json");
const previous = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, "utf8")) : null;
const pinned = option("--commit") ?? previous?.commit;
const head = execFileSync("git", ["-C", from, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (!pinned) {
  console.error(`No pinned commit: pass --commit ${head} to vendor this checkout.`);
  process.exit(2);
}
if (head !== pinned) {
  console.error(`The checkout is at ${head}, not the pinned ${pinned}. Check it out, or pass --commit.`);
  process.exit(2);
}
const dirty = execFileSync("git", ["-C", from, "status", "--porcelain", "--", "apps/web", "packages"], { encoding: "utf8" });
if (dirty.trim()) {
  console.error(`The checkout has local changes under apps/web or packages:\n${dirty}`);
  process.exit(2);
}

// --- the closure -------------------------------------------------------------------------
const shims = loadShims();
const ours = [];
(function collect(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) collect(path);
    else if (/\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name)) ours.push(path);
  }
})(join(here, "src"));

const files = new Set();
const packages = new Map(); // package → Set of importing files
const missing = [];
const visited = new Set();
const queue = ours.map((path) => ({ abs: path }));
while (queue.length) {
  const item = queue.pop();
  const id = item.abs ?? item.rel;
  if (visited.has(id)) continue;
  visited.add(id);
  const path = item.abs ?? join(from, item.rel);
  if (item.rel) files.add(item.rel);
  if (!/\.(ts|tsx|js|mjs)$/.test(path)) continue;
  const source = readFileSync(path, "utf8");
  for (const spec of runtimeImports(source)) {
    const target = resolveSpec(from, item.abs ?? item.rel, spec, shims);
    if (target.kind === "file") queue.push({ rel: target.rel });
    else if (target.kind === "shim" || target.kind === "local") queue.push({ abs: target.path });
    else if (target.kind === "external") {
      if (!packages.has(target.pkg)) packages.set(target.pkg, new Set());
      packages.get(target.pkg).add(item.rel ?? relative(here, item.abs));
    } else if (target.kind === "missing") {
      // Our own modules may import a Synara module that a shim provides under a new name;
      // anything else missing is an error in the closure.
      missing.push(`${item.rel ?? relative(here, item.abs)}: ${spec}`);
    }
  }
}
if (missing.length) {
  console.error(`Unresolved imports:\n  ${missing.join("\n  ")}`);
  process.exit(1);
}

// Extras: the stylesheet, the licence, and the icons the closure names.
files.add("apps/web/src/index.css");
files.add("LICENSE");
const iconDirs = ["central-icons-reversed", "central-icons-fill"];
const literal = /["'`]([a-z0-9][a-z0-9-]*)(?:\.svg)?["'`]/g;
const named = new Set();
const sources = [...files].filter((rel) => /\.(ts|tsx)$/.test(rel)).map((rel) => join(from, rel)).concat(ours);
for (const path of sources) {
  for (const match of readFileSync(path, "utf8").matchAll(literal)) named.add(match[1]);
}
for (const dir of iconDirs) {
  const abs = join(from, "apps/web/public", dir);
  for (const name of readdirSync(abs)) {
    if (name.endsWith(".svg") && named.has(basename(name, ".svg"))) files.add(`apps/web/public/${dir}/${name}`);
  }
}

const sorted = [...files].sort();
const sha = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

// The versions Synara's lockfile pins, for package.json.
const lock = readFileSync(join(from, "bun.lock"), "utf8");
const versions = {};
for (const pkg of [...packages.keys()].sort()) {
  const m = lock.match(new RegExp(`\\n\\s*"${pkg.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}": \\["${pkg.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}@([^"]+)"`));
  versions[pkg] = m ? m[1] : null;
}

if (check) {
  const want = new Map(sorted.map((rel) => [rel, sha(join(from, rel))]));
  const have = new Set();
  const problems = [];
  (function walk(dir) {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else have.add(relative(vendorRoot, path).split(sep).join("/"));
    }
  })(vendorRoot);
  have.delete("MANIFEST.json");
  for (const [rel, hash] of want) {
    if (!have.has(rel)) problems.push(`missing ${rel}`);
    else if (sha(join(vendorRoot, rel)) !== hash) problems.push(`changed ${rel}`);
  }
  for (const rel of have) if (!want.has(rel)) problems.push(`not in the closure ${rel}`);
  if (problems.length) {
    console.error(`vendor/synara differs from ${pinned}:\n  ${problems.join("\n  ")}`);
    process.exit(1);
  }
  console.log(`vendor/synara matches ${pinned}: ${sorted.length} files, byte for byte.`);
  process.exit(0);
}

rmSync(vendorRoot, { recursive: true, force: true });
let lines = 0;
for (const rel of sorted) {
  const target = join(vendorRoot, rel);
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(join(from, rel), target);
  if (extname(rel) !== ".svg") lines += readFileSync(target, "utf8").split("\n").length;
}
writeFileSync(manifestPath, `${JSON.stringify({
  source: "https://github.com/Emanuele-web04/synara",
  license: "MIT",
  commit: pinned,
  note: "Copied verbatim by scripts/vendor-synara.mjs. Never edit these files; shim them in src/shims.",
  shims: [...shims.modules.keys(), ...[...shims.packages.keys()].map((p) => `npm:${p}`)].sort(),
  packages: versions,
  files: Object.fromEntries(sorted.map((rel) => [rel, sha(join(vendorRoot, rel))])),
}, null, 2)}\n`);
console.log(`Vendored ${sorted.length} files (${lines} lines of source) from ${pinned}.`);
const unpinned = Object.entries(versions).filter(([, v]) => !v).map(([p]) => p);
console.log(`Packages the closure imports (Synara's lockfile versions):`);
for (const [pkg, version] of Object.entries(versions)) console.log(`  ${pkg}@${version ?? "?"}`);
if (unpinned.length) console.log(`Not in Synara's lockfile: ${unpinned.join(", ")}`);
