# The chat page and Synara

The agent chat (`macos/Resources/ChatPage`, served on `cascade-chat://` with no network) is
[Synara](https://github.com/Emanuele-web04/synara)'s own web client (MIT): its transcript,
composer, approval and question cards, context meter, model and effort pickers and slash/mention
menu, run unchanged behind Cascade's native bridge. The backend (`crates/cascade-chat`) speaks
Synara's data: `OrchestrationThread`, `OrchestrationEvent`, `ClientOrchestrationCommand`. This
page reaches it only through the app.

**Pinned commit:** `3e72c70af1f9bfe1fdf3eeafd7fa9e0ba0d5f3b4` (see `vendor/synara/MANIFEST.json`).

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
| `src/ChatController.tsx` | A slim ChatView: Synara's hooks and components for one thread, with its single-row composer and the status row under it. |
| `src/TurnDiffPanel.tsx` | A slim DiffPanel: the turn and whole-thread checkpoint diffs, drawn over the chat, in DiffPanel's per-thread layout. |
| `src/threadStream.ts` | Folds pushed snapshots and events into Synara's store. |
| `src/relatedThreads.ts` | Reads the threads the subagent run cards and a subagent's intro need beside the one on screen (its subagents, or its parent and siblings) into Synara's store. |
| `src/decode.ts` | Decodes pushes with Synara's schemas, as its WebSocket transport does. |
| `src/storage.ts` | In-memory `localStorage` if the origin has none; otherwise the real one, with the composer drafts' key merged on write (`storageMerge.ts`). |
| `src/storageMerge.ts` | Merges a page's whole-state write onto what another page stored since. |
| `src/editorDropPaths.ts` | Reads the paths a folder dragged from an editor's file tree carries (`codefiles`, file:// `text/uri-list`), as Synara's `composerDropPaths.ts` does under its desktop shell only. |
| `src/styles.css` | Synara's `index.css` through Tailwind v4, then Cascade's overrides (system fonts, a transparent ground, the composer's 24px side gutters). |
| `build.mjs` | esbuild + Tailwind into `macos/Resources/ChatPage`. |
| `test/` | DOM smoke test, the composer's layout (`layout`, laid out in headless Chrome when it is installed), subagent run cards and the composer's running-agents capsule (`subagents`), the queue's survival across pages (`queue-restore`, which loads fresh pages through `remount.mjs`), the storage merge, file attachment by path (`attach-paths`), inline visuals (`visuals`: a `visual.shown` activity drawn with Synara's components where its reply's fence places it, and its follow-up choice sent), what came by hand from Synara 0cf5ea460 (`ported`: the interface English with another language stored, a new `/goal` sent as a visible goal start, Stop on an idle thread blocked by a provider failure, a folder dragged from an editor's tree mentioned by path, an assistant's inline image drawn from its kept attachment), and the fixture harness (`npm test`, `npm run dev:fixture`). |

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

## The model catalogue, for the app

`src/modelCatalog.ts` is built beside the page as `ChatModelCatalog.js`: Synara's catalogue
(`MODEL_OPTIONS_BY_PROVIDER`), its default per provider, and the merge the page's picker runs over
what the CLI reported (`mergeDynamicModelOptions`), behind one global, `cascadeModelCatalog`. The
app runs it in JavaScriptCore (`Services/Chat/ChatModelCatalog.swift`) so a new chat's form lists
models as the chat's composer does; no page loads it, and it reaches nothing.

## Shims

A shim lives at `src/shims/<area>/<path>` and replaces `<area>`'s module at that path wherever
it is imported (`web` = `apps/web/src`, `shared` = `packages/shared/src`, `contracts` =
`packages/contracts/src`); `src/shims/npm/<pkg>.ts` replaces an npm package.

| Shim | Why |
|---|---|
| `web/nativeApi.ts` | Synara's `NativeApi` is a WebSocket RPC client (`wsNativeApi.ts`, `wsTransport.ts`) or Electron's preload. Here it is a proxy over the bridge: the methods listed below are forwarded as RPCs, a few are answered in the page, everything else rejects as unavailable. Cuts the whole transport out of the bundle. |
| `web/lib/central-icons.tsx` | Synara serves its icons as files under `/central-icons-*`; the app's scheme serves only flat html/css/js. The build inlines the vendored SVGs and the shim hands them out as `data:` URLs. Same exports. |
| `web/lib/icons.tsx` | Synara draws a fork with its branch glyph, which in Cascade is the session's branch. `GitForkIcon` is Cascade's own fork mark; same exports otherwise. |
| `web/components/chat/ChatEmptyStateHero.tsx` | A blank chat is headed by Synara's logo, which in Cascade stands for nothing. The words stay without it; same exports. |
| `web/components/chat/ComposerModelPicker.logic.ts` | The model picker takes ⌘1…⌘9 for its rows while open and labels them so; in Cascade those chords are the sidebar's. No row answers a chord and none is labelled with one; same exports otherwise. |
| `web/components/chat/InlineVisualFrame.tsx` | Synara's file with two changes, for an HTML visual (below, "Inline visuals"). Synara runs agent HTML only under its desktop shell (`isElectron`), whose main process stops a frame navigating itself; here the app's navigation delegate does that, so the frame is always drawn. And Synara writes the document into its frame as `srcdoc`; WebKit gives a srcdoc frame (as a `data:` or `blob:` one) the page's own content security policy, whose `script-src 'self'` stops every inline script of the visual, so the frame loads the same document (built by Synara's `buildInlineVisualDocument`, its policy first) from `cascade-chat://visual/<id>.html`, handed to the app in a `visualDocument` event. Same export. |
| `web/i18n/locale.ts` | Synara picks its interface language from the stored preference or the system's languages (English, Spanish, and Chinese where Beta features are on, as they are on any scheme not Synara's). Cascade's interface is English: every preference resolves to English and English is the only language offered; the stored value is still read and kept. Same exports. |
| `shared/uiLocalizationResources.ts` | Only the English catalogue (`packages/shared/src/locales/en`), imported as `@synara/shared/locales/en/*.json` (a shim's relative import means its own neighbour; `synara-paths.mjs` maps a `.json` subpath the package does not export to its file). The Spanish and Chinese catalogues the page never reads stay out of the bundle. Same export, with `en` only. |
| `npm/@tanstack/react-router` | No router: one thread per page. `useParams` answers the page's thread (toasts scope by it), `useSearch` answers no search, the history goes nowhere (a push to `/settings` is told to the app as `openSettings`). |

`tsconfig.json` resolves `~/…` to `src/shims/web/…` first, then the vendored tree, as the build
does, so a shimmed module type-checks against its shim (a shimmed original is not vendored).

**Interface language.** Synara's strings go through its i18n (`~/i18n`, i18next and react-i18next)
and its catalogue keys; with the two shims above the page draws them in English. `main.tsx` does
not call Synara's `initializeI18n`: under the shims it would only set the document's `lang` to
`en` (and set it again on every app-settings write), where the page keeps the app's `locale` from
the context. Dates and times format with Synara's format locale, which is the interface language
(`en`), as Synara does. No language picker is offered.

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
| `openThread` | `{ threadId }` | Show another chat thread: the one a `/fork`, a message's "Fork from here" or Codex's `/review` just made, a thread link, a row of a subagent run card (a subagent's thread, `subagent:<parent>:<provider thread id>`), or a subagent's intro (its parent). Synara navigates to it; the page shows one thread, so the app is asked to. Never sent for the thread on screen. |
| `openSettings` | `{ path }` | Synara's "Manage providers" link. |
| `copy` | `{ text }` | Put text on the pasteboard. The page routes `navigator.clipboard.writeText` here (Synara's copy buttons), since a custom-scheme page may have no Clipboard API. |
| `visualDocument` | `{ id, html }` | An HTML inline visual's built document, which the app serves at `cascade-chat://visual/<id>.html` for its frame (`ChatPageAssets`). `id` is `<load token>-<n>`; the app keeps the page's latest 64 documents, each at most 1 MiB, and forgets them when the page loads again. Not a chat's: the page host takes it whichever chat is in the page. |
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
| `context` | `ChatContext` (below). Push before anything else and again whenever it changes; a new `threadId` replaces the conversation. `null` takes the chat off the page, which shows nothing until the next context: the app keeps a page across the chats it shows. |
| `providers` | `ServerProviderStatus[]`, Synara's (`contracts/server.ts`), as its `server.getConfig` carries them: `{ provider, instanceId?, driver?, displayName?, enabled?, status: "ready"\|"warning"\|"error", available, authStatus: "authenticated"\|"unauthenticated"\|"unknown", checkedAt, message?, … }`. The page answers `server.getConfig` from it. |
| `thread` | `OrchestrationThreadStreamItem`: `{ kind: "snapshot", snapshot: { snapshotSequence, thread: OrchestrationThread } }` or `{ kind: "event", event: OrchestrationEvent }`. |
| `files` | `{ paths: string[], images: [{ name, mimeType, dataBase64 }] }`, for the composer: each path (absolute, of a file or folder) becomes an `@path` mention, never uploaded; each image goes into Synara's image intake as a pasted one does (prepared, held to `PROVIDER_SEND_TURN_MAX_ATTACHMENTS`, uploaded with the message). Refused whole, with a toast, while a plan question waits. Sent for the app's open panel ("+" → Files and folders: paths only, its images go back through the file input) and for a drop or paste of Finder files, which the app takes whole so WebKit never delivers it: WebKit would give those `File`s no path. The app sorts each file once, on disk with links resolved (`ChatPagePick`): a regular file of an image type the agents take (PNG, JPEG, GIF, WebP) and at most 32 MB is read and sent as an image; anything else, a folder named like an image included, goes by path (`src/nativeFiles.ts`). A drop or paste with no Finder files (an image dragged from a web page, a screenshot on the clipboard) reaches the page as it is: any `image/*` file is uploaded as Synara does, a file with no path is refused. |

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
| `orchestration.getInlineVisual` | `OrchestrationGetInlineVisualInput`: `{ threadId, visualId }` | `OrchestrationGetInlineVisualResult`: `{ visualId, html }`, the stored source of a visual the thread's agent published (the spec JSON, or the HTML document, per the `visual.shown` activity's `format`). A visual that is gone fails coded `inline-visual-missing`. |
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

## Inline visuals

A chat's agent shows a chart, table, comparison or small interactive view with Synara's
`synara_show_visual` tool, which the backend's agent gateway serves to chat CLIs (not to terminal
agents, whose turns no page shows): `crates/cascade-backend/src/gateway/visuals.rs`, a port of
`apps/server/src/agentGateway/inlineVisualTools.ts` keeping its name, description, limits, ids,
`visual.shown` activity and `synara-visual` fence. The page draws the activity with Synara's own
components, unchanged: `MessagesTimeline` places it where the reply's fence puts it (or above the
reply), `InlineVisualBlocks` and its charts, tables, calculator and choices draw a component spec,
and `InlineVisualFrame` (shimmed, above) runs an HTML one; both read the source through
`orchestration.getInlineVisual` (`inlineVisualQueryOptions`). A choice is the reader's next
message, as ChatView's `onSendVisualChoice` sends it (`ChatController.tsx`), and scrolling over an
HTML visual detaches the transcript's follow as ChatView's `onEmbeddedScrollIntent` does.

