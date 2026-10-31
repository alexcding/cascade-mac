# cascade-chat and Synara

This crate is a Rust port of the provider layer of [Synara](https://github.com/Emanuele-web04/synara)
(MIT), the part that drives agent CLIs over their JSON protocols and folds what they say into
chat threads. It is kept shaped like Synara's TypeScript, file for file, so that a change
upstream can be found here and ported by hand.

**Ported from:** `c6ce7f7a0dfc5c4e31fb85c217a188885c99180e` (2026-10-05).

To take a newer Synara: diff the upstream files below between the pinned commit and the new
one, port each hunk into the mapped file, then move the pin. Do not reshape a mapped file
beyond what Rust needs; a file that drifts from its source cannot be updated from it.

**Cherry-picked since the pin** (the pin stays until everything between it and a newer commit
that applies is ported):

- `4b2441d10` Claude permission fixes (approval pins `--permission-mode default`), `60dc4e667`
  Codex terminal notifications for an older turn, `4e79063ac` streaming messages finalized on
  session exit, `ec8c940e0` idle threads stay settled when access changes.
- `0f8194de0` `turn/moderationMetadata` (with `item/autoApprovalReview/started`) kept out of
  the transcript; `8cd655901` "no rollout found" is a recoverable resume error; `d5a91276b`
  Codex `guardianWarning`/`warning` as warning activities (`codex.<method>`), an approval
  review's approval dropped; `540ba4a11` `--src-prefix=a/ --dst-prefix=b/` on every checkpoint
  diff, whatever the person's `diff.noprefix`.
- `1b4252570` a Claude subagent's resolved model (its assistant messages' `model`) is reported
  as `thread.metadata.updated` and set on its child thread, never the parent.
- `a8ba57587` (server half) a session stop ends every live task with `stopped` and its
  launching call (`toolUseId`), skipping tasks already ended; at start, tasks a dead runtime left
  open on a thread whose session was not stopped, or a subagent child of one, get a `stopped`
  end (`findRestartOrphanedTasks`, in `engine.rs`), and that session is then stored as stopped (no CLI outlives a run), so the next start reads the thread no more. `task.completed` carries `toolUseId`, and
  `task_notification` names its run's. Not ported: re-publishing a background run's launching
  item (`emitSubagentFinalState`; no background runs here), the per-task turn ids.
- `94407ef8e`, `99b090d91` a running Codex turn's diff is its streamed cumulative patch,
  rebuilt from the turn's start in a private index (`CheckpointStore::diff_provider_patch`);
  each parsed revision is a placeholder ref of its own; an interrupted turn's captured end
  (status missing, its canonical turn ref) is a readable single-turn diff. Synara reads the
  patch back from its runtime event journal by the placeholder's event id; here the turn's
  latest revision is kept with ingestion's placeholder and handed over only for that exact ref.
  Not ported: the git-derived live preview of providers without a streamed patch (Claude) and
  its revisioned `turn-live` refs, which nothing here writes.
- `4cd66c35d` a spawn into a missing working folder names the folder (`process.rs`).
- From `29b11e105..0cf5ea460`: `908ba5065` a Claude `success` result carrying `is_error` fails
  its turn. `3f55b77ef` (part): a provider failure's `detail`, a `runtime.error` message, a failed
  turn's `errorMessage` and a Codex request error show their first line without an inline stack
  frame (`sanitize_user_facing_error_message`), so the Claude CLI's stderr tail, which Synara's SDK
  error does not carry, is joined on one line (`stderr_tail_message`); a command's elapsed-time snapshots (Codex
  `command_execution` `item.updated`, Claude `Bash` `tool.progress`) update one row
  (`provider-command-progress:<key>`) that keeps its first place, per runtime generation and turn,
  through `stableActivityById` bounded at its 2,048 entries (no TTL);
  an interrupt's late outcome neither settles nor stops a turn or session that replaced the one it
  was for (`interrupt_target_replaced`), and only reports; a Stop of a thread with nothing running
  calls no provider and appends no error row. `b1dca5b25` a Claude Stop whose interrupt times out
  shows no interrupt failure once the session stops; it is reported only if the stop fails. Not
  ported from `3f55b77ef`: the durable Stop receipts, lifecycle-generation fences and retries of
  `ProviderService` (no event store or delivery replay here), `preserveQueuedWork` (both providers
  steer natively, so no steer reaches the interrupt path), the `active-turn-unavailable`
  escalation (no adapter reports it). Not ported, as they fix Synara's SDK runtime, delivery
  recovery or features this crate does not have: `92a3b771a`, `7ff3f26ac` (a steer here is
  prepared and written within one command of the session's one task, so no turn can end between
  them), `dfb6416d5`, `e5303d7b1`, `6300b86fc`, `ddab94e31` (uncertain-send recovery leases,
  quarantine, stop-control receipts), `13a6333b7` (VCS notices are not ported), `e730d195f`,
  `d6eaa4306` (goals: a `thread.meta.update` carrying a goal field is refused, `GoalsUnsupported`,
  so the page keeps a `/goal` in the composer rather than taking it as done), `d72b8cf47` (assistant image snapshots need Synara's managed attachments;
  its optional `sourcePath` and `attachments` fields are left out of the contracts), and the
  web-only `555a74112`, `dd5373847`, `6c5939957`, `1f05cb442`. Every contract change in the range
  is optional, so nothing this crate sends lacks a field the new schemas require.

