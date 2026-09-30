# Cascade Remote: the chat mirror (as built)

Status: **implemented on `feat/remote-chat`.** This supersedes the transport in
05-session-control.md. There is no direct connection, no listener and no terminal on the
phone. The Mac mirrors each live session's chat into the user's CloudKit private database.
The phone reads it there and writes messages and approvals back.

## Shape

```
 Cascade (Mac)                               iCloud (private DB, zone "Remote")          Cascade Remote (iPhone)
 ─────────────                               ──────────────────────────────────          ───────────────────────
 /api/agent/transcript ─► RemoteMirror ─────► Session / Turn / Permission  ──────────────► RemoteClient ─► SwiftUI
 (every 2 s, `since`)       │                                                                   │
 AgentMessageTyper ◄────────┴─────────────── Command (message, allow, deny) ◄───────────────────┘
 answerPermission                              status written back by the Mac
```

- **Sync**:
  - `RemoteSyncStore` (`macos/Services/Remote/Shared/`) is an actor around `CKSyncEngine`.
    `cascade-ios` compiles a copy of that folder: it is the wire format between the two apps,
    so **change both copies together**.
  - It keeps a local mirror of the zone and the engine's state in one JSON file, so a relaunch
    resumes from the change token.
  - Every record carries its value as JSON in one end-to-end encrypted field
    (`encryptedValues["payload"]`).
- **One writer per record**, so nothing needs merging:
  - Each Mac writes its own sessions, turns and permissions.
  - The phone creates commands addressed to one Mac.
  - Only that Mac updates a command's `status`/`message`, and it removes the command
    10 minutes later.
  - Every record carries its Mac's `hostID` (a random UUID, in the clear), so two Macs on one
    Apple Account mirror side by side without touching each other's records.
- **The Mac** (`RemoteMirror`, owned by `AppViewModel`, host protocol in
  `AppViewModel+Remote.swift`):
  - **Mirroring**: every 2 s it reads each live session's transcript with `since`. It maps the
    last 60 turns through `RemoteTurnMapper`, which caps text at 16 KB, tool output at 4 KB,
    thinking at 2 KB, and never mirrors file-change bodies. It saves only the turns whose
    encoded bytes changed. A session that ends is deleted along with its turns and requests.
  - **Messages**: a phone message is typed by `AgentMessageTyper`, the same sequence the chat
    uses (moved out of `SessionWorkspaceViewModel`). It is typed only once the agent's hooks
    show it at its prompt, with nothing asked and no approval open, waiting up to 60 s.
    Otherwise the command fails with a reason the phone shows.
  - **Freshness**: a command older than 2 minutes when read is refused, never typed.
    Commands run one at a time, oldest first.
  - **At most once**: a command is recorded as attempted (in `UserDefaults`) before anything
    is typed. One found still pending after a quit or crash is failed, never typed again.
  - **Approvals**: every `agent-permission` of a mirrored session is mirrored. When a request
    arrives with no chat on screen, it normally goes straight to the terminal (`pass`), as
    before. If nobody has touched the Mac for 2 minutes (`CGEventSource` idle time), it waits
    for the phone instead. It still falls back to the terminal after the hook's 280 s.
- **The phone** (Cascade Remote, in the separate `cascade-ios` repository):
  - It shows the session list and a chat for each session: turns, collapsible tool calls,
    approval cards and a composer.
  - A truncated approval offers only Deny, since nobody should approve what they weren't
    shown.
  - It fetches every 3 s while on screen, on top of CloudKit pushes.

## Turning it on

1. Copy `macos/Signing.local.xcconfig.example` to `macos/Signing.local.xcconfig` and set
   your team. The file is git-ignored.
   - Without it, the Mac app builds ad-hoc as before, and Settings → iPhone says the build
     isn't signed for iCloud.
   - `RemoteMirror.hasEntitlement()` checks before any CloudKit call, because
     `CKContainer` traps without the entitlement.
2. In the developer portal (or with Xcode's automatic signing and your account added):
   - Create the container `iCloud.com.alexcding.cascade`.
   - Enable iCloud (CloudKit) and Push Notifications on `com.alexcding.cascade` and
     `com.alexcding.cascade.remote`.
3. Build the Mac app and turn on **Settings → iPhone → Sync agent chats to iPhone**.
4. In the `cascade-ios` repository, set the same team, open `CascadeRemote.xcodeproj` and run
   it on an iPhone signed in to the same Apple Account.

Turning it off deletes this Mac's records from iCloud.

While `Signing.local.xcconfig` exists, every build, including ⌘R and `xcodebuild test`, needs
the team's provisioning profile. Move the file aside to build ad-hoc again.

## Not done / known limits

- **Latency**: seconds, set by CloudKit, and not measured yet.
- **No alerts while the phone app is closed**: CloudKit's silent pushes don't wake a
  force-quit app, and there is no alert subscription. The next step is a `CKQuerySubscription`
  on `Permission` with an alert payload.
- **Release builds**:
  - A Developer ID Mac build needs `CASCADE_APS_ENVIRONMENT = production` and a provisioning
    profile carrying the iCloud entitlement. The release pipeline hasn't been changed.
  - Whether CloudKit works in a notarised Developer ID build is still unverified.
- **Unsupported agents**: an agent without hooks installed can't take phone messages. The
  phone is told to install them.
- **Unsupported prompts**: questions an agent asks only in the terminal (trust prompts, menus)
  aren't visible on the phone.
