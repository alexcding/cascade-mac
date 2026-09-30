# Cascade Remote: the chat mirror (as built)

Status: **implemented on `feat/remote-chat`.** This supersedes the transport in
05-session-control.md. There is no direct connection, no listener and no terminal on the
phone. The Mac mirrors each live session's chat into the user's CloudKit private database.
The phone reads it there and writes messages and approvals back.

## Shape

```
 Cascade (Mac)                               iCloud (private DB, zone "Remote")          Cascade Remote (iPhone)
 ─────────────                               ──────────────────────────────────          ───────────────────────
 /api/agent/transcript ─► RemoteMirror ─────► Host / Session / Turn / Permission ────────► RemoteClient ─► SwiftUI
 (every 2 s, `since`)       │                                                                   │
 RemoteDelivery ◄───────────┴─────────────── Device, Command (signed) ◄─────────────────────────┘
 answerPermission                              status written back by the Mac
```

- **Sync**:
  - `RemoteSyncStore` (`macos/Services/Remote/Shared/`) is an actor around `CKSyncEngine`.
    `cascade-ios` compiles a copy of that folder: it is the wire format between the two apps,
    so **change both copies together**.
  - It keeps a local mirror of the zone, the engine's state and the names still to send in one
    JSON file, so a relaunch resumes from the change token and loses no unsent change.
  - Every record carries its value as JSON in one end-to-end encrypted field
    (`encryptedValues["payload"]`).
- **One writer per record**, so nothing needs merging:
  - Each Mac writes its own host record, sessions, turns and permissions.
  - Each phone writes its own device record and creates commands addressed to one Mac.
  - Only that Mac updates a command's `status`/`message`, and it removes the command
    10 minutes later.
  - Every Mac record carries its Mac's `hostID`, in the clear, so two Macs on one Apple Account
    mirror side by side without touching each other's records.
- **Identity**: `hostID` is derived from the Mac's hardware ID and the data directory
  (`RemoteLocalState.hostID`), not stored. A data folder or preferences carried to another Mac
  don't carry the identity, and a run with its own `CASCADE_DATA_DIR` is its own mirror. The
  mirror's own state (on/off, approved phones, commands begun) is in
  `<data>/Remote/mirror.json`, not `UserDefaults`.
- **Who may act**: reading is open to every device on the Apple Account; that is what iCloud
  is. Acting is not.
  - Each phone has a P-256 key, in the Secure Enclave where the device has one (this device
    only). Its device ID is derived from the public key, and it signs every command.
  - The phone introduces itself with a `Device` record. The Mac lists it under
    **Settings → iPhone → Waiting for approval**, with a short code taken from its ID. The phone
    shows the same code. A name is only what a record claims; the code is what tells the owner's
    phone from another. The owner allows or denies it once, and a denied phone can be asked again.
  - The Mac carries out a command only if its device is approved on that Mac and the
    signature verifies against the key it was approved under. Anything else is marked failed.
  - An Allow also carries a digest of the request as the phone displayed it. The Mac compares
    it with the request as it offered it, kept in memory, and refuses a mismatch.
  - The Mac never takes its own records back from iCloud. Of a Mac's records only a command is
    written by anything else, so only commands are read from a fetch. A session, turn, request
    or host record that comes back changed or deleted was written over by something else on the
    account: the Mac puts its own back.
  - The Mac's `Host` record lists its approved and denied device IDs, so a phone can say what
    to do on the Mac instead of sending into nothing.
- **The Mac** (`RemoteMirror`, owned by `AppViewModel`, host protocol in
  `AppViewModel+Remote.swift`):
  - **Mirroring**: every 2 s it updates each live session's record. It reads transcripts, with
    `since`, only while an approved phone has been open in the last 15 minutes (the phone's
    device record carries a heartbeat). With no phone around, conversations stay on the Mac.
  - **Turns**: the last 60, through `RemoteTurnMapper`, which caps text at 16 KB, tool output
    at 4 KB and thinking at 2 KB. Only a turn that changed is mapped and sent. A session that
    ends is deleted along with its turns.
  - **Messages**: `RemoteDelivery` types a phone message with `AgentMessageTyper`, the same
    sequence the chat uses. Before every write it checks that:
    - the agent's hooks show it at its prompt with nothing asked, and no approval is open;
    - the terminal is not at its shell;
    - the process in front is still the one the hooks last spoke for
      (`AgentTurnTracker.processChanged`), so a message never lands in a shell or in the
      startup dialog of an agent started since.

    It waits up to 60 s for that, then fails with a reason the phone shows. Once Enter is
    written the phone is told the message was sent. The next message then waits up to 10 s to
    hear this one's turn begin.
  - **Freshness**: a command older than 2 minutes when read is refused, never typed.
    Commands run one at a time, oldest first.
  - **At most once**: a command is recorded as begun before anything is typed. One found
    still pending after a quit or crash is failed, never typed again.
  - **Approvals**: every `agent-permission` of a mirrored session is mirrored, with a file
    change's old and new sides when each fits in 6,000 characters. A request too long to show
    whole is marked, the phone offers only Deny, and the Mac refuses an Allow for it.
  - **Holding an approval**: a request with no chat on screen normally goes straight to the
    terminal (`pass`), as before. If nobody has touched the Mac for 2 minutes (`CGEventSource`
    idle time) and a phone is approved, it waits for the phone instead. It still falls back to
    the terminal after the hook's 280 s.
  - **Account change**: if the iCloud account signs out or switches, mirroring stops and says
    so, across relaunches too. It starts again only when turned off and on.
  - **Deleted iCloud data**: if the zone is deleted under the same account, mirroring carries
    on in a new zone.
  - **iCloud unreachable**: it says so and retries, 15 s apart at first and up to 5 minutes.
- **The phone** (Cascade Remote, in the separate `cascade-ios` repository):
  - It shows the session list and a chat for each session: turns, collapsible tool calls,
    approval cards and a composer.
  - Until it is approved on a Mac, the composer and the approval buttons for that Mac's
    sessions are disabled, with a note saying where to allow it.
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
5. Back on the Mac, allow the iPhone under **Settings → iPhone → Waiting for approval**, after
   checking its code against the one the iPhone shows.

Turning it off deletes this Mac's records from iCloud. If that can't be done at the time
(offline, signed out), it is owed and done at the next chance.

While `Signing.local.xcconfig` exists, every build, including ⌘R and `xcodebuild test`, needs
the team's provisioning profile. Move the file aside to build ad-hoc again.

## Not done / known limits

- **Never run against CloudKit**: everything here is tested against a fake store. Sync, pushes
  and latency are unmeasured.
- **First open is slow**: conversations are sent only while a phone is around, so a phone
  opened after a while shows what it had until the Mac hears its heartbeat (a push, or a fetch
  within 30 s) and catches up.
- **A new approval request shows only in Settings**: nothing prompts on the Mac when a phone
  asks to be allowed.
- **Replacing a record of the wrong type is unverified**: if something on the account deletes
  one of the Mac's records and recreates the name as another record type, the store deletes it
  and saves the Mac's own again. That path has no test: it needs CloudKit.
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
