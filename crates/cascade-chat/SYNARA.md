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
| `src/orchestration/projector.rs` | `S/orchestration/projector.ts` (thread events), `S/orchestration/turnLifecycle.ts`, `S/orchestration/turnStartSession.ts` |
| `src/orchestration/ingestion.rs` | `S/orchestration/Layers/ProviderRuntimeIngestion.ts` |
| `src/orchestration/activity_projection.rs` | `S/orchestration/providerRuntimeActivityProjection.ts` |
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
- **Providers.** Claude and Codex. The ACP family (Cursor, Droid, Grok, Devin, OMP), OpenCode,
  Pi and Antigravity are not ported yet.

## Recorded fixtures

`tests/fixtures/*.jsonl` are real sessions recorded with `tests/fixtures/*_probe.py` (one turn
that runs a shell command after an approval), scrubbed of home paths and account details. To
record again after a CLI update, run the probe in an empty folder and scrub the same way.