## File map

`S` = `apps/server/src`, `C` = `packages/contracts/src`.

| Here | Synara |
|---|---|
| `src/contracts/base.rs` | `C/baseSchemas.ts` (ids, timestamps) |
| `src/contracts/provider_runtime.rs` | `C/providerRuntime.ts` |
| `src/contracts/provider.rs` | `C/provider.ts` |
| `src/contracts/orchestration.rs` | `C/orchestration.ts` (threads, messages, activities, commands, events; spaces, projects, sidechats and handoffs left out) |
| `src/contracts/model.rs` | `C/model.ts` (Claude and Codex options) |
| `src/provider/adapter.rs` | `S/provider/Services/ProviderAdapter.ts` |
| `src/provider/attachment_projection.rs` | `S/provider/attachmentProjection.ts`, and from `S/attachmentStore.ts` the flat layout's paths and ids (`attachmentRelativePath`, `resolveAttachmentPathById`, the id pattern) |
| `src/provider/claude/adapter.rs` | `S/provider/Layers/ClaudeAdapter.ts` |
| `src/provider/claude/protocol.rs` | none: the `claude` stream-json wire, which Synara reaches through `@anthropic-ai/claude-agent-sdk` (see below) |
| `src/provider/codex/transport.rs` | `S/codexAppServerTransport.ts`, `packages/shared/src/jsonrpc-stdio.ts` |
| `src/provider/codex/app_server_manager.rs` | `S/codexAppServerManager.ts` |
| `src/provider/codex/adapter.rs` | `S/provider/Layers/CodexAdapter.ts` |
| `src/provider/codex/turn_input.rs` | `S/codexTurnInput.ts` |
| `src/orchestration/decider.rs` | `S/orchestration/decider.ts` (thread commands, `thread.fork.create` included), `S/orchestration/commandInvariants.ts` (single-thread invariants), `S/orchestration/messageTurnId.ts` |
| `src/orchestration/fork_thread_title.rs` | `S/orchestration/forkThreadTitle.ts` |
| `src/orchestration/handoff.rs` | `S/orchestration/handoff.ts` (`buildImportedMessagesBootstrapText` alone, for the knowledge recap below) |
| `src/orchestration/projector.rs` | `S/orchestration/projector.ts` (thread events), `S/orchestration/turnLifecycle.ts`, `S/orchestration/turnStartSession.ts` |
| `src/orchestration/ingestion.rs` | `S/orchestration/Layers/ProviderRuntimeIngestion.ts`, with `ensureSubagentThread` split with the engine (below) |
| `src/orchestration/activity_projection.rs` | `S/orchestration/providerRuntimeActivityProjection.ts`, `providerRuntimeProgressKey` and `providerRuntimeCommandProgressKey` of `S/orchestration/providerRuntimeProgressCoalescing.ts`, `sanitizeUserFacingErrorMessage` of `packages/shared/src/errorMessages.ts` |
| `src/orchestration/subagents.rs` | `packages/shared/src/subagents.ts` (receiver ids, identity hints and their directory) |
| `src/orchestration/engine.rs` | `S/orchestration/Layers/OrchestrationEngine.ts` and `S/provider/Layers/ProviderService.ts`, reduced to what a single-user app needs: one task owning threads, sessions and the store; the shell snapshot of `S/orchestration/Layers/ProjectionSnapshotQuery.ts` (`getShellSnapshot`); from `S/orchestration/startupTurnReconciliation.ts` the orphaned tasks (`findRestartOrphanedTasks`, `planOrphanedTaskCommands`) |
| `src/orchestration/reactor.rs` | `S/orchestration/Layers/ProviderCommandReactor.ts` (`processDomainEvent` and its handlers, the fork branch of `ensureSessionForThread`), `ProviderService.forkThread`, and `S/orchestration/Layers/CheckpointReactor.ts` (capture, diff, revert) |
| `src/checkpointing/store.rs` | `S/checkpointing/Layers/CheckpointStore.ts`, the ref names of `S/checkpointing/Utils.ts` (under `refs/cascade/checkpoints`, with the managed-family helpers) |
| `src/checkpointing/diff_query.rs` | `S/checkpointing/Layers/CheckpointDiffQuery.ts` (`orchestration.getTurnDiff`, `orchestration.getFullThreadDiff`) |
| `src/persistence/store.rs` | `S/persistence/Layers/*` (read model tables, not the event store) |
| `src/text_generation.rs` | `S/git/Services/TextGeneration.ts` (`generateThreadTitle`), `S/git/textGenerationShared.ts` (`buildThreadTitlePrompt`), `packages/shared/src/chatThreads.ts` (title sanitizing and checks); the CLI run of `S/git/Layers/ClaudeTextGeneration.ts` / `CodexTextGeneration.ts` is the backend's (`cascade-backend/src/chat/titles.rs`) |

