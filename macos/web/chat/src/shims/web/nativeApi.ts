// Shim of apps/web/src/nativeApi.ts.
//
// Synara's client reaches its server through one NativeApi object (a WebSocket RPC client, or
// Electron's preload). Here that object is built over Cascade's native bridge: every call
// Synara's code makes lands in one of three places.
//
//  - Forwarded: the methods in FORWARDED become an RPC `{ method: "<group>.<name>", params }`
//    that the app answers from its backend (POST /api/chat/rpc). The names are Synara's own
//    WebSocket method names, so the backend serves the same contract Synara's server does.
//  - Answered here: what the page knows without asking (server.getConfig from the pushed
//    providers and context), and what is a native action rather than data (links, files,
//    the context menu).
//  - Unavailable: anything else rejects with a BridgeError coded "unavailable", logged once
//    to the app. Synara's code treats it as a failed request (a query in error, no data).
import {
  ServerConfig,
  type ContextMenuItem,
  type NativeApi,
  type ServerProviderStatus,
} from "@synara/contracts";
import { Schema } from "effect";

import { showContextMenuFallback } from "~/contextMenuFallback";

import { BridgeError, emit, latestPush, logOnce, request, type ChatContext } from "../../bridge";
import { decodeProviderStatuses } from "../../decode";
import { containedPath } from "../../filePaths";
import { refreshSnapshot, streamThreadId } from "../../threadStream";

/** The Synara RPC methods the app serves. SYNARA.md lists their params and results. */
export const FORWARDED = new Set([
  "orchestration.getThreadDetailSnapshot",
  "orchestration.dispatchCommand",
  "provider.getComposerCapabilities",
  "provider.listCommands",
  "provider.listSkills",
  "provider.listPlugins",
  "provider.listModels",
  "provider.listAgents",
  "provider.compactThread",
  "projects.searchEntries",
  "projects.readFile",
  "projects.resolveWorkspaceFileReferences",
]);

/**
 * Optional members of Synara's NativeApi (`name?:` in contracts/ipc.ts) that the app does not
 * serve. They read as absent, as on a Synara host without them, so feature checks
 * (`if (api.projects.onFileChange)`) take the path for their absence instead of calling a
 * method that only rejects.
 */
const ABSENT_OPTIONAL = new Set([
  "dialogs.saveFile",
  "projects.onFileChange",
  "server.prewarmVoice",
  "browser.vault",
]);

function unavailable(method: string): Promise<never> {
  logOnce(`unavailable:${method}`, `The chat page called ${method}, which Cascade does not serve.`);
  return Promise.reject(new BridgeError(`${method} is not available in Cascade.`, "unavailable"));
}

function omitNullUserInputAnswers(command: Parameters<NativeApi["orchestration"]["dispatchCommand"]>[0]) {
  if (command.type !== "thread.user-input.respond") return command;
  return {
    ...command,
    answers: Object.fromEntries(
      Object.entries(command.answers).filter(([, answer]) => answer !== null && answer !== undefined),
    ),
  };
}

export function currentServerConfig(): ServerConfig {
  const context = latestPush<ChatContext>("context");
  const providers: ReadonlyArray<ServerProviderStatus> = decodeProviderStatuses(
    latestPush<unknown>("providers") ?? [],
  );
  const cwd = context?.cwd || "/";
  const config = {
    cwd,
    ...(context?.homeDir ? { homeDir: context.homeDir } : {}),
    worktreesDir: cwd,
    keybindingsConfigPath: `${cwd}/.keybindings.json`,
    keybindings: [],
    issues: [],
    providers,
    availableEditors: [],
  };
  try {
    return Schema.decodeUnknownSync(ServerConfig)(config);
  } catch {
    return config as unknown as ServerConfig;
  }
}

type Handler = (...args: never[]) => unknown;

function allowedPath(path: string): string {
  const contained = containedPath(path, latestPush<ChatContext>("context"));
  if (!contained) throw new Error("Only files inside the workspace or the home folder can be opened.");
  return contained;
}

const LOCAL: Record<string, Handler> = {
  "server.getConfig": async () => currentServerConfig(),
  "orchestration.dispatchCommand": (command: Parameters<NativeApi["orchestration"]["dispatchCommand"]>[0]) =>
    request("orchestration.dispatchCommand", { command: omitNullUserInputAnswers(command) }),
  "shell.openExternal": async (url: string) => {
    if (!/^(https?:\/\/|mailto:)/i.test(url)) throw new Error("Only web and mail links can be opened.");
    emit("openLink", { url });
  },
  // openInPreferredEditor hands the file as `cwd`; the app opens it in its own editor. Only a
  // file inside the workspace or the home folder is handed over (the app checks too).
  "shell.openInEditor": async (path: string) => emit("openFile", { path: allowedPath(path) }),
  "shell.showInFolder": async (path: string) => emit("revealFile", { path: allowedPath(path) }),
  // Synara (re)subscribes to a thread to have its server send a full snapshot, after a
  // question is answered and when an approval was already answered elsewhere. Here the app
  // pushes the thread's stream unasked; a subscription is a fresh read of the thread on screen.
  "orchestration.subscribeThread": async (input?: { threadId?: string }) => {
    if (input?.threadId && String(input.threadId) === streamThreadId()) await refreshSnapshot({ fresh: true });
  },
  "orchestration.unsubscribeThread": async () => undefined,
  "contextMenu.show": <T extends string>(items: readonly ContextMenuItem<T>[], position?: { x: number; y: number }) =>
    showContextMenuFallback(items, position),
  // The app keeps no Synara server settings: the page runs on Synara's defaults and the
  // settings it keeps itself (localStorage), as Synara's client does before its server answers.
  "server.getSettings": () => Promise.reject(new BridgeError("No server settings in Cascade.", "unavailable")),
  "dialogs.confirm": async (message: string) => window.confirm(message),
  "dialogs.pickFolder": async () => null,
};

function methodOf(group: string, name: string): Handler | undefined {
  const method = `${group}.${name}`;
  if (LOCAL[method]) return LOCAL[method];
  // Subscriptions: `onX(callback)` hands back an unsubscribe; none of them fires. The thread
  // reaches Synara's store through threadStream.ts, not through a subscription.
  if (/^on[A-Z]/.test(name)) return () => () => undefined;
  if (FORWARDED.has(method)) return (params: unknown = {}) => request(method, params ?? {});
  return () => unavailable(method);
}

const groups = new Map<string, unknown>();
function group(name: string): unknown {
  let value = groups.get(name);
  if (!value) {
    const methods = new Map<string, Handler>();
    value = new Proxy(
      {},
      {
        get(_target, property) {
          if (typeof property !== "string" || property === "then") return undefined;
          if (ABSENT_OPTIONAL.has(`${name}.${property}`)) return undefined;
          let method = methods.get(property);
          if (!method) methods.set(property, (method = methodOf(name, property) as Handler));
          return method;
        },
      },
    );
    groups.set(name, value);
  }
  return value;
}

const api = new Proxy(
  {},
  {
    get(_target, property) {
      if (typeof property !== "string" || property === "then") return undefined;
      return group(property);
    },
  },
) as NativeApi;

export function readNativeApi(): NativeApi | undefined {
  return typeof window === "undefined" ? undefined : api;
}

export function ensureNativeApi(): NativeApi {
  return api;
}

export function readNativeApiServerCapability(_capability: string): boolean {
  return false;
}

export function onNativeApiServerCapabilitiesChange(
  listener: () => void,
  options?: { readonly replayCurrent?: boolean },
): () => void {
  if (options?.replayCurrent) listener();
  return () => undefined;
}
