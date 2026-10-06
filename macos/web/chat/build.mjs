// Builds the chat page into macos/Resources/ChatPage.
//
// The page is Synara's web client (vendor/synara, copied verbatim by
// scripts/vendor-synara.mjs) behind Cascade's native bridge (src/). The build resolves imports
// exactly as the vendor script does (scripts/synara-paths.mjs): Synara's `~/` and
// `@synara/*` aliases, and a module that src/shims replaces is swapped for its shim wherever
// it is imported. Tailwind v4 compiles Synara's index.css against the vendored sources, with
// Cascade's overrides (src/styles.css) on top.
//
// The app serves only flat html/css/js files from this folder, on its own scheme, with no
// network: icons are inlined, KaTeX's fonts are data: URLs, and a worker Synara loads with
// `new URL("./x.worker.ts", import.meta.url)` is emitted as its own x.worker.js beside the page.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

import { here, loadShims, resolveSpec, vendorRoot } from "./scripts/synara-paths.mjs";

const out = resolve(here, "../../Resources/ChatPage");
const temp = join(here, ".build");
const srcRoot = join(here, "src");
const manifest = JSON.parse(readFileSync(join(vendorRoot, "MANIFEST.json"), "utf8"));
const shims = loadShims();

// Vendored files are Synara's, byte for byte (MANIFEST.json holds their hashes). A change
// belongs in a shim, so an edited file stops the build.
const edited = Object.entries(manifest.files).filter(([rel, hash]) => {
  const path = join(vendorRoot, rel);
  return !existsSync(path) || createHash("sha256").update(readFileSync(path)).digest("hex") !== hash;
});
if (edited.length) {
  console.error(`vendor/synara differs from MANIFEST.json (edit a shim in src/shims instead):\n  ${edited.map(([rel]) => rel).join("\n  ")}`);
  process.exit(1);
}
// Nor may a file be added beside them: the build resolves imports into vendor/synara, so an
// unlisted module would be bundled unchecked. Synara modules come in through the vendor script.
const unlisted = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else {
      const rel = relative(vendorRoot, path).split(sep).join("/");
      if (rel !== "MANIFEST.json" && !Object.hasOwn(manifest.files, rel)) unlisted.push(rel);
    }
  }
})(vendorRoot);
if (unlisted.length) {
  console.error(`vendor/synara holds files MANIFEST.json does not list (run scripts/vendor-synara.mjs):\n  ${unlisted.join("\n  ")}`);
  process.exit(1);
}