## Where this differs from Synara, on purpose

- **Claude without the SDK.** Synara drives `claude` through the Agent SDK's `query()`. Rust has
  no SDK, so `claude/protocol.rs` speaks the wire the SDK speaks: the CLI launched with
  `--output-format stream-json --input-format stream-json --verbose --permission-prompt-tool stdio`,
  user messages and `control_request`s on stdin, messages and `control_request`s
  (`can_use_tool`) on stdout. Read from `@anthropic-ai/claude-agent-sdk` 0.3.259 `sdk.mjs`
  (`ProcessTransport` arguments, `Query.request`, `processControlRequest`). The adapter keeps
  ClaudeAdapter.ts's names and mapping; only the call into the SDK is replaced.
- **A read model, not an event store.** Synara persists every orchestration event and projects
  them. Here the store keeps the projection (threads, messages, activities, plans, sessions)
  and the events are only pushed to the app as they happen, carrying a per-thread `sequence` so
  a client can tell it missed one and read the thread again.
- **Forks.** Synara forks a thread's provider conversation eagerly in `ProviderService.forkThread`,
  through each adapter's `forkThread`. Here the fork happens when the fork's first session starts:
  the reactor hands the start the source's resume cursor (`forkSourceResumeCursor`), and Codex
  opens its thread with `thread/fork` (as Synara's `startSession` can), while Claude, which
  Synara forks with the SDK's `forkSession` (a copy of the transcript file), is launched with
  `--resume <source> --fork-session --session-id <new>`. `--resume-session-at` is not passed:
  the stored cursor's pin can lag the live session by a turn (the live session is not asked), and
  a source with a turn in flight is not forked natively (ClaudeAdapter.ts:7287), so the whole
  source transcript is the settled one. Without a native fork (no source conversation, another
  provider, a busy Claude source) the fork starts a conversation of its own; Synara's
  retained-transcript bootstrap for that case is not ported. The fork's title comes from its
  lineage (`forkThreadTitle.ts`) and its source thread must be in the same project. A fork
  forks its source once: when its own first session binds, `chat.db` notes it (`fork_bindings`,
  which a revert, an edit, a rollback or a stale resume that clears `provider_sessions` leaves
  alone), and from then on the source is neither loaded with it nor forked again.
- **Knowledge from another conversation (Cascade, not Synara).** `thread.create` may carry
  `knowledgeSource: {provider, conversationId, model?, recap?}` (`ThreadKnowledgeSource`): a chat
  started in a terminal session's pane that begins with what the session's agent knows. The engine
  keeps it in `knowledge_sources` and appends Synara's `provider.handoff` activity (no turn) so the
  page draws its `ProviderHandoffDivider`; no message is imported. The chat's first session on the
  same provider forks `conversationId` the way a fork forks its source (`forkSourceResumeCursor`,
  the cursor `{threadId, resume}` both adapters read); on another provider its first turn's input is
  wrapped as Synara's handoff bootstrap (`<handoff_context>` + `<latest_user_message>`,
  `wrapProviderContext`) with `recap`, which the backend builds from the terminal transcript with
  `handoff.rs`. It stays pending until a turn carrying it (forked or recapped) has started; a
  conversation reset before any turn of the chat completed (a revert, an edit, a stale resume) takes
  it out of the conversation, and the next start forks or recaps it again. Once a turn has completed
  it is used up for good, noted in `fork_bindings` as a fork's binding is. The message the person
  sent is stored and shown unwrapped. `ChatEngine::chat_conversations` names every conversation a
  chat holds (`provider_sessions`), so the backend never takes one for a session's agent's.
