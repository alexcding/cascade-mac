// Streamdown's code plugin, cut down to the languages an agent actually prints. `@streamdown/code`
// pulls in every Shiki grammar and theme, which built into hundreds of chunks; this keeps each
// grammar below as its own chunk, still loaded on demand, and highlights anything else as text.
import { createHighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import githubLight from "@shikijs/themes/github-light";
import githubDark from "@shikijs/themes/github-dark";

const grammars = {
  bash: () => import("@shikijs/langs/bash"),
  c: () => import("@shikijs/langs/c"),
  css: () => import("@shikijs/langs/css"),
  diff: () => import("@shikijs/langs/diff"),
  docker: () => import("@shikijs/langs/docker"),
  go: () => import("@shikijs/langs/go"),
  graphql: () => import("@shikijs/langs/graphql"),
  html: () => import("@shikijs/langs/html"),
  ini: () => import("@shikijs/langs/ini"),
  java: () => import("@shikijs/langs/java"),
  javascript: () => import("@shikijs/langs/javascript"),
  json: () => import("@shikijs/langs/json"),
  jsonc: () => import("@shikijs/langs/jsonc"),
  jsx: () => import("@shikijs/langs/jsx"),
  kotlin: () => import("@shikijs/langs/kotlin"),
  make: () => import("@shikijs/langs/make"),
  markdown: () => import("@shikijs/langs/markdown"),
  objc: () => import("@shikijs/langs/objective-c"),
  python: () => import("@shikijs/langs/python"),
  rust: () => import("@shikijs/langs/rust"),
  sql: () => import("@shikijs/langs/sql"),
  swift: () => import("@shikijs/langs/swift"),
  toml: () => import("@shikijs/langs/toml"),
  tsx: () => import("@shikijs/langs/tsx"),
  typescript: () => import("@shikijs/langs/typescript"),
  xml: () => import("@shikijs/langs/xml"),
  yaml: () => import("@shikijs/langs/yaml"),
};

const aliases = {
  sh: "bash", shell: "bash", shellscript: "bash", zsh: "bash", console: "bash",
  "c++": "c", cpp: "c", h: "c", hpp: "c", dockerfile: "docker", gql: "graphql",
  js: "javascript", mjs: "javascript", cjs: "javascript", kt: "kotlin", kts: "kotlin",
  makefile: "make", md: "markdown", "objective-c": "objc", m: "objc", py: "python",
  rs: "rust", ts: "typescript", mts: "typescript", yml: "yaml", plist: "xml", svg: "xml",
  patch: "diff",
};

// Shiki's name for a grammar is not always our key (`objective-c`, `docker`); it is what the
// loaded registration calls itself, so tokens are asked for by that.
const resolve = (language) => {
  const name = String(language ?? "").trim().toLowerCase();
  return grammars[name] ? name : aliases[name] ?? null;
};

const themes = [githubLight, githubDark];
const highlighter = createHighlighterCore({ themes, langs: [], engine: createJavaScriptRegexEngine({ forgiving: true }) });
const loaded = new Map(); // our key -> Promise of Shiki's language id
const results = new Map();
const waiting = new Map();

const load = (key) => {
  if (!loaded.has(key)) {
    loaded.set(key, highlighter.then(async (core) => {
      const grammar = (await grammars[key]()).default;
      await core.loadLanguage(grammar);
      return grammar[grammar.length - 1].name;
    }));
  }
  return loaded.get(key);
};

export const code = {
  name: "shiki",
  type: "code-highlighter",
  supportsLanguage: (language) => resolve(language) !== null,
  getSupportedLanguages: () => Object.keys(grammars),
  getThemes: () => themes,
  highlight({ code: text, language }, callback) {
    const key = resolve(language);
    const id = `${key ?? "text"}:${text.length}:${text.slice(0, 100)}:${text.slice(-100)}`;
    if (results.has(id)) return results.get(id);
    if (callback) { if (!waiting.has(id)) waiting.set(id, new Set()); waiting.get(id).add(callback); }
    Promise.all([highlighter, key ? load(key) : "text"]).then(([core, lang]) => {
      const tokens = core.codeToTokens(text, { lang, themes: { light: githubLight.name, dark: githubDark.name } });
      results.set(id, tokens);
      for (const done of waiting.get(id) ?? []) done(tokens);
      waiting.delete(id);
    }).catch((error) => { console.error("Code highlighting failed:", error); waiting.delete(id); });
    return null;
  },
};