An HTML visual runs where Synara's desktop runs it: a frame sandboxed `allow-scripts allow-forms`
(no `allow-same-origin`, so an opaque origin, away from the page, its storage and the bridge),
under Synara's policy for the document (no network, inline code and `data:` media only), with
Synara's bootstrap reporting its size and passing theme changes. What differs is where the
document comes from (the shim's note): the page's policy allows one frame source,
`frame-src cascade-chat://visual`, and keeps `connect-src 'none'`. The app's navigation delegate
(`ChatPageHost.allows`) is Synara's `subframeNavigationGuard`: a frame loads only a registered
visual document (or `about:srcdoc` / `about:blank`), so a visual cannot carry data out in a URL it
sends its frame to; a frame that navigates to its own document again loads it a second time, which
Synara's `onLoad` takes as a navigation and stops the visual.

Synara patches LegendList 3.3.3 (`patches/@legendapp%2Flist@3.3.3.patch`) so that putting rows back
in order moves their containers with `Element.moveBefore`, which keeps an HTML visual's frame
loaded. WebKit has no `moveBefore` (checked in a WKWebView on macOS 27), where the patch falls back
to `insertBefore`, today's behaviour; so it is not applied. A frame the list re-inserts gets a new
browsing context and loads its document again from the app, a fresh first load to Synara's
`onLoad`, and the visual's own state (a value typed into it) starts over.

## Known gaps against Synara's ChatView

Left out with ChatView itself: the sidebar, header (and its new-thread button and project
actions; a new chat is the app's), split panes, right dock, terminal drawer,
plan sidebar, git and worktree controls, handoffs (and the blocked-handoff notice), sidechats,
export commands, automations, computer control, voice, pinned messages and notes, goal capsule,
the workflow run capsule, MCP connector mentions, plan follow-ups from the plan card, the
Claude-switch tip, and the composer status row's width-adaptive tiers (it always plans for full
width). The transcript's assistant-selection action (select text to quote it in the composer) is
not wired, nor is Stop on a
background command's row (`thread.task.stop`, which no adapter here carries out).

The composer is ChatView's for a started thread: a single pill row (+ / text / send) while the
draft is one plain line (`useComposerSingleRow`), the block otherwise, with permissions, model,
effort and the context ring in the status row under it. Above it, the capsule row
(`ComposerCapsuleRow`) and Synara's queue, which a Stop pauses (`holdQueuedComposerTurnsForStop`)
until Resume or a message sent by hand. A failed turn offers Synara's "Continue" (a turn of its
own with Synara's resume prompt) and "Change model".

Synara 0cf5ea460's right-dock changes (each thread's dock width, the subagents dock's model and
effort per row) are not reached: the page has no right dock. A folder dragged from an editor's
file tree is mentioned by path as Synara's desktop does (`editorDropPaths.ts`; Synara reads those
paths only under its desktop shell, the page runs beside its agent as the desktop does); a drag
that carries file URLs is the app's, as a Finder drop is.

