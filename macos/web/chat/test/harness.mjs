// Runs the built chat page (macos/Resources/ChatPage) in happy-dom with a fake native side:
// it answers the page's RPCs from a recorded thread and pushes what the app would push.
// Used by the smoke test and by `npm run dev:fixture`.
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const pageDir = join(here, "../../../Resources/ChatPage");
export const fixture = JSON.parse(readFileSync(join(here, "fixtures/claude-turn-with-approval.json"), "utf8"));

export const context = {
  threadId: fixture.done.thread.id,
  projectId: fixture.done.thread.projectId,
  cwd: "/Users/me/project",
  projectName: "project",
  appearance: "light",
  locale: "en-US",
  readOnly: false,
  chatFontSizePx: 13,
  homeDir: "/Users/me",
};

export const providers = [
  {
    provider: "claudeAgent",
    instanceId: "claudeAgent",
    driver: "claudeAgent",
    displayName: "Claude",
    enabled: true,
    status: "ready",
    available: true,
    authStatus: "authenticated",
    checkedAt: "2026-10-05T10:00:00.000Z",
  },
];

const MODELS = {
  claudeAgent: [
    { slug: "haiku", name: "Claude Haiku", supportedReasoningEfforts: [] },
    { slug: "sonnet", name: "Claude Sonnet" },
  ],
};

/** Answers a test puts in place of the recorded ones (method → (params) => result). */
const overrides = new Map();

/** What the fake app answers for each RPC the page makes. */
function answer(method, params) {
  if (overrides.has(method)) return overrides.get(method)(params);
  switch (method) {
    case "orchestration.getThreadDetailSnapshot":
      return fixture.atApproval;
    case "orchestration.dispatchCommand":
      return { sequence: fixture.events.length + 1 };
    case "provider.listModels":
      return { models: MODELS[params.provider] ?? [] };
    case "provider.getComposerCapabilities":
      return {
        provider: params.provider,
        supportsSkillMentions: false,
        supportsSkillDiscovery: false,
        supportsNativeSlashCommandDiscovery: true,
        supportsPluginMentions: false,
        supportsPluginDiscovery: false,
        supportsRuntimeModelList: true,
      };
    case "provider.listCommands":
      return { commands: [{ name: "compact", description: "Compact the conversation" }] };
    case "provider.listSkills":
      return { skills: [] };
    case "provider.listAgents":
      return { agents: [] };
    case "provider.listPlugins":
      return { marketplaces: [] };
    case "projects.searchEntries":
      return { entries: [], truncated: false };
    default:
      throw Object.assign(new Error(`not served: ${method}`), { code: "unavailable" });
  }
}

/** Loads the page. Returns the messages it posted and helpers to drive it. `storage` is what
 *  the page's localStorage holds before it loads, as an earlier page left it. */