rmSync(out, { recursive: true, force: true });
rmSync(temp, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
mkdirSync(temp, { recursive: true });

const inside = (path, root) => path === root || path.startsWith(root + sep);

// Workers Synara constructs from `new URL(..., import.meta.url)`, found while loading.
const workers = new Map(); // absolute source → output name

const synaraPlugin = {
  name: "synara",
  setup(pluginBuild) {
    pluginBuild.onResolve({ filter: /.*/ }, (args) => {
      if (args.kind === "entry-point" || !args.importer) return undefined;
      if (args.importer.includes(`${sep}node_modules${sep}`)) return undefined;
      const fromVendor = inside(args.importer, vendorRoot);
      if (!fromVendor && !inside(args.importer, srcRoot)) return undefined;
      const from = fromVendor ? relative(vendorRoot, args.importer).split(sep).join("/") : args.importer;
      const target = resolveSpec(vendorRoot, from, args.path, shims);
      switch (target.kind) {
        case "shim":
          return { path: target.path };
        case "file":
          return { path: join(vendorRoot, target.rel) };
        case "virtual":
          return { path: target.spec, namespace: "cascade-virtual" };
        case "missing":
          return { errors: [{ text: `Synara module not vendored: ${args.path} (${target.rel}). Run scripts/vendor-synara.mjs.` }] };
        default:
          return undefined;
      }
    });

    pluginBuild.onLoad({ filter: /^cascade:central-icons$/, namespace: "cascade-virtual" }, () => {
      const icons = {};
      for (const variant of ["reversed", "fill"]) {
        icons[variant] = {};
        const dir = join(vendorRoot, "apps/web/public", `central-icons-${variant}`);
        if (!existsSync(dir)) continue;
        for (const name of readdirSync(dir).sort()) {
          if (name.endsWith(".svg")) icons[variant][basename(name, ".svg")] = readFileSync(join(dir, name), "utf8").trim();
        }
      }
      return { contents: `export const CENTRAL_ICONS = ${JSON.stringify(icons)};`, loader: "js" };
    });

    // `new URL("./x.worker.ts", import.meta.url)` names a module Vite emits as its own file.
    // Point it at the file this build emits; the source itself is read as it is.
    pluginBuild.onLoad({ filter: /\.(ts|tsx)$/ }, (args) => {
      if (!inside(args.path, vendorRoot)) return undefined;
      const source = readFileSync(args.path, "utf8");
      if (!source.includes("import.meta.url")) return undefined;
      const contents = source.replace(
        /new URL\(\s*(["'])(\.[^"']+?)\.(ts|tsx|js)\1\s*,\s*import\.meta\.url\s*\)/g,
        (_match, quote, path) => {
          const absolute = resolve(dirname(args.path), `${path}.ts`);
          const name = `${basename(path)}.js`;
          workers.set(absolute, name);
          return `new URL(${quote}./${name}${quote}, import.meta.url)`;
        },
      );
      return { contents, loader: args.path.endsWith(".tsx") ? "tsx" : "ts" };
    });
  },
};

const common = {
  bundle: true,
  minify: true,
  target: "safari17",
  jsx: "automatic",
  logLevel: "warning",
  tsconfig: join(here, "tsconfig.json"),
  plugins: [synaraPlugin],
  define: {
    "process.env.NODE_ENV": '"production"',
    "import.meta.env.DEV": "false",
    "import.meta.env.PROD": "true",
    "import.meta.env.MODE": '"production"',
    "import.meta.env.VITE_WS_URL": '""',
    "import.meta.env.APP_VERSION": JSON.stringify(`synara-${manifest.commit.slice(0, 7)}`),
    "import.meta.hot": "undefined",
  },
  loader: { ".woff2": "dataurl", ".woff": "empty", ".ttf": "empty", ".svg": "dataurl", ".png": "dataurl" },
};

const result = await build({
  ...common,
  entryPoints: { ChatPage: join(here, "src/main.tsx") },
  outdir: out,
  splitting: true,
  format: "esm",
  chunkNames: "chunk-[hash]",
  metafile: true,
});

for (const [source, name] of workers) {
  await build({ ...common, entryPoints: [source], outfile: join(out, name), format: "esm" });
}

// Tailwind compiles Synara's theme and utilities; the CSS the bundle imports (KaTeX) follows.
const tailwindOut = join(temp, "tailwind.css");
execFileSync(join(here, "node_modules/.bin/tailwindcss"), ["-i", join(here, "src/styles.css"), "-o", tailwindOut, "--minify"], {
  cwd: here,
  stdio: ["ignore", "ignore", "inherit"],
});
const bundledCss = existsSync(join(out, "ChatPage.css")) ? readFileSync(join(out, "ChatPage.css"), "utf8") : "";
writeFileSync(join(out, "ChatPage.css"), `${readFileSync(tailwindOut, "utf8")}\n${bundledCss}`);

writeFileSync(
  join(out, "ChatPage.html"),
  `<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; worker-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src data:; media-src 'self' data: blob:; connect-src 'none'; base-uri 'none'; form-action 'none'">
  <title>Conversation</title>
  <link rel="stylesheet" href="ChatPage.css">
  <script type="module" src="ChatPage.js"></script>
</head>
<body><div id="chat"></div></body>
</html>
`,
);
rmSync(temp, { recursive: true, force: true });

const files = readdirSync(out).sort();
const size = (name) => statSync(join(out, name)).size;
const total = files.reduce((sum, name) => sum + size(name), 0);
const kb = (bytes) => `${(bytes / 1024).toFixed(0)} KB`;
console.log(`${files.length} files, ${kb(total)} in ${relative(process.cwd(), out) || out}`);
for (const name of ["ChatPage.js", "ChatPage.css", ...files.filter((f) => f.endsWith(".worker.js"))]) {
  if (files.includes(name)) console.log(`  ${name} ${kb(size(name))}`);
}
const chunks = files.filter((name) => name.startsWith("chunk-"));
if (chunks.length) console.log(`  ${chunks.length} chunks, ${kb(chunks.reduce((sum, name) => sum + size(name), 0))}`);
if (process.env.CHAT_METAFILE) writeFileSync(process.env.CHAT_METAFILE, JSON.stringify(result.metafile));