Data the new UI reads that the backend does not send yet, so the page goes without it: a new
`/goal` on an idle thread (Synara sends `thread.meta.update` with `goal` and
`goalStartBehavior: "start-with-message"`, and its server records the goal, a visible
`/goal …` user message `goal:<commandId>` and a queued turn carrying `initialGoalStartedAt`
together; the backend keeps no goal and refuses the command, so the composer keeps the text and
a toast says why); an assistant's inline image
kept as an attachment (`ChatImageAttachment.sourcePath`: an image whose alias matches a markdown
image's path is drawn from `/attachments/<id>`, which the app serves); Stop on an idle thread the
engine quarantined (the footer offers it while the session's `lastError` starts with
`PROVIDER_DELIVERY_BLOCK_SUMMARY`, "Thread is blocked by an earlier provider failure", which the
engine never writes; were it written, that Stop would reach a settled thread and do nothing); turn
headers' stop provenance (`turn.stop-requested` activities with `payload.requestedBy: "user"`; the
page sends `requestedBy` on `thread.turn.interrupt`, which the backend ignores) and their start
time from the checkpoint (`OrchestrationCheckpointSummary.startedAt`); Claude's served speed
(`fast-mode.state` activities); the queue's pause on a usage limit (`account.rate-limited`);
"Fork from here" stopping at its message (`thread.fork.create.throughMessageId`, so it forks the
whole thread); and the recovery cursors (`OrchestrationThreadDetailSnapshot.historyRevisionSequence`,
`OrchestrationEventMetadata.checkpointRuntimeSequence`, `OrchestrationThreadActivity.sequenceSource`).
Also: a running turn's diff in full (Synara's server answers `orchestration.getTurnDiff` for a turn
whose summary is a `provider-diff:` placeholder, `status: "missing"`, from the patch it captured
live; the page asks with the cache scope and `liveSnapshot` DiffPanel uses, and shows what the
backend returns); a Claude subagent's own model on its thread (Synara reports the model of the
subagent's assistant messages as thread metadata; here the child shows the model its launch named,
or its parent's); and the end of every subagent task a stop or a crash leaves open (Synara appends
a `stopped` `task.completed` carrying the launching call; here a card of a session that is
`stopped` reads "Stopped" from the session alone, and an open task of a live session still counts).
Synara 3e72c70's task continuation after a usage limit is not reached either: its setting
(`autoResumeAfterUsageLimits`) is off by default and has no switch in the app, and the composer's
usage-limit recovery banner reads thread state the backend never keeps.

