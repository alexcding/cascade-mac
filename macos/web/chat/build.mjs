// Builds the chat page into macos/Resources/ChatPage: the React app with its Shiki grammars split
// into chunks loaded on demand, Tailwind for Streamdown's classes, and the HTML shell. The app
// serves only what lands in that folder, from its own scheme, with no network access.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "../../Resources/ChatPage");

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await build({
  entryPoints: { ChatPage: join(here, "src/main.jsx") },
  outdir: out,
  bundle: true,
  splitting: true,
  format: "esm",
  minify: true,
  target: "safari17",
  jsx: "automatic",
  chunkNames: "chunk-[hash]",
  define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "warning",
});

execFileSync(join(here, "node_modules/.bin/tailwindcss"),
  ["-i", join(here, "src/styles.css"), "-o", join(out, "ChatPage.css"), "--minify"],
  { cwd: here, stdio: ["ignore", "ignore", "inherit"] });

// Shiki runs on its JavaScript regex engine, so the page needs no WebAssembly and no eval.
writeFileSync(join(out, "ChatPage.html"), `<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'">
  <title>Conversation</title>
  <link rel="stylesheet" href="ChatPage.css">
  <script type="module" src="ChatPage.js"></script>
</head>
<body><div id="chat"></div></body>
</html>
`);

const files = readdirSync(out);
console.log(`${files.length} files in ${out}`);
