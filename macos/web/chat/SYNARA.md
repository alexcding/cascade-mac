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
| `src/TurnDiffPanel.tsx` | A slim DiffPanel: the turn and whole-thread checkpoint diffs, drawn over the chat. |
| `src/threadStream.ts` | Folds pushed snapshots and events into Synara's store. |
| `src/decode.ts` | Decodes pushes with Synara's schemas, as its WebSocket transport does. |
| `src/storage.ts` | In-memory `localStorage` if the origin has none; otherwise the real one, with the composer drafts' key merged on write (`storageMerge.ts`). |
| `src/storageMerge.ts` | Merges a page's whole-state write onto what another page stored since. |
| `src/styles.css` | Synara's `index.css` through Tailwind v4, then Cascade's overrides (system fonts). |
| `build.mjs` | esbuild + Tailwind into `macos/Resources/ChatPage`. |
| `test/` | DOM smoke test, the queue's survival across pages (`queue-restore`, which loads fresh pages through `remount.mjs`), the storage merge, and the fixture harness (`npm test`, `npm run dev:fixture`). |

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
| `openTurnDiff` | `{ threadId, turnId, filePath? }` | "Edit file" on a file of the page's turn diff (Synara opens its own diff editor there): show Cascade's diff of that file. "Review" and the changed-file rows open the diff in the page instead. |
| `openThread` | `{ threadId }` | Show another chat thread: the one a `/fork`, a message's "Fork from here" or Codex's `/review` just made, or a thread link. Synara navigates to it; the page shows one thread, so the app is asked to. Never sent for the thread on screen. |
| `openSettings` | `{ path }` | Synara's "Manage providers" link. |
| `copy` | `{ text }` | Put text on the pasteboard. The page routes `navigator.clipboard.writeText` here (Synara's copy buttons), since a custom-scheme page may have no Clipboard API. |
| `error` | `{ message, stack? }` | An uncaught error or rejection. |
| `log` | `{ level, message }` | Diagnostics: an RPC the app does not serve (once per method), a push that did not decode with Synara's schema (once per distinct failure). |

### Native → page

```ts
window.nativeChat.reply(id, { ok: true, result } | { ok: false, error: { message, code? } })
window.nativeChat.push(channel, payload)
window.nativeChat.flush()   // the page is about to close: Synara's stores write what they debounce
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
| `orchestration.getTurnDiff` | `OrchestrationGetTurnDiffInput`: `{ threadId, fromTurnCount, toTurnCount, ignoreWhitespace? }` | `OrchestrationGetTurnDiffResult`: `{ threadId, fromTurnCount, toTurnCount, diff }` (a unified patch; one turn is `toTurnCount - 1 → toTurnCount`) |
| `orchestration.getFullThreadDiff` | `OrchestrationGetFullThreadDiffInput`: `{ threadId, toTurnCount, ignoreWhitespace? }` | the same shape, from turn count 0 ("All turns" in the diff panel) |
| `orchestration.getShellSnapshot` | `{}` | `OrchestrationShellSnapshot`: `{ snapshotSequence, spaces, projects, threads, updatedAt }`, read after a fork or a review as Synara does. The page applies it only when it lists the thread on screen (a shell snapshot prunes every thread it does not list). |
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
model settings carried to the next turn), `thread.message.edit-and-resend` (editing the latest
rollbackable user message), `thread.checkpoint.revert` (`scope: "thread"` to revert to a
message, after Synara's confirm dialog; `scope: "files"` for a changed-files card's Undo, newest
turn first), and what Synara's slash commands send (`useComposerSlashCommands`):
`thread.turn.start`, `thread.fork.create` (`/fork`, a message's "Fork from here"; then
`orchestration.getShellSnapshot` and `openThread`), and for Codex's `/review` `thread.create`
plus a `thread.turn.start` with `reviewTarget` on the new thread (then the same), which the
engine runs as Codex's native `review/start`. The pickers those commands open are ChatView's
(`composerMenuItems` in ChatController.tsx) less what the app cannot carry out: `/fork` offers
only "Fork Into Local", and `/review` only "Review Uncommitted Changes" (the page knows no base
branch).

**Follow-ups during a turn** go Synara's way: in "queue" mode (Synara's default; Cmd-Enter
takes the other) the message is held in the page's queue (`composerDraftStore`, drawn by
`ComposerQueuedHeader` above the composer, with Steer, Edit and Delete) and sent with
`dispatchMode: "queue"` when the turn ends (`useChatQueuedTurns`); "steer" sends it at once.
The queue and the drafts are kept per thread in localStorage, and every chat page shares one
persistent WebKit data store (`ChatPageHost.dataStore`), so they outlive the page: the page made
when a chat comes back finds its queue and, the thread's turn being over, sends it. Synara holds
its queue while the session is "disconnected" (its server reconnects one); here a stopped session
is a CLI that a send starts again, so the controller drains to it as to an idle one. Two pages
open at once share that localStorage; `storage.ts` merges each page's write of the drafts onto
the other's, so neither drops the other's threads. The app has the page write what it debounces
(`nativeChat.flush`) before it closes it.

Cmd-F (Synara's `chat.find` binding) opens Synara's find bar over the transcript
(`ChatThreadFindHost`), and the transcript draws Synara's message trail along its edge.

Answered in the page, never sent: `server.getConfig` (from `providers` and `context`),
`server.getSettings` (no Synara server settings; Synara's defaults and the page's own
localStorage apply), `shell.openExternal` → `openLink`, `shell.openInEditor` → `openFile`,
`shell.showInFolder` → `revealFile`, `contextMenu.show` (Synara's in-page menu),
`dialogs.confirm` (Synara's in-page dialog, `confirmDialogFallback`), `orchestration.subscribeThread` (Synara calls it after answering a
question and when an approval was already answered, for a fresh snapshot: the page reads the
thread on screen again and resolves), `orchestration.unsubscribeThread` (resolves), and every
`on…` subscription (none fires; the thread reaches Synara's store from the `thread` push, not
through `orchestration.onThreadEvent`). Optional members of `NativeApi` the app does not serve
(`dialogs.saveFile`, `projects.onFileChange`, `server.prewarmVoice`, `browser.vault`) read as
absent, so Synara's feature checks see them missing. Any other method rejects with
`{ code: "unavailable" }` and is logged once.

## Known gaps against Synara's ChatView

Left out with ChatView itself: the sidebar, header, split panes, right dock, terminal drawer,
plan sidebar, git and worktree controls, handoffs, sidechats, export commands, automations,
computer control, voice, pinned messages and notes, goal header, workflow/subagent strips, plan
follow-ups from the plan card, and the composer footer's width-adaptive tiers (the footer always
plans for full width). The transcript's assistant-selection action (select text to quote it in
the composer) is not wired.

The diff panel is DiffPanel's turn view only (TurnDiffPanel.tsx): no working-tree, staged,
branch or compare-ref scopes, no blame, no file tree, no commit and push, since all of them read
git through methods the app does not serve. A fork to a new worktree is not offered: Synara
sends it with `envMode: "worktree"` and no path and creates the worktree on the first send,
and a chat here has no worktree of its own, so the engine refuses it (a typed `/fork worktree`
ends in Synara's "Could not fork thread" toast with the engine's reason).

On a read-only page (a terminal session's transcript) there is no composer, so no queue, and the
transcript offers no edit, revert, undo or fork; the approval and question panels, the turn diff
and find still work.

A user's image attachments load from the page's own scheme: Synara resolves `/attachments/<id>`
against `location.origin`, which WebKit reports as `cascade-chat://page` for the page (checked
in a real web view by `chatPageResolvesAttachmentURLsOnItsScheme`), and the app answers that
path through `attachments.read`. Other images Synara loads over HTTP (local image previews, generated
images) do not load: the page has no network.