export async function loadPage({ storage = {} } = {}) {
  GlobalRegistrator.register({ url: "http://localhost/ChatPage.html", width: 900, height: 900 });
  for (const [key, value] of Object.entries(storage)) window.localStorage.setItem(key, value);
  document.body.innerHTML = '<div id="chat"></div>';
  // happy-dom lays nothing out: every box is 0×0, and Synara's virtualized transcript
  // (LegendList) renders no rows into a viewport of no height. Give the transcript's scroll
  // container a viewport and every other box a row's height.
  const sizeOf = (element) =>
    element?.hasAttribute?.("data-chat-scroll-container") ? { width: 800, height: 600 } : { width: 800, height: 40 };
  for (const [name, axis] of [["clientHeight", "height"], ["offsetHeight", "height"], ["clientWidth", "width"], ["offsetWidth", "width"]]) {
    Object.defineProperty(window.HTMLElement.prototype, name, { configurable: true, get() { return sizeOf(this)[axis]; } });
  }
  // Nor Web Animations: Base UI's popups (the composer's command menu) wait on getAnimations().
  window.Element.prototype.getAnimations ??= function () {
    return [];
  };
  window.HTMLElement.prototype.getBoundingClientRect = function () {
    const { width, height } = sizeOf(this);
    return { x: 0, y: 0, top: 0, left: 0, right: width, bottom: height, width, height, toJSON() {} };
  };
  // Nor does it ever report a size; LegendList waits for one before it renders a row.
  globalThis.ResizeObserver = window.ResizeObserver = class {
    constructor(callback) {
      this.callback = callback;
    }
    observe(target) {
      const { width, height } = sizeOf(target);
      const size = [{ inlineSize: width, blockSize: height }];
      const entry = {
        target,
        contentRect: { x: 0, y: 0, top: 0, left: 0, right: width, bottom: height, width, height },
        borderBoxSize: size,
        contentBoxSize: size,
        devicePixelContentBoxSize: size,
      };
      setTimeout(() => this.callback([entry], this), 0);
    }
    unobserve() {}
    disconnect() {}
  };
  // A scroll moves nothing and tells no one; LegendList waits for its first scroll to land.
  const scrollTops = new WeakMap();
  Object.defineProperty(window.HTMLElement.prototype, "scrollTop", {
    configurable: true,
    get() {
      return scrollTops.get(this) ?? 0;
    },
    set(value) {
      scrollTops.set(this, Math.max(0, Number(value) || 0));
    },
  });
  window.HTMLElement.prototype.scrollTo = function (x, y) {
    const top = typeof x === "object" && x !== null ? x.top : y;
    if (top !== undefined) this.scrollTop = top;
    setTimeout(() => this.dispatchEvent(new window.Event("scroll")), 0);
  };
  window.HTMLElement.prototype.scroll = window.HTMLElement.prototype.scrollTo;
  const posted = [];
  const requests = [];
  // Methods the fake app leaves unanswered, and the requests it is sitting on.
  const holding = new Set();
  const held = [];
  window.webkit = {
    messageHandlers: {
      chat: {
        postMessage(message) {
          posted.push(message);
          if (message.kind !== "request") return;
          requests.push(message);
          if (holding.has(message.method)) {
            held.push(message);
            return;
          }
          queueMicrotask(() => {
            try {
              window.nativeChat.reply(message.id, { ok: true, result: answer(message.method, message.params) });
            } catch (error) {
              window.nativeChat.reply(message.id, { ok: false, error: { message: error.message, code: error.code } });
            }
          });
        },
      },
    },
  };
  // The bundle installs window.nativeChat and posts `ready` on load.
  await import(pathToFileURL(join(pageDir, "ChatPage.js")).href);
  await waitFor(() => posted.some((m) => m.kind === "event" && m.name === "ready"), "the page's ready event");
  const push = (channel, payload) => window.nativeChat.push(channel, payload);
  return {
    posted,
    requests,
    push,
    held,
    /** Answers `method` with `result(params)` from now on; undefined restores the recorded one. */
    answerWith(method, result) {
      if (result) overrides.set(method, result);
      else overrides.delete(method);
    },
    /** Leaves `method` unanswered from now on (true) or answers it again (false). */
    hold(method, on = true) {
      if (on) holding.add(method);
      else holding.delete(method);
    },
    reply: (id, reply) => window.nativeChat.reply(id, reply),
  };
}

/** Puts `value` into the composer as a paste (happy-dom has no keyboard input). */
export async function typeInComposer(value) {
  const editor = document.querySelector("[data-chat-composer-form] [contenteditable]");
  if (!editor) throw new Error("the composer has no editor");
  editor.focus();
  const range = document.createRange();
  range.selectNodeContents(editor.querySelector("p") ?? editor);
  range.collapse(false);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event("selectionchange"));
  await new Promise((resolve) => setTimeout(resolve, 50));
  const data = new window.DataTransfer();
  data.setData("text/plain", value);
  editor.dispatchEvent(new window.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
}

export async function waitFor(condition, what, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = condition();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

export function text() {
  return document.getElementById("chat")?.textContent ?? "";
}

export async function unload() {
  await GlobalRegistrator.unregister();
}