The diff panel is DiffPanel's turn view only (TurnDiffPanel.tsx): no working-tree, staged,
branch or compare-ref scopes, no blame, no file tree, no commit and push, since all of them read
git through methods the app does not serve. A fork to a new worktree is not offered: Synara
sends it with `envMode: "worktree"` and no path and creates the worktree on the first send,
and a chat here has no worktree of its own, so the engine refuses it (a typed `/fork worktree`
ends in Synara's "Could not fork thread" toast with the engine's reason).

**Subagents** go Synara's way: the transcript folds a subagent launch into Synara's
`SubagentRunCard` where the tool call ran (`useChatWorkLog`'s `foldSubagentRunWorkEntries`), fed
through `SubagentRunContext` as ChatView feeds it, and while the newest card with subagents at work
is off screen a floating "N running" chip (`SubagentRunningChip`) brings it back. Above the
composer, ChatView's "N agents running" capsule (`ComposerRunningAgentsCapsule`) counts every agent
still at work across the thread, during the turn and after it (`scanSubagentRunCards`,
`deriveRunningSubagentTasks`, `createRunningChildThreadIdsSelector`, `summarizeRunningAgents`), and
a click scrolls to the newest one's card; while it shows, the chip stays hidden. Liveness follows
the root thread's session: once it is `stopped`, nothing it launched is counted as running. Synara keeps the
subagents' own threads in its store through detail subscriptions; the app pushes only the thread
on screen, so `relatedThreads.ts` reads them with `orchestration.getThreadDetailSnapshot` (and, on a
subagent's page, its parent and siblings), again whenever the thread on screen changes, at most
every 500 ms. A card's row opens the subagent's thread through `openThread`; Stop (and the card's
Stop all) sends `thread.turn.interrupt` for the subagent's thread (`useSubagentRunControls`), which
stops that subagent only; "Run in background" is not offered. A subagent's thread opens read-only
(`readOnly` in the context) under Synara's `SubagentThreadIntro`, which names the parent and leads
back to it: it follows its parent's agent, and messaging a running subagent is not ported.

On a read-only page (a terminal session's transcript) there is no composer, so no queue, and the
transcript offers no edit, revert, undo or fork; the approval and question panels, the turn diff
and find still work.

A user's image attachments load from the page's own scheme: Synara resolves `/attachments/<id>`
against `location.origin`, which WebKit reports as `cascade-chat://page` for the page (checked
in a real web view by `chatPageResolvesAttachmentURLsOnItsScheme`), and the app answers that
path through `attachments.read`. Other images Synara loads over HTTP (local image previews, generated
images) do not load: the page has no network.
