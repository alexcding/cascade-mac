# cascade-chat and Synara

This crate is a Rust port of the provider layer of [Synara](https://github.com/Emanuele-web04/synara)
(MIT), the part that drives agent CLIs over their JSON protocols and folds what they say into
chat threads. It is kept shaped like Synara's TypeScript, file for file, so that a change
upstream can be found here and ported by hand.

**Ported from:** `c6ce7f7a0dfc5c4e31fb85c217a188885c99180e` (2026-10-05).

To take a newer Synara: diff the upstream files below between the pinned commit and the new
one, port each hunk into the mapped file, then move the pin. Do not reshape a mapped file
beyond what Rust needs; a file that drifts from its source cannot be updated from it.

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
| `src/orchestration/activity_projection.rs` | `S/orchestration/providerRuntimeActivityProjection.ts` |
| `src/orchestration/subagents.rs` | `packages/shared/src/subagents.ts` (receiver ids, identity hints and their directory) |
| `src/orchestration/engine.rs` | `S/orchestration/Layers/OrchestrationEngine.ts` and `S/provider/Layers/ProviderService.ts`, reduced to what a single-user app needs: one task owning threads, sessions and the store; the shell snapshot of `S/orchestration/Layers/ProjectionSnapshotQuery.ts` (`getShellSnapshot`) |
| `src/orchestration/reactor.rs` | `S/orchestration/Layers/ProviderCommandReactor.ts` (`processDomainEvent` and its handlers, the fork branch of `ensureSessionForThread`), `ProviderService.forkThread`, and `S/orchestration/Layers/CheckpointReactor.ts` (capture, diff, revert) |
| `src/checkpointing/store.rs` | `S/checkpointing/Layers/CheckpointStore.ts`, the ref names of `S/checkpointing/Utils.ts` (under `refs/cascade/checkpoints`, with the managed-family helpers) |
| `src/checkpointing/diff_query.rs` | `S/checkpointing/Layers/CheckpointDiffQuery.ts` (`orchestration.getTurnDiff`, `orchestration.getFullThreadDiff`) |
| `src/persistence/store.rs` | `S/persistence/Layers/*` (read model tables, not the event store) |

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
- **Providers.** Claude and Codex. The ACP family (Cursor, Droid, Grok, Devin, OMP), OpenCode,
  Pi and Antigravity are not ported yet.

## Recorded fixtures

`tests/fixtures/*.jsonl` are real sessions recorded with `tests/fixtures/*_probe.py` (one turn
that runs a shell command after an approval; `claude_subagent_probe.py`, a turn whose foreground
general-purpose subagent runs `ls` after an approval), scrubbed of home paths and account details. To
record again after a CLI update, run the probe in an empty folder and scrub the same way.
