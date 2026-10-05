# The chat page and Synara

The agent chat (`macos/Resources/ChatPage`, served on `cascade-chat://` with no network) is
[Synara](https://github.com/Emanuele-web04/synara)'s own web client (MIT): its transcript,
composer, approval and question cards, context meter, model and effort pickers and slash/mention
menu, run unchanged behind Cascade's native bridge. The backend (`crates/cascade-chat`) speaks
Synara's data: `OrchestrationThread`, `OrchestrationEvent`, `ClientOrchestrationCommand`. This
page reaches it only through the app.

**Pinned commit:** `c6ce7f7a0dfc5c4e31fb85c217a188885c99180e` (see `vendor/synara/MANIFEST.json`).

## Layout

| Path | What |
|---|---|
| `vendor/synara/` | Synara's files, **verbatim**: `apps/web/src/…`, `packages/contracts/src/…`, `packages/shared/src/…`, `apps/web/src/index.css`, the Central icons the source names (`apps/web/public/central-icons-*`), `LICENSE`. Never edit them. |
| `vendor/synara/MANIFEST.json` | The commit, the shims, the npm versions Synara's lockfile pins, and every vendored file's SHA-256. The build refuses an edited file. |
| `scripts/vendor-synara.mjs` | Copies the closure from a Synara checkout; `--check` verifies the tree byte for byte. |
| `scripts/synara-paths.mjs` | Import resolution shared by the vendor script and the build. |
| `src/shims/` | Replacements for Synara modules that reach its server, router or Electron. |
| `src/bridge.ts` | The native bridge (protocol below). |
| `src/main.tsx` | Entry: React Query, toasts, theme and type scale, the controller. |
| `src/ChatController.tsx` | A slim ChatView: Synara's hooks and components for one thread. |
| `src/threadStream.ts` | Folds pushed snapshots and events into Synara's store. |
| `src/decode.ts` | Decodes pushes with Synara's schemas, as its WebSocket transport does. |
| `src/storage.ts` | In-memory `localStorage` if the origin has none. |
| `src/styles.css` | Synara's `index.css` through Tailwind v4, then Cascade's overrides (system fonts). |
| `build.mjs` | esbuild + Tailwind into `macos/Resources/ChatPage`. |
| `test/` | DOM smoke test and the fixture harness (`npm test`, `npm run dev:fixture`). |

## Commands

```bash
npm install
npm run build        # verify vendor hashes, bundle, write macos/Resources/ChatPage
npm test             # build, then the DOM smoke test
npm run typecheck    # src/ against the vendored modules
npm run dev:fixture  # print what the page renders for the recorded thread
node scripts/vendor-synara.mjs --from <synara checkout> --check
SYNARA_CHECKOUT=<synara checkout> npm run vendor:check   # the same; --from defaults to $SYNARA_CHECKOUT
```

The build also refuses a file under `vendor/synara` that `MANIFEST.json` does not list.

## Taking a newer Synara

1. Check out the new commit in a Synara clone.
2. `node scripts/vendor-synara.mjs --from <clone> --commit <sha>`: it recomputes the runtime
   import closure of `src/` (following Synara's imports, stopping at shimmed modules and
   following the shims' own imports instead), copies it verbatim, and rewrites the manifest.
   It prints the npm packages the closure imports with the versions Synara's `bun.lock` pins;
   bring `package.json` to them.
3. `npm run typecheck && npm test`. A shim whose original changed its exports fails here; diff
   the original between the two commits and port the change into the shim.

The closure is computed from what `src/` imports, so using another Synara module is a matter of
importing it and re-running the script; the build stops with "Synara module not vendored" until
then.

## Shims

A shim lives at `src/shims/<area>/<path>` and replaces `<area>`'s module at that path wherever
it is imported (`web` = `apps/web/src`, `shared` = `packages/shared/src`, `contracts` =
`packages/contracts/src`); `src/shims/npm/<pkg>.ts` replaces an npm package.

| Shim | Why |
|---|---|
| `web/nativeApi.ts` | Synara's `NativeApi` is a WebSocket RPC client (`wsNativeApi.ts`, `wsTransport.ts`) or Electron's preload. Here it is a proxy over the bridge: the methods listed below are forwarded as RPCs, a few are answered in the page, everything else rejects as unavailable. Cuts the whole transport out of the bundle. |
| `web/lib/central-icons.tsx` | Synara serves its icons as files under `/central-icons-*`; the app's scheme serves only flat html/css/js. The build inlines the vendored SVGs and the shim hands them out as `data:` URLs. Same exports. |
| `npm/@tanstack/react-router` | No router: one thread per page. `useParams` answers the page's thread (toasts scope by it), `useSearch` answers no search, the history goes nowhere (a push to `/settings` is told to the app as `openSettings`). |

Build-level adaptations (no file changed): `import.meta.env.*` is defined (production, no
WebSocket URL); `new URL("./x.worker.ts", import.meta.url)` is emitted as `x.worker.js` beside
the page, as Vite does; KaTeX's fonts are `data:` URLs; the theme's font stacks are system fonts
(SF Pro, SF Mono) instead of Inter/Geist/JetBrains Mono from Google Fonts.

Everything else Synara does when its desktop bridge is absent (audio levels, diagnostics, the
desktop window material) it already does on its own: those modules run unchanged.

## Bridge protocol

The page posts to `webkit.messageHandlers.chat` and native calls functions on
`window.nativeChat`. Both directions carry JSON.

### Page → native

```ts
{ kind: "request", id: string, method: string, params: object }   // an RPC, answered by reply()
{ kind: "event", name: string, payload: object }                    // fire-and-forget
```

A request id is `"<token>-<n>"`, the token random per page load, so a reply meant for an
earlier load (before a reload) cannot settle a request of this one. A request the app leaves
unanswered rejects in the page with `{ code: "timeout" }`: after 15 s for
`orchestration.getThreadDetailSnapshot`, 60 s for anything else. A reply that comes later is
ignored, as is a reply to a snapshot read the page has cancelled (`{ code: "cancelled" }`,
when the context switches to another thread). Both codes are the page's own; the app never
sends them.

Events:

| name | payload | |
|---|---|---|
| `ready` | `{}` | The page is up. Push `context`, then `providers`, then the thread's snapshot. Sent again after a reload (content process crash). |
| `openLink` | `{ url }` | An http(s) or mailto link was clicked. The page cancels every link click itself (a markdown link is an `<a target="_blank">`), so it never navigates; a link of another scheme goes nowhere. |
| `openFile` | `{ path, line? }` | A file reference was clicked. `path` is absolute and inside `context.cwd` or `context.homeDir`; the page sends nothing for a file outside them (the app should check too). |
| `revealFile` | `{ path }` | "Show in Finder" on a file reference. Same rule for `path`. |
| `openTurnDiff` | `{ threadId, turnId, filePath? }` | "Review" on a turn's changed files. |
| `openSettings` | `{ path }` | Synara's "Manage providers" link. |
| `copy` | `{ text }` | Put text on the pasteboard. The page routes `navigator.clipboard.writeText` here (Synara's copy buttons), since a custom-scheme page may have no Clipboard API. |
| `error` | `{ message, stack? }` | An uncaught error or rejection. |
| `log` | `{ level, message }` | Diagnostics: an RPC the app does not serve (once per method), a push that did not decode with Synara's schema (once per distinct failure). |

### Native → page

```ts
window.nativeChat.reply(id, { ok: true, result } | { ok: false, error: { message, code? } })
window.nativeChat.push(channel, payload)
```

| channel | payload |
|---|---|
| `context` | `ChatContext` (below). Push before anything else and again whenever it changes; a new `threadId` replaces the conversation. |
| `providers` | `ServerProviderStatus[]`, Synara's (`contracts/server.ts`), as its `server.getConfig` carries them: `{ provider, instanceId?, driver?, displayName?, enabled?, status: "ready"\|"warning"\|"error", available, authStatus: "authenticated"\|"unauthenticated"\|"unknown", checkedAt, message?, … }`. The page answers `server.getConfig` from it. |
| `thread` | `OrchestrationThreadStreamItem`: `{ kind: "snapshot", snapshot: { snapshotSequence, thread: OrchestrationThread } }` or `{ kind: "event", event: OrchestrationEvent }`. |

```ts
interface ChatContext {
  threadId: string;        // the thread shown
  projectId: string;       // the thread's projectId
  cwd: string;             // workspace root; file references resolve against it
  projectName: string;
  appearance: "light" | "dark";
  locale: string;          // BCP 47
  readOnly: boolean;       // hides the composer (terminal-session transcripts)
  chatFontSizePx?: number; // Synara's chat font size (11–18, default 13)
  homeDir?: string;
}
```

**Thread stream.** Events carry the thread's `sequence`, contiguous from 1; `snapshotSequence`
is the sequence of the last event the snapshot includes. The page applies a snapshot, then the
events after it in order (Synara's `syncServerThreadDetailHotPath` and
`applyOrchestrationEventsHotPath`, coalesced and batched per 16 ms). An event at or below what
is applied is dropped; an event past a gap is held and the page reads the thread again with
`orchestration.getThreadDetailSnapshot` (at once, then backing off from 0.5 s to 30 s while the
reads come back no newer, or time out). A snapshot older than what is applied is ignored. If no
snapshot arrives within 0.5 s of the context, the page asks for one. A context with another
`threadId` switches the stream as it lands: the snapshot pushed right behind it applies, and
anything applied, held or being read for the old thread is dropped.

## RPC methods the app serves

The names are Synara's WebSocket method names (`WS_METHODS`, `ORCHESTRATION_WS_METHODS` in
`contracts/ws.ts`, `contracts/orchestration.ts`), and the shapes are Synara's contract types,
encoded as JSON (the backend implements exactly this list). Types below are in
`vendor/synara/packages/contracts/src`.

| Method | Params | Result |
|---|---|---|
| `orchestration.getThreadDetailSnapshot` | `{ threadId }` | `OrchestrationThreadDetailSnapshot \| null`: `{ snapshotSequence, thread: OrchestrationThread }` |
| `orchestration.dispatchCommand` | `{ command: ClientOrchestrationCommand }` | `{ sequence }`: the sequence of the last event the command produced |
| `provider.listModels` | `ProviderListModelsInput`: `{ provider, instanceId?, refresh?: "if-stale"\|"now", cwd?, binaryPath?, … }` | `ProviderListModelsResult`: `{ models: ProviderModelDescriptor[], source?, cached?, error? }`; a descriptor is `{ slug, name, description?, supportedReasoningEfforts?: {value,label?}[], defaultReasoningEffort?, supportsFastMode?, supportsThinkingToggle?, supportsAutoMode?, contextWindowOptions?, defaultContextWindow?, optionDescriptors?, … }` |
| `provider.getComposerCapabilities` | `{ provider, instanceId? }` | `ProviderComposerCapabilities`: `{ provider, supportsSkillMentions, supportsSkillDiscovery, supportsNativeSlashCommandDiscovery, supportsPluginMentions, supportsPluginDiscovery, supportsRuntimeModelList, supportsThreadCompaction?, supportsThreadImport? }` |
| `provider.listCommands` | `ProviderListCommandsInput`: `{ provider, instanceId?, cwd, threadId?, forceReload?, … }` | `ProviderListCommandsResult`: `{ commands: { name, description? }[], artifacts?, source?, cached? }` |
| `provider.listSkills` | `ProviderListSkillsInput`: `{ provider, instanceId?, cwd, threadId?, forceReload?, … }` | `ProviderListSkillsResult`: `{ skills: ProviderSkillDescriptor[], source?, cached? }` |
| `provider.listPlugins` | `ProviderListPluginsInput` | `ProviderListPluginsResult` (Codex marketplaces; `{ marketplaces: [] }` when none) |
| `provider.listAgents` | `ProviderListAgentsInput`: `{ provider, instanceId?, cwd?, … }` | `ProviderListAgentsResult`: `{ agents: { name, displayName, description?, model? }[] }` |
| `provider.compactThread` | `ProviderCompactThreadInput` | `void` (Claude's "Compact" in the context meter) |
| `projects.searchEntries` | `ProjectSearchEntriesInput`: `{ cwd, query, limit, kind?: "file"\|"directory" }` | `ProjectSearchEntriesResult`: `{ entries: { path, kind, parentPath? }[], truncated }` (the `@` menu) |
| `projects.readFile` | `ProjectReadFileInput`: `{ cwd, relativePath, maxBytes?, previewGrant? }` | `ProjectReadFileResult`: `{ relativePath, contents, truncated, version, encoding, lineEnding, symlink? }` (file-reference hover previews) |
| `projects.resolveWorkspaceFileReferences` | `{ cwd, relativePaths: string[] }` | `{ relativePaths: (string \| null)[] }` (which markdown file references exist) |
| `attachments.save` | `{ threadId, type: "image"\|"file", name, mimeType, dataBase64 }` | `ChatImageAttachment \| ChatFileAttachment`: `{ type, id, name, mimeType, sizeBytes }`. Cascade's own method, replacing Synara's HTTP upload route; the id goes into `thread.turn.start`'s `message.attachments`. |

Commands the page dispatches through `orchestration.dispatchCommand`: `thread.turn.start` (with
`modelSelection`, `providerOptions?`, `assistantDeliveryMode`, `dispatchMode`, `runtimeMode`,
`interactionMode` and Synara's computer-control fields, which the backend may ignore),
`thread.turn.interrupt`, `thread.approval.respond`, `thread.user-input.respond`,
`thread.runtime-mode.set`, `thread.interaction-mode.set`, `thread.meta.update` (runtime and
model settings carried to the next turn), and what Synara's slash commands send
(`useComposerSlashCommands`: `thread.turn.start`). Typed `/fork …` and Codex's `/review …`,
which would create another thread and then navigate to it, are refused in the page with a
toast before anything is sent (they are not in the slash menu either).

Answered in the page, never sent: `server.getConfig` (from `providers` and `context`),
`server.getSettings` (no Synara server settings; Synara's defaults and the page's own
localStorage apply), `shell.openExternal` → `openLink`, `shell.openInEditor` → `openFile`,
`shell.showInFolder` → `revealFile`, `contextMenu.show` (Synara's in-page menu),
`dialogs.confirm`, `orchestration.subscribeThread` (Synara calls it after answering a
question and when an approval was already answered, for a fresh snapshot: the page reads the
thread on screen again and resolves), `orchestration.unsubscribeThread` (resolves), and every
`on…` subscription (none fires; the thread reaches Synara's store from the `thread` push, not
through `orchestration.onThreadEvent`). Optional members of `NativeApi` the app does not serve
(`dialogs.saveFile`, `projects.onFileChange`, `server.prewarmVoice`, `browser.vault`) read as
absent, so Synara's feature checks see them missing. Any other method rejects with
`{ code: "unavailable" }` and is logged once.

## Known gaps against Synara's ChatView

Left out with ChatView itself: the sidebar, header, split panes, right dock, terminal drawer,
diff panel, plan sidebar, git and worktree controls, handoffs, sidechats, forks, review and
export commands, automations, computer control, voice, thread find, pinned messages and notes,
goal header, workflow/subagent strips, the client-side queue of follow-ups (a follow-up during a
turn is sent at once with Synara's queue/steer dispatch mode, and the backend queues it),
message editing, checkpoint revert and file undo, and the composer footer's width-adaptive
tiers (the footer always plans for full width). The transcript's assistant-selection action
(select text to quote it in the composer) is not wired.

Images in the transcript that Synara loads over HTTP (user attachments after a reload, local
image previews, generated images) do not load: the page has no network and the app's scheme
serves only the page's own files. Attachments just sent show from their in-memory preview.
