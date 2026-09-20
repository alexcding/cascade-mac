# Native upgrade and rollback data

The Rust backend owns recovery for the native app. Backup commands do not open
application stores, run schema migrations, start a server, or invoke GitHub/Jira.
The default data directory is `~/Library/Application Support/Craft`; recovery
commands always require explicit paths.

## Backup, verify, and restore

From a checkout, build `crates/craft-backend` and run:

```sh
crates/craft-backend/target/debug/craft-backend backup \
  '/absolute/path/to/data' '/absolute/path/to/new-backup'
crates/craft-backend/target/debug/craft-backend verify \
  '/absolute/path/to/new-backup'
crates/craft-backend/target/debug/craft-backend restore \
  '/absolute/path/to/new-backup' '/absolute/path/to/new-restored-data'
```

From the installed app, use the same arguments with:

```sh
'/Applications/Craft.app/Contents/Helpers/craft-backend' backup \
  '/absolute/path/to/data' '/absolute/path/to/new-backup'
```

Save editor buffers and quit clients/backends for a checkpoint across all files.
An online backup includes committed WAL contents in each SQLite database, but
separate databases and the native page cache are not one cross-file transaction.
Unsaved editor text, worktree contents and agent conversation files need separate
preservation.

Backup and restore destinations must not exist, even as empty directories; their
parents must exist. Files use mode `0600`, directories `0700`. The tool validates
allowlisted paths, rejects symlink inputs/components and SQLite snapshot sidecars,
checks SHA-256 digests and SQLite integrity, and publishes a manifest or restore
receipt only after the copied data has been flushed. Interrupted operations may
leave incomplete output for inspection. Choose a fresh path for a retry.

Format-1 snapshots from the old Node tool remain readable, including `config.db`
under its original filename. Restoring never overwrites the source or a live data
directory. Use a **pre-upgrade** snapshot for rollback and keep the matching old
app: a newer database is not guaranteed to work with an older backend.

Open a restored directory with `--data-dir /absolute/path/to/new-restored-data`
and an unused `--backend-port`. Stop the current app first. A different data
directory alone does not change the PTY daemon's default socket.

## Automatic packaged startup checkpoint

With `CRAFT_PACKAGED=1`, startup acquires the existing SQLite ownership lock in
`DATA_DIR/native-backups/owner.db` before opening any application store. The lock
remains held until process exit and coordinates with older packaged Node owners.
Standalone development and external backends do not acquire this lease; stop them
before upgrading shared data.

First adoption of existing data and every release change creates and verifies a
`native-backups/checkpoint-<UUID>` snapshot before database migrations. Fresh data
records the release without an empty snapshot. Release identity hashes the Rust
executable plus the bundled native executable and Info.plist; repeat launches of
the same bundle reuse and verify the saved checkpoint. A changed app/backend or
rollback creates another checkpoint. Backups are not pruned automatically.

`last-launch.json` is atomically replaced only after the checkpoint is complete.
The format remains compatible with previous launch receipts. A corrupt receipt or
missing/damaged previous checkpoint stops startup instead of silently replacing
the rollback data. Errors appear in `native-backend.log`. The native host allows
up to two minutes for startup; cancellation terminates its owned backend.

## State inventory

| State | Storage and handling |
| --- | --- |
| Projects, workflows, automation settings, CLI preferences, PR/Jira links | `craft.db`; included without rewriting schema or unknown columns. |
| Worktree sessions, pinned state, CLI conversation IDs | `craft.db`; included. Actual checkout files and agent conversation stores remain in their existing locations. |
| Viewer tabs, document paths/order/history, native context settings | `craft.db`; included. Native `native.context.*` settings coexist with web tab rows. |
| Pending native context writes | `ptyd-native-spike/page-tabs.json`; included when present. This is page metadata, not unsaved editor text. |
| Review requested/viewed timestamps | `craft.db`; included, avoiding an artificial reset of acknowledged reviews on restore. |
| Activity and diagnostic history | `logs.db`; included when present as a separate consistent SQLite snapshot. |
| Older durable filename | If `craft.db` is absent, `config.db` is captured/restored under its original name. Backup does not trigger the application's legacy rename or destructive schema changes. |
| GitHub/Jira snapshots | `data.db`; regenerable, omitted. The normal poller repopulates the restored installation. |
| Terminal screen state and live process metadata | Daemon memory and PTY manifests; omitted. Closing or updating Craft terminates its PTYs; saved CLI conversation IDs recreate and resume sessions on launch. |
| Native sidebar selection/collapse, window geometry | AppKit/UserDefaults in `com.alexcding.craft`; left in place during same-bundle upgrades. Not part of this data-directory snapshot. |
| Native cached settings and pending preference writes | UserDefaults `native.*`; not copied by this tool. Synced values are in SQLite. Reconnect and let pending writes finish before taking an offline checkpoint. |
| Tauri localStorage appearance | Theme is mirrored to SQLite; the database remains authoritative. |
| Tauri localStorage layout | `craft.prRatio`, `craft.projCollapsed`, `craft.sidebarWidth`, `craft.histSplit` are web layout preferences. Native layouts use their own defaults; the web values are left untouched for rollback. |
| Remote website logins/cookies, OS notification/login approvals | Browser and macOS stores; not moved by this tool. Cross-host login migration and real OS upgrade behavior still require acceptance. |

## Validation status

The Rust recovery implementation and release helper compile. Further unit/UI
execution remains deferred by user direction. Earlier Node snapshot tests describe
the previous implementation; they are not evidence that the Rust recovery paths
have been exercised. Manual review, signed updates and clean-Mac acceptance remain
separate from the implementation and local packaging work.
