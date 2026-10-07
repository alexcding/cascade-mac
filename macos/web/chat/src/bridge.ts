// The page's only channel to the app. The page has no network (CSP connect-src 'none'); it
// talks to native through one WebKit message handler and functions native calls on
// window.nativeChat. SYNARA.md documents this protocol; native implements exactly it.
//
// page → native   webkit.messageHandlers.chat.postMessage(message)
//   { kind: "request", id, method, params }   an RPC; native answers with nativeChat.reply
//   { kind: "event", name, payload }          fire-and-forget:
//       ready   {}                           the page is up; push "context", "providers", "thread"
//       openLink { url }                     an http(s) or mailto link was clicked
//       openFile { path, line? }             a file reference was clicked (absolute, inside
//                                            the context's cwd or homeDir)
//       revealFile { path }                  "Show in Finder" on a file reference (same rule)
//       openTurnDiff { threadId, turnId, filePath? }   open Cascade's diff of a turn's file
//                                            ("Edit file" in the page's turn diff)
//       openThread { threadId }              show another chat thread (one a fork or a review
//                                            made, a thread link); the page shows one thread
//       openSettings { path }                Synara's "Manage providers" link
//       copy    { text }                     copy to the pasteboard (Synara's copy buttons)
//       error   { message, stack? }          an uncaught error, for the app's log
//       log     { level, message }           diagnostics (an RPC the app does not serve, a
//                                            push that does not decode with Synara's schema)
//
// RPC methods: Synara's WebSocket method names and contract shapes, plus attachments.save;
// the list the app serves is FORWARDED in shims/web/nativeApi.ts, documented in SYNARA.md.
//
// Request ids are "<per-load token>-<n>", unique across reloads of the page. A request the app
// leaves unanswered rejects on its own, coded "timeout" (requestTimeoutMs); a reply that comes
// later is ignored.
//
// native → page
//   nativeChat.reply(id, { ok: true, result } | { ok: false, error: { message, code? } })
//   nativeChat.push(channel, payload)
//   nativeChat.flush()                         the page is about to close: write what Synara
//                                              holds back for storage (drafts, queued follow-ups)
//       "context"    ChatContext (below); null takes the chat off the page, which shows
//                    nothing until the next context (the app keeps a page across chats)
//       "providers"  ServerProviderStatus[] (Synara's, as server.getConfig carries them)
//       "thread"     OrchestrationThreadStreamItem: { kind: "snapshot", snapshot: {
//                    snapshotSequence, thread } } | { kind: "event", event }
//       "files"      { paths: string[], images: [{ name, mimeType, dataBase64 }] }  for the
//                                         composer: paths of files and folders, mentioned as
//                                         @path, and images the agents take, attached as a pasted
//                                         image is. From the app's open panel (paths only; its
//                                         images go through the file input) and from a drop or
//                                         paste of Finder files, which the app takes whole and
//                                         WebKit never delivers (nativeFiles.ts)

export interface ChatContext {
  /** The thread this page shows. A change replaces the conversation. */
  threadId: string;
  /** The project the thread belongs to (the backend's projectId for it). */
  projectId: string;
  /** Workspace root the agent runs in; file references resolve against it. */
  cwd: string;
  projectName: string;
  appearance: "light" | "dark";
  /** BCP 47, for dates and numbers. */
  locale: string;
  /** Hides the composer: a transcript to read, not a conversation to continue. */
  readOnly: boolean;
  /** Body text size of the transcript, in CSS px (Synara's chatFontSizePx). */
  chatFontSizePx?: number;
  homeDir?: string;
}

type Reply = { ok: true; result: unknown } | { ok: false; error: { message: string; code?: string } };
type PushChannel = "context" | "providers" | "thread" | "files";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { chat?: { postMessage: (message: unknown) => void } } };
    nativeChat?: {
      reply: (id: string, reply: Reply) => void;
      push: (channel: PushChannel, payload: unknown) => void;
      flush: () => void;
    };
  }
}

export class BridgeError extends Error {
  constructor(
    message: string,
    readonly code?: string,
  ) {
    super(message);
    this.name = "BridgeError";
  }
}

const pending = new Map<
  string,
  { method: string; resolve: (value: unknown) => void; reject: (error: Error) => void }
>();
const listeners = new Map<PushChannel, Set<(payload: unknown) => void>>();
const latest = new Map<PushChannel, unknown>();
let nextId = 1;
/** Tells this load's requests from an earlier load's, whose replies may still be in flight. */
const loadToken = (() => {
  try {
    const bytes = new Uint8Array(6);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  } catch {
    return Math.random().toString(16).slice(2, 14);
  }
})();

/** How long the app has to answer a request before it rejects with code "timeout". */
const SNAPSHOT_READ_TIMEOUT_MS = 15_000;
const DEFAULT_TIMEOUT_MS = 60_000;
export function requestTimeoutMs(method: string): number {
  // The smoke test shortens every timeout to see one fire.
  const override = (globalThis as { __cascadeChatTest?: { requestTimeoutMs?: number } }).__cascadeChatTest
    ?.requestTimeoutMs;
  if (typeof override === "number" && override > 0) return override;
  return method === "orchestration.getThreadDetailSnapshot" ? SNAPSHOT_READ_TIMEOUT_MS : DEFAULT_TIMEOUT_MS;
}

