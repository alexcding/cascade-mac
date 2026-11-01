# The device layer and Synara

`src/device/` is a port of Synara's iOS Simulator device backend, and
`vendor/synara-device-helper/` is Synara's native helper, copied verbatim.

Pinned to Synara commit `566efb1b132b97a1d76e86229be8a177abb9e435`
(`vendor/synara-device-helper/MANIFEST.json` records it with every file's SHA-256, and
`tests/vendor.rs` fails when a vendored file differs from it), with the later device changes up to
`d419d5d40a2dd65214ddb43b59ed96f5e43951a8` ported on top: that commit ("release idle agent-booted
simulators after turns settle") is the only one since the pin to touch `apps/server/src/device/`,
`agentGateway/deviceTools.ts`, the helper or the device contracts. Its manager and tool changes are
in `manager.rs` and `tools.rs`, its tests in `tests/manager.rs` and `tests/tools.rs`; its
`ProviderRuntimeIngestion.ts` part, which tells the manager a turn settled, is `service.rs` and
the turn hooks in `integrations.rs` (see "Turn leases" below).

## Vendored helper

`vendor/synara-device-helper/` is `apps/server/native/device-helper/` (`build.sh`,
`device-helper.sb`, `HEADER.md`, `Sources/*`, `Tests/*`) plus the repository's `LICENSE`. Never
edit these files: to take a newer helper, copy the folder again from Synara, regenerate
`MANIFEST.json`, update the pin and `cache::VENDORED_FILES` if files were added or removed, and
update the revision `tests/vendor.rs` pins (Synara's `readDeviceHelperSourceRevision` over the new
tree; Node computes it).

The files are compiled into the crate (`cache::VENDORED_FILES`, `include_bytes!`) and written out
at first use to `<cache root>/<key>/source/`, where `build.sh` compiles them and the sandbox
profile is read from. No app-bundle resource is involved.

## File map

| Rust (`src/device/`) | Synara |
|---|---|
| `contracts.rs` | `packages/contracts/src/device.ts` (types only) |
| `backend.rs` | `apps/server/src/device/DeviceBackend.ts` |
| `ios_simulator.rs` | `apps/server/src/device/IosSimulatorBackend.ts` |
| `helper.rs` | `apps/server/src/device/helperClient.ts` (and the JSON-RPC stdio framing of `packages/shared/src/jsonrpc-stdio.ts` it uses) |
| `sandbox.rs` | `apps/server/src/device/helperSandbox.ts` |
| `capabilities.rs` | `apps/server/src/device/helperCapabilities.ts` |
| `cache.rs` | `packages/shared/src/deviceHelperCache.ts` |
| `frame.rs` | `packages/shared/src/deviceFrame.ts`, the envelope codec of `packages/shared/src/frameTransport.ts`, `packages/shared/src/lengthPrefixedRecords.ts` |
| `process.rs` | `apps/server/src/processRunner.ts` (`runProcess` with `allowNonZeroExit`) |
| `ui_targeting.rs` | `apps/server/src/device/uiTreeTargeting.ts` |
| `tree_targeting.rs` | `packages/shared/src/uiTreeTargeting.ts` |
| `ui_snapshot.rs` | `apps/server/src/device/deviceUiSnapshot.ts` |
| `logs.rs` | `apps/server/src/device/deviceLogs.ts` |
| `catalogue.rs` | `apps/server/src/device/deviceTypeCatalogue.ts` |
| `boot_ownership.rs` | `apps/server/src/device/bootOwnership.ts` |
| `manager.rs` | `apps/server/src/device/DeviceManager.ts` (and the contract's `ThreadDeviceState`, `DeviceBootResult`, `DeviceEvent`) |
| `tools.rs` | `apps/server/src/agentGateway/deviceTools.ts`, plus the device line of `harnessPolicy.ts` |
| `transport.rs` | `packages/shared/src/frameTransport.ts` (`FrameTransport`) and `apps/server/src/device/deviceFrameTransport.ts` |
| `frames.rs` | `apps/server/src/device/deviceFrameRoute.ts` |
| `routes.rs` | `apps/server/src/device/wsDeviceHandlers.ts` |
| `service.rs` | `apps/server/src/device/Layers/DeviceService.ts` |
| `tests/fake.rs` | `apps/server/src/device/FakeDeviceBackend.ts` |
| `tests/*.rs` | the matching `*.test.ts` files, where they test logic |

## Deliberate differences

- **A drag follows the pointer.** Synara's pane sends a drag as one `swipe` on release, so the
  screen replays it afterwards. Cascade's pane holds the finger down through the helper's own
  `touch` method once a press moves past a tap: `POST /api/device/touch {udid, phase, x, y}`
  (`routes.rs` `touch`, `DeviceBackend::touch`), its moves sent one at a time and folded into the
  newest while one is in flight (`SimulatorPaneModel.handle`). A press released before it moved is
  still a tap, or a swipe if no drag was seen.
- **Names.** Cache root `~/Library/Caches/Cascade/device-helper/<key>/` (override
  `CASCADE_DEVICE_HELPER_CACHE`), with the sources beside the binary in `<key>/source/`; the binary
  keeps Synara's name, `synara-device-helper`, since `build.sh` writes it. Sandbox opt-out
  `CASCADE_DEVICE_HELPER_NO_SANDBOX`. Frame sockets in `$TMPDIR/cascade-device-frames-<8 hex>/`.
  Boot ownership in `<data>/device/boot-ownership.json`. The boot source a Cascade boot reports is
  `cascade`, and user-facing text says Cascade where Synara said Synara.
- **Processes go through Cascade's seams.** Short commands (`simctl`, `xcodebuild`, `xcode-select`,
  `sips`, `plutil`, `PlistBuddy`, `build.sh`) run through `cli` (`process.rs`), so they are
  resolved, grouped and timed out as every other command and scripted with
  `cli::ScriptedRunner` in tests. A failed command carries its stderr (or how it ended), not its
  stdout. The helper and its `--probe` are started through the chat engine's `Spawner`
  (`chat::CliSpawner`; `ScriptedSpawner` in tests). `simctl io recordVideo` has a seam of its own
  (`RecordingSpawner`), since it needs SIGINT, which `Spawner` cannot send.
- **Frames are broadcast.** `attachStream(udid, onFrame)` became `attach_stream(udid)` plus
  `subscribe_frames()`, a tokio broadcast of `{udid, frame}`, so the pane and the backend can both
  read one stream; `onStreamInterrupted` became `subscribe_interruptions()`.
- **Cancellation.** `typeText`'s `AbortSignal` is dropping the future, which stops it before the
  next chunk. Likewise a tool call's: dropped while it waits out an idle poweroff, it never reaches
  the device (Synara's `signal.throwIfAborted()` after admission), and its guards end its activity
  and its device use.
- **Coalescing.** Synara shares in-flight promises (`helperStart`, `helperCompilation`, the device
  list); the port holds an async lock for the same span, and the device list cache is invalidated
  by a generation that every mutating simctl command bumps. The keyboard-layout and executable
  caches keep answers rather than promises, so two first asks at once may both run.
- **Helper exit reason.** A Node exit reports code and signal; the `Spawner` reports only the code,
  so a signal reads `code=null, signal=unknown`.
- **Strings and order.** Lengths and clipping count characters, not UTF-16 units. JSON objects
  are read in key order rather than insertion order (`serde_json` without `preserve_order`), which
  only affects the order of runtimes in a device listing.
- **Owner, not thread.** The manager keys an attachment by its owner's working folder, not by chat
  thread: a chat's worktree (or folder), a terminal agent's working folder. Every agent working in
  one session shares the state that session's Simulator pane shows (`tools::owner_of`). The state
  is `{owner, version, attachedDeviceUdid, attachPhase, devices, agentActive, availability,
  lastError}`; the boot cap's candidates are `cascadeBooted`. A removed worktree is Synara's
  `handleThreadRemoved`, and so is a deleted chat: its `chat:<id>` owner always, its folder owner
  only when no other chat or session works there (`service::chat_removed`).
- **One task owns the manager's state** (Cascade's convention for engines): each stretch Synara runs
  between two `await`s is one step sent to that task, and the idle-shutdown timers are its
  deadlines. A viewer that subscribes marks its device wanted before it returns, so one that leaves
  at once stops the stream rather than racing its start. An idle poweroff under way, or the boot restoring
  one, is a `watch` in the state that consumers wait on (Synara's `idleShutdowns` promises), and
  the `finally` that ends a device call or an agent's activity is a guard whose `Drop` sends the
  step, so a dropped call still ends.
- **No approval gate on the tools.** The CLI's own permission prompt asks before an MCP tool runs,
  so the `DeviceApprovalRequired` path and its description sentence are gone. A chat caller still
  needs a running turn (Synara `requiresActiveTurn`); a terminal has none to check.
- **The pane's transport.** Native, not a WebSocket: the pane posts to `/api/device/*` and reads
  frames from a Unix socket per device (`POST /api/device/frames` names it), in the helper's own
  record format. A viewer joining a running stream with no keyframe cached gets the stream rebuilt
  (`requestKeyframe`). There is no `touch` route: the backend has no `touch`, as Synara's pane has
  none (it taps and swipes).
- **Turn leases.** A device an agent tool used stays leased to the caller's turn until it settles,
  and an agent's attachment alone keeps nothing up (Synara `agentDevicesByTurn`, d419d5d40). A
  turn is `AgentTurn { holder, id }`, the holder being the caller (`chat:<thread>`,
  `run:<run id>`) rather than the owner, since several callers share one owner; the leases live on
  the owner's attachment and go with it. Synara's ingestion ends the exact turn whose terminal
  event it saw; Cascade learns a turn settled without the chat engine's help:
  - **A chat**: the engine's `thread.session-set`, `thread.turn-diff-completed` and
    `thread.deleted` events, watched in the engine's `publish` (`service::releasing_devices`),
    send the backend to ask which turn runs now; every other turn the chat holds is released
    (`end_agent_turns_except`), but only turns that leased a device before the check began
    (`lease_mark`), so a late check never ends a newer turn. A deleted chat releases all its turns.
  - **A terminal agent**: its turn hooks. `UserPromptSubmit` (`/api/hooks/turn-start`) starts a
    turn for the run, `Stop` (`/api/hooks/turn-done`) ends it. A run whose agent never reported a
    turn (hooks not installed) leases nothing: its device's idle grace starts when its last device
    call returns, as Synara's call with no `callerTurnId`. A turn-start that finds a turn still
    held ends that one, its `Stop` lost, and so does `SessionStart` (`/clear`, `/resume`, a
    relaunch). Claude runs no `Stop` after an Esc interrupt, and the backend does not hear a
    terminal exit (cascade-ptyd tells the app), so a terminal's lease also lapses a grace
    (`DEVICE_IDLE_SHUTDOWN`) after the last device call of its turn (`DeviceUse.lapses`); the
    device then idles off after the usual grace, unless another call of the turn leases it again.
    A removed session's worktree drops its owner's leases with it.
  - A call admitted for a turn that settled before the call was counted would keep a lease no end
    is coming for; the tool call ends it itself when it ends, returned or dropped
    (`service::SettleCheck`).
  - A restoration after an idle poweroff runs on a task of its own that the waiting calls await, and
    a dropped boot gives its slot and its in-flight mark back (`BootGuard`), so a call cancelled
    mid-boot leaves nothing held.
- **The device helper's sources are not looked up** (`resolveDeviceHelperSourceDir`,
  `SYNARA_DEVICE_HELPER_SOURCE_DIR`): they are embedded.
