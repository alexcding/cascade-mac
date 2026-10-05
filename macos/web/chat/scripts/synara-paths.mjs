// How an import inside Synara's source is resolved, shared by the vendor script (which walks
// Synara's checkout to find what the page needs) and the build (which resolves the vendored
// copy). Both must agree, or the vendored tree would not be the tree the build reads.
//
// Paths are relative to a Synara root (the checkout, or vendor/synara): apps/web/src/...,
// packages/contracts/src/..., packages/shared/src/...
//
// A shim replaces one Synara module. It lives at src/shims/<area>/<path>, where <area> is
// `web` (apps/web/src), `shared` (packages/shared/src) or `contracts` (packages/contracts/src),
// and the path is the module's own path under it. src/shims/npm/<pkg with / as __>.ts replaces
// an npm package.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const here = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const vendorRoot = join(here, "vendor/synara");
export const shimRoot = join(here, "src/shims");

export const AREAS = {
  web: "apps/web/src",
  shared: "packages/shared/src",
  contracts: "packages/contracts/src",
};

const EXTENSIONS = ["", ".ts", ".tsx", "/index.ts", "/index.tsx"];

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, out);
    else out.push(path);
  }
  return out;
}

/** Synara module key (path without extension) → shim file, plus npm package → shim file. */
export function loadShims() {
  const modules = new Map();
  const packages = new Map();
  for (const [area, prefix] of Object.entries(AREAS)) {
    for (const file of walk(join(shimRoot, area))) {
      if (!/\.(ts|tsx)$/.test(file)) continue;
      const rel = relative(join(shimRoot, area), file).split(sep).join("/");
      modules.set(`${prefix}/${rel.replace(/\.(ts|tsx)$/, "")}`, file);
    }
  }
  for (const file of walk(join(shimRoot, "npm"))) {
    const name = relative(join(shimRoot, "npm"), file).replace(/\.(ts|tsx)$/, "").replaceAll("__", "/");
    packages.set(name, file);
  }
  return { modules, packages };
}

let sharedExports;
function sharedSubpath(root, sub) {
  sharedExports ??= new Map();
  if (!sharedExports.has(root)) {
    const pkg = join(root, "packages/shared/package.json");
    sharedExports.set(root, existsSync(pkg) ? JSON.parse(readFileSync(pkg, "utf8")).exports : null);
  }
  const exportsMap = sharedExports.get(root);
  const entry = exportsMap?.[`./${sub}`];
  const target = typeof entry === "string" ? entry : entry?.import;
  return target ? `packages/shared/${target.replace(/^\.\//, "")}` : `packages/shared/src/${sub}.ts`;
}

/** The package name of a bare specifier: `@scope/pkg/sub` → `@scope/pkg`. */
export function packageName(spec) {
  const parts = spec.split("/");
  return spec.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

/**
 * Resolves `spec` imported from the Synara file `fromRel` (a path relative to `root`, or an
 * absolute path for a file outside it, such as a shim or our own source).
 *  { kind: "file", rel }      a Synara file under root
 *  { kind: "shim", path }     a shim replaces it
 *  { kind: "external", pkg }  an npm package
 *  { kind: "virtual", spec }  a module the build generates
 *  { kind: "missing", rel }
 */
export function resolveSpec(root, from, spec, shims) {
  const clean = spec.replace(/\?.*$/, "");
  // Modules the build generates (build.mjs), such as the inlined icons.
  if (clean.startsWith("cascade:")) return { kind: "virtual", spec: clean };
  let base;
  if (clean.startsWith("~/")) base = `${AREAS.web}/${clean.slice(2)}`;
  else if (clean === "@synara/contracts") base = `${AREAS.contracts}/index`;
  else if (clean.startsWith("@synara/contracts/")) base = `${AREAS.contracts}/${clean.slice(18)}`;
  else if (clean.startsWith("@synara/shared/")) base = sharedSubpath(root, clean.slice(15));
  else if (clean.startsWith(".")) {
    const fromAbs = from.startsWith("/") ? from : join(root, from);
    const target = resolve(dirname(fromAbs), clean);
    // A relative import from a shim means the shim's own neighbour, not Synara's.
    if (!target.startsWith(root + sep)) return { kind: "local", path: target };
    base = relative(root, target).split(sep).join("/");
  } else {
    const pkg = packageName(clean);
    if (shims.packages.has(clean)) return { kind: "shim", path: shims.packages.get(clean) };
    if (shims.packages.has(pkg) && clean === pkg) return { kind: "shim", path: shims.packages.get(pkg) };
    return { kind: "external", pkg, spec: clean };
  }
  const bases = [base, base.replace(/\.(js|mjs)$/, "")];
  for (const b of bases) {
    const key = b.replace(/\.(ts|tsx)$/, "");
    for (const k of [key, `${key}/index`]) {
      if (shims.modules.has(k)) return { kind: "shim", path: shims.modules.get(k) };
    }
  }
  for (const b of bases) {
    for (const ext of EXTENSIONS) {
      const candidate = join(root, b + ext);
      if (existsSync(candidate) && statSync(candidate).isFile()) {
        return { kind: "file", rel: relative(root, candidate).split(sep).join("/") };
      }
    }
  }
  return { kind: "missing", rel: base };
}

/**
 * The module specifiers a source file imports at runtime. Type-only imports (`import type`,
 * `export type`, and `import { type A, type B }` naming nothing else) are left out: the build
 * erases them, so they need no file.
 */
export function runtimeImports(source) {
  const specs = [];
  const stripped = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
  const re = /(?:^|[\s;}])(import|export)\s+(type\s+)?([^'";]*?\s+from\s+|)["']([^"']+)["']|import\(\s*["']([^"']+)["']\s*\)/g;
  let m;
  while ((m = re.exec(stripped))) {
    if (m[5]) { specs.push(m[5]); continue; }
    if (m[2]) continue;
    const clause = m[3];
    const braces = clause.match(/^\s*\{([^}]*)\}\s+from\s+$/);
    if (braces) {
      const names = braces[1].split(",").map((s) => s.trim()).filter(Boolean);
      if (names.length > 0 && names.every((n) => n.startsWith("type "))) continue;
    }
    // `export { a, b };` without from is not an import; the regex needs `from` or a bare import.
    if (m[1] === "export" && clause === "") continue;
    specs.push(m[4]);
  }
  // `new URL("./x.worker.ts", import.meta.url)`: a module the build emits as a file of its own.
  for (const w of stripped.matchAll(/new URL\(\s*["'](\.[^"']+)["']\s*,\s*import\.meta\.url\s*\)/g)) {
    specs.push(w[1]);
  }
  return specs;
}