- **A revert or an edit takes back the chat's own changes, not the folder.** Synara's full-scope
  revert and its edit-and-resend restore the whole workspace to the target checkpoint
  (`restoreCheckpoint`: `git restore --worktree --staged -- .` and `git clean -fd`), which also
  undoes what the person did in their checkout, or a session's terminal agent did in the worktree a
  pane chat shares, since the turn. Here both reverse each removed turn's own diff, newest first,
  from its turn-start checkpoint (or the turn before's end) to its end, with the files-scope undo's
  machinery (`reverse_checkpoint_diff`: a strict reverse apply, then a three-way one through a
  throwaway index) — `CheckpointStore::reverse_checkpoint_diffs`. Every turn is taken back from its
  refs, whatever its summary lists (a summary with no files may be one that could not be computed);
  a files-scope undo moves the turn's start ref onto its recaptured end, so an undone turn reverses
  as nothing. The patch goes to a file, so Synara's 10 MB diff cap does not apply to it. Where
  Synara then resets each path's index entry to the turn's start, only an entry the turn left (the
  agent staged its change) goes back; the person's staging, and an untracked file, stay. Paths are
  passed to git as names (`GIT_LITERAL_PATHSPECS`). It is all or nothing: every reverse is first
  tried on a throwaway index mirroring the folder (seeded from the person's index for its stat
  cache), and a conflict refuses the revert with `checkpoint.revert.failed` (an edit, with the
  session error) before anything changes or a rescue snapshot is taken — the folder, the
  conversation and the CLI stay as they were. An edit is tried before its CLI is stopped, and again
  once it has. A reverse that still fails for real puts back the paths the reverses touched from the
  rescue snapshot taken just before, with their index entries; the snapshot is deleted once it is
  not needed, and kept (and named in the error) only when that put-back fails.
  `restoreCheckpoint` is not ported. What the person wrote into a file during a turn is part of
  that turn's diff, and goes with it.
- **A fork that names no worktree keeps its source's.** Synara's page always sends a worktree-backed
  source's path for "Fork Into Local"; `decide_fork_create` falls back to the source's
  `worktreePath` when the command has none, so a pane chat's forks stay tagged with its session.
- **Forks into a new worktree are refused.** Synara's "Fork Into New Worktree" sends
  `envMode: "worktree"` with no path and its server makes the worktree on the first send.
  Nothing here makes one (a chat has no worktree of its own, and a Cascade worktree without a
  session is invisible), so `decide_fork_create` refuses that fork as invalid; a fork that names
  its worktree is allowed.
- **Review.** Codex's native review (`review/start`, `reviewTurnIds`, `settleTrackedReview` and
  the `exitedReviewMode` settle) is ported; the review recovery of `interruptTurn` after an
  interrupt timeout (`thread/read`, `findLatestReviewTurnId`) is not. Claude has no native
  review, as in Synara.
- **Shell snapshot.** Sequences are per thread here, so `snapshotSequence` is the sum of the
  threads' sequences; `spaces` and `projects` are always empty (projects are the app's).
- **Attachments are read by a call**, `attachments.read {attachmentId}`, where Synara serves an
  HTTP route; ids are checked against Synara's pattern and only a regular file in the
  attachments folder is read.