function post(message: unknown): void {
  const handler = window.webkit?.messageHandlers?.chat;
  if (handler) handler.postMessage(message);
  else testSink?.(message);
}

/** Tests and the fixture harness receive what the page posts here instead of WebKit. */
let testSink: ((message: unknown) => void) | undefined;
export function setTestSink(sink: ((message: unknown) => void) | undefined): void {
  testSink = sink;
}

export function request<T = unknown>(method: string, params: unknown = {}): Promise<T> {
  const id = `${loadToken}-${nextId++}`;
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      if (!pending.delete(id)) return;
      logOnce(`timeout:${method}`, `The app did not answer ${method} in time.`);
      reject(new BridgeError(`${method} timed out.`, "timeout"));
    }, requestTimeoutMs(method));
    const settle = () => clearTimeout(timer);
    pending.set(id, {
      method,
      resolve: (value) => {
        settle();
        resolve(value as T);
      },
      reject: (error) => {
        settle();
        reject(error);
      },
    });
    try {
      post({ kind: "request", id, method, params });
    } catch (error) {
      pending.delete(id);
      settle();
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

/**
 * Rejects the requests of `method` still waiting for the app, coded "cancelled" (their replies
 * are then ignored): a read made for a thread the page no longer shows. Anything else a chat
 * that left the page asked for is still answered (ChatPageModel.request), so what it sent
 * settles as sent.
 */
export function cancelPending(method: string): void {
  for (const [id, entry] of pending) {
    if (entry.method !== method) continue;
    pending.delete(id);
    entry.reject(new BridgeError(`${method} was cancelled.`, "cancelled"));
  }
}

export function emit(name: string, payload: Record<string, unknown> = {}): void {
  post({ kind: "event", name, payload });
}

export function onPush<T>(channel: PushChannel, listener: (payload: T) => void): () => void {
  let set = listeners.get(channel);
  if (!set) listeners.set(channel, (set = new Set()));
  set.add(listener as (payload: unknown) => void);
  return () => set.delete(listener as (payload: unknown) => void);
}

export function latestPush<T>(channel: PushChannel): T | undefined {
  return latest.get(channel) as T | undefined;
}

const loggedOnce = new Set<string>();
export function logOnce(key: string, message: string, level: "info" | "warn" = "warn"): void {
  if (loggedOnce.has(key)) return;
  loggedOnce.add(key);
  emit("log", { level, message });
}

window.nativeChat = {
  reply(id, reply) {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    if (reply.ok) entry.resolve(reply.result);
    else entry.reject(new BridgeError(reply.error?.message ?? "Request failed", reply.error?.code));
  },
  push(channel, payload) {
    latest.set(channel, payload);
    for (const listener of listeners.get(channel) ?? []) {
      try {
        listener(payload);
      } catch (error) {
        reportError(error);
      }
    }
  },
  flush() {
    // Synara's stores write what they debounce on pagehide (lib/storage.ts
    // flushStorageBeforePageHide); a web view the app takes down never sees one of its own.
    window.dispatchEvent(new Event("pagehide"));
  },
};

export function reportError(error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  const stack = error instanceof Error ? error.stack : undefined;
  emit("error", { message: message.slice(0, 4000), ...(stack ? { stack: stack.slice(0, 8000) } : {}) });
}

window.addEventListener("error", (event) => reportError(event.error ?? event.message));
window.addEventListener("unhandledrejection", (event) => {
  // A request the app does not serve is expected; it is logged once where it is made.
  if (event.reason instanceof BridgeError && (event.reason.code === "unavailable" || event.reason.code === "cancelled")) return;
  reportError(event.reason);
});

// Links go to the app. A markdown link is an <a target="_blank">, which a page on the app's
// scheme must not follow (nor open as a window): every anchor click is cancelled before
// anything else sees it, and a web or mail link is handed to the app instead. Other schemes
// are dropped. Handlers of the page's own (file chips, thread links) still run: the event is
// not stopped, only its default.
const OPENABLE_LINK = /^(https?:|mailto:)/i;
function interceptLink(event: MouseEvent): void {
  if (event.type === "auxclick" && event.button !== 1) return;
  const target = event.target as Element | null;
  const anchor = target?.closest?.("a[href]") as HTMLAnchorElement | null;
  if (!anchor) return;
  event.preventDefault();
  const href = anchor.getAttribute("href") ?? "";
  if (OPENABLE_LINK.test(href.trim())) emit("openLink", { url: anchor.href || href.trim() });
}
document.addEventListener("click", interceptLink, true);
document.addEventListener("auxclick", interceptLink, true);

// The app owns the pasteboard: Synara's copy buttons write through the Clipboard API, which a
// page on a custom scheme may not have (not a secure context) or may be refused, so text
// copies go to the app as a `copy` event instead.
try {
  const clipboard = navigator.clipboard ?? ({} as Clipboard);
  Object.defineProperty(clipboard, "writeText", {
    configurable: true,
    value: async (text: string) => emit("copy", { text: String(text) }),
  });
  if (!navigator.clipboard) Object.defineProperty(navigator, "clipboard", { configurable: true, value: clipboard });
} catch {
  // Leave Synara's own fallback (execCommand) in place.
}