- **Subagent threads.** As in Synara, a Claude Task/Agent tool's subagent runs in a scoped context
  of the session (`ensureSubagentRun`; here the session's context swaps a run's scope in for as long
  as a handler runs, `ClaudeScope`), and every event it makes carries `providerRefs` naming it
  (`providerThreadId` = the tool use id, `providerParentThreadId` = the parent thread). The CLI
  forwards a subagent's text because `initialize` asks with `forwardSubagentText`. Codex child
  conversations already carried the same refs. Ingestion's `ensureSubagentThread` is split: the
  pure part (`subagent_routing`, `ensure_subagent_thread_command`, the cap of
  `MAX_NATIVE_CHILDREN_PER_PARENT_TURN`) is in `ingestion.rs`, and the engine (`on_runtime`,
  `ensure_subagent_thread`) reads the child, dispatches its `thread.create` or `thread.meta.update`
  and ingests a subagent's event against the child (`ingest_subagent_runtime`), leaving the parent
  session's binding, checkpoints and queue alone as ProviderService does. A child's id is
  `subagent:<parent>:<provider thread id>`. Stopping one (`thread.turn.interrupt` on the child)
  stops only that run: Claude's `stop_task`, Codex's `turn/interrupt` on the child conversation.
  Archive, unarchive and delete take a thread's subagent subtree along (decider.ts:1497-1555, done
  by the engine, which sees all threads). Not ported: messaging a running subagent
  (`steerSubagent`, which needs the SDK's PreToolUse hook), so the engine refuses a send to a child
  thread and the app shows it read-only; per-task token meters (`emitTaskUsageSnapshot`); the
  workflow runtime.
- **A turn still being sent holds the queue.** A turn start that goes straight to the provider
  takes the same reservation a queued one does, until its turn ends or fails to start, so a
  message sent meanwhile (while the CLI starts, or a checkpoint is taken) is queued behind it
  rather than sent beside it, which made the Claude adapter close the first turn empty.
- **Generated titles.** As `maybeGenerateAndRenameThreadTitleForFirstTurn`, the first user
  message of a thread with the generic title names it, but the first-message fallback is applied at
  once and the generated title replaces it when it comes (Synara applies the fallback only without a
  text model or on failure). The host hands the engine a `TextGeneration` (`ChatEngineConfig`); the
  backend's runs `claude -p --safe-mode` on `haiku` (a Codex chat too, when Claude is installed;
  else `codex exec` on the chat's model at low effort), not a configured git-writing model.
  `expectedTitleSequence` is kept as a pending marker on the thread's entry: any title set after the
  fallback clears it, and the generated title is dropped. Conversation-context regeneration
  (`regenerateThreadTitle`) is not ported.
- **The gateway token of a Claude chat.** Synara's `buildClaudeMcpServers` writes the bearer token
  into the server's headers, and so into the CLI's `--mcp-config` argument, which every user's `ps`
  shows. Here the header names `${CASCADE_GATEWAY_TOKEN}`, which the CLI expands, and the token is in
  the child's environment (`agent_gateway.rs` `CLAUDE_TOKEN_VARIABLE`). Codex's is sent over its
  app-server pipe, as in Synara.
- **The agent gateway's writes.** Synara's gateway (`S/agentGateway/mcpTransport.ts`) binds a tool
  call's write authority to the caller thread's running turn (`latestTurn`, while `running`) when the
  request arrives, checks it again (`assertCallerTurnActive`) and dispatches `thread.activity.append`;
  an identical retry collides on its command id and succeeds. Here the gateway is the backend's
  (`cascade-backend/src/gateway/`) and the engine is one task, so it asks `ChatEngine::running_turn`
  for the turn, and `ChatEngine::append_turn_activity` checks that turn still runs and appends on the
  engine's task in one step (refused as `ChatError::Invalid` otherwise); an activity whose id the
  thread already has is that retry and appends nothing. The inline visual tool
  (`S/agentGateway/inlineVisualTools.ts`, `S/inlineVisualStore.ts`, `C/inlineVisual.ts`,
  `C/inlineVisualSpec.ts`, `packages/shared/src/inlineVisualFormula.ts`) is ported in
  `cascade-backend/src/gateway/visuals.rs` and `visuals/{store,spec,formula}.rs`, its store under this
  engine's `attachments/visuals/`, removed with a deleted thread by the backend on the engine's
  `Removed` event, and its `orchestration.getInlineVisual` read in `cascade-backend/src/chat.rs`.
- **Providers.** Claude and Codex. The ACP family (Cursor, Droid, Grok, Devin, OMP), OpenCode,
  Pi and Antigravity are not ported yet.

## Recorded fixtures

`tests/fixtures/*.jsonl` are real sessions recorded with `tests/fixtures/*_probe.py` (one turn
that runs a shell command after an approval; `claude_subagent_probe.py`, a turn whose foreground
general-purpose subagent runs `ls` after an approval), scrubbed of home paths and account details. To
record again after a CLI update, run the probe in an empty folder and scrub the same way.
