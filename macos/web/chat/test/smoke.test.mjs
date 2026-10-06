// Smoke test of the built page: renders a recorded Claude turn (captured from cascade-chat's
// engine, test/fixtures) through the bridge, the way the app drives it, and checks what
// Synara's chat draws and what the page asks of the app.
//
//   npm test            builds, then runs this
//   node --test test/   runs it against the current build
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, text, typeInComposer, unload, waitFor } from "./harness.mjs";

let page;
before(async () => {
  page = await loadPage();
});
after(async () => {
  await unload();
});

const events = (name) => page.posted.filter((message) => message.kind === "event" && message.name === name);
const SNAPSHOT_READ = "orchestration.getThreadDetailSnapshot";
/** The last sequence the page has applied, as the tests below move it on. */
let applied = fixture.events.at(-1).sequence;

/** A thread.message-sent event of an assistant message. */
function assistantMessage(sequence, text, threadId = context.threadId) {
  const template = fixture.events.find((event) => event.type === "thread.message-sent" && event.payload.role === "assistant");
  const messageId = `assistant-${threadId}-${sequence}`;
  return {
    ...template,
    aggregateId: threadId,
    eventId: `event-${threadId}-${sequence}`,
    commandId: `command-${sequence}`,
    correlationId: `command-${sequence}`,
    sequence,
    payload: { ...template.payload, threadId, messageId, text, turnId: null },
  };
}

/** `thread` with one more assistant message at the end. */
function withMessage(thread, id, text) {
  const assistant = thread.messages.find((message) => message.role === "assistant");
  return { ...thread, messages: [...thread.messages, { ...assistant, id, text, turnId: null }] };
}

/** Pushes `thread` as a snapshot newer than anything applied. */
function pushThread(thread) {
  applied += 5;
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: applied, thread } });
}

/** `base` with one more finished turn: a user message, the answer, its checkpoint. */
function withTurn(base, { userId, userText, assistantText, turnId, turnCount, files }) {
  const user = base.messages.find((message) => message.role === "user");
  const assistant = base.messages.find((message) => message.role === "assistant");
  const at = new Date().toISOString();
  const assistantId = `assistant:${turnId}`;
  return {
    ...base,
    updatedAt: at,
    messages: [
      ...base.messages,
      { ...user, id: userId, text: userText, turnId: null, createdAt: at, updatedAt: at },
      { ...assistant, id: assistantId, text: assistantText, turnId, createdAt: at, updatedAt: at },
    ],
    latestTurn: { ...base.latestTurn, turnId, assistantMessageId: assistantId, requestedAt: at, startedAt: at, completedAt: at, state: "completed" },
    checkpoints: [
      ...base.checkpoints,
      {
        ...base.checkpoints[0],
        turnId,
        assistantMessageId: assistantId,
        checkpointTurnCount: turnCount,
        checkpointRef: `refs/cascade/checkpoints/dGhyZWFkLWNsYXVkZQ/turn/${turnCount}`,
        completedAt: at,
        files,
      },
    ],
    session: { ...base.session, status: "ready", activeTurnId: null, updatedAt: at },
  };
}

/** `base` with a turn running (no answer yet). */
function withRunningTurn(base, turnId) {
  const at = new Date().toISOString();
  return {
    ...base,
    updatedAt: at,
    latestTurn: { ...base.latestTurn, turnId, assistantMessageId: null, requestedAt: at, startedAt: at, completedAt: null, state: "running" },
    session: { ...base.session, status: "running", activeTurnId: turnId, updatedAt: at },
  };
}

/** The thread the page shows, as the tests below move it on. */
let shown = fixture.done.thread;

const dispatched = (type) =>
  page.requests.filter((message) => message.method === "orchestration.dispatchCommand" && message.params?.command?.type === type);
const buttonLabelled = (label) => document.querySelector(`button[aria-label="${label}"]`);
const buttonWithText = (pattern) => [...document.querySelectorAll("button")].filter((button) => pattern.test((button.textContent ?? "").trim()));

/** Sets a React-controlled textarea's value as typing would. */
function setTextareaValue(textarea, value) {
  Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value").set.call(textarea, value);
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
}


test("the page says it is ready before anything is pushed", () => {
  assert.equal(events("ready").length, 1);
});

test("a thread at an approval shows the user's message, the tool and the approval card", async () => {
  page.push("context", context);
  page.push("providers", providers);
  page.push("thread", { kind: "snapshot", snapshot: fixture.atApproval });

  await waitFor(() => text().includes("Run the shell command"), "the user's message");
  await waitFor(() => text().includes("Approve this command?"), "the approval card");
  // The work log row for the Bash call that waits on the approval.
  await waitFor(() => /Running Bash: echo hi > probe\.txt|Bash.*echo hi > probe\.txt/.test(text()), "the tool row");
  assert.ok(document.querySelector("[data-chat-composer-form]"), "the composer is drawn");
  assert.ok(document.querySelector('[contenteditable="true"], [contenteditable]'), "the composer has its editor");
  assert.match(text(), /Approve once/);
  assert.match(text(), /Decline/);
});

test("approving answers the request through orchestration.dispatchCommand", async () => {
  const approve = [...document.querySelectorAll("button")].find((button) => /Approve once/.test(button.textContent ?? ""));
  assert.ok(approve, "the Approve once button");
  approve.click();
  const request = await waitFor(
    () =>
      page.requests.find(
        (message) =>
          message.method === "orchestration.dispatchCommand" && message.params?.command?.type === "thread.approval.respond",
      ),
    "the approval response",
  );
  const requestId = fixture.atApproval.thread.activities.find((a) => a.kind === "approval.requested").payload.requestId;
  assert.equal(request.params.command.requestId, requestId);
  assert.equal(request.params.command.threadId, context.threadId);
  assert.equal(request.params.command.decision, "accept");
});

test("the turn's events, applied in order, end in the assistant's answer", async () => {
  for (const event of fixture.events.slice(fixture.atApproval.snapshotSequence)) {
    page.push("thread", { kind: "event", event });
  }
  await waitFor(() => text().includes("Done."), "the assistant's message");
  await waitFor(() => !text().includes("Approve this command?"), "the approval card to go");
  // The checkpoint's changed file, drawn under the answer.
  assert.match(text(), /probe\.txt/);
  assert.ok(document.querySelector("[data-chat-composer-form]"), "the composer is back");
  assert.match(text(), /Ask anything/);
});

test("a message typed in the composer is sent as thread.turn.start", async () => {
  const editor = document.querySelector("[data-chat-composer-form] [contenteditable]");
  assert.ok(editor, "the composer's editor");
  editor.focus();
  const range = document.createRange();
  range.selectNodeContents(editor.querySelector("p") ?? editor);
  range.collapse(false);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event("selectionchange"));
  await new Promise((resolve) => setTimeout(resolve, 50));
  // Lexical takes text from a paste; happy-dom has no keyboard input to type with.
  const data = new window.DataTransfer();
  data.setData("text/plain", "Now say it twice.");
  editor.dispatchEvent(new window.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  const send = await waitFor(() => {
    const button = document.querySelector('button[aria-label="Send message"]');
    return button && !button.disabled ? button : null;
  }, "the send button");
  send.click();
  const request = await waitFor(
    () => page.requests.find((m) => m.params?.command?.type === "thread.turn.start"),
    "the turn start",
  );
  const { command } = request.params;
  assert.equal(command.threadId, context.threadId);
  assert.equal(command.message.role, "user");
  assert.equal(command.message.text, "Now say it twice.");
  assert.deepEqual(command.message.attachments, []);
  assert.equal(command.modelSelection.provider, "claudeAgent");
  assert.equal(command.runtimeMode, "approval-required");
  assert.ok(["queue", "steer"].includes(command.dispatchMode));
  // Shown at once, before the backend echoes it, and the composer is cleared.
  await waitFor(() => text().includes("Now say it twice."), "the sent message in the transcript");
  await waitFor(() => (editor.textContent ?? "").trim() === "", "the composer to clear");
  // The backend runs the turn: the message, the answer and a checkpoint of one changed file.
  shown = withTurn(shown, {
    userId: command.message.messageId,
    userText: "Now say it twice.",
    assistantText: "Said twice.",
    turnId: "turn-2",
    turnCount: 2,
    files: [{ path: "twice.txt", additions: 2, deletions: 0, kind: "added" }],
  });
  pushThread(shown);
  await waitFor(() => text().includes("Said twice."), "the answer");
});

test("copying a message hands its text to the app", async () => {
  const copies = () => events("copy").length;
  const before = copies();
  const buttons = [...document.querySelectorAll('button[aria-label="Copy message"]')];
  assert.ok(buttons.length >= 2, "a copy button on each message");
  for (const button of buttons) button.click();
  await waitFor(() => copies() >= before + buttons.length, "the copy events");
  const copied = events("copy").slice(before).map((message) => message.payload.text);
  assert.ok(copied.includes("Done."), "the first answer");
  assert.ok(copied.includes("Said twice."), "the second answer");
});

test("the context meter shows the turn's usage", () => {
  assert.ok(document.querySelector('[aria-label^="Context window"]'), "the context meter");
});

test("the model picker shows the thread's model from provider.listModels", async () => {
  await waitFor(() => text().includes("Claude Haiku"), "the model label");
  const methods = new Set(page.requests.map((message) => message.method));
  assert.ok(methods.has("provider.listModels"));
  assert.ok(methods.has("provider.getComposerCapabilities"));
});

test("editing the last message sends thread.message.edit-and-resend", async () => {
  const lastUser = shown.messages.filter((message) => message.role === "user").at(-1);
  // Only the latest user message can be edited.
  assert.equal(document.querySelectorAll('button[aria-label="Edit message"]').length, 1);
  buttonLabelled("Edit message").click();
  const textarea = await waitFor(() => document.querySelector('textarea[aria-label="Edit message"]'), "the edit form");
  assert.equal(textarea.value, "Now say it twice.");
  setTextareaValue(textarea, "Now say it three times.");
  const send = await waitFor(
    () => buttonWithText(/^Send$/).find((button) => button.closest("form")?.contains(textarea) && !button.disabled),
    "the edit's Send button",
  );
  send.click();
  const request = await waitFor(() => dispatched("thread.message.edit-and-resend")[0], "the edit command");
  const { command } = request.params;
  assert.equal(command.threadId, context.threadId);
  assert.equal(command.messageId, lastUser.id);
  assert.match(command.text, /Now say it three times\./);
  assert.equal(command.modelSelection.provider, "claudeAgent");
  await waitFor(() => !document.querySelector('textarea[aria-label="Edit message"]'), "the edit form to close");
});

test("reverting to a message asks first, then sends thread.checkpoint.revert", async () => {
  const reverts = () => dispatched("thread.checkpoint.revert");
  const revertButtons = () => [...document.querySelectorAll('button[aria-label="Revert to this message"]')];
  // Each user message whose answer has a checkpoint can be reverted to.
  await waitFor(() => revertButtons().length === 2, "a revert button per user message");
  revertButtons().at(-1).click();
  const dialog = await waitFor(() => document.querySelector('[role="alertdialog"]'), "Synara's confirm dialog");
  assert.match(dialog.textContent, /Revert this thread to checkpoint 1\?/);
  [...dialog.querySelectorAll("button")].find((button) => button.textContent === "Cancel").click();
  await waitFor(() => !document.querySelector('[role="alertdialog"]'), "the dialog to close");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(reverts().length, 0, "nothing sent when cancelled");

  revertButtons().at(-1).click();
  const again = await waitFor(() => document.querySelector('[role="alertdialog"]'), "the dialog again");
  [...again.querySelectorAll("button")].find((button) => button.textContent === "Confirm").click();
  const request = await waitFor(() => reverts()[0], "the revert command");
  assert.equal(request.params.command.threadId, context.threadId);
  assert.equal(request.params.command.turnCount, 1);
  assert.equal(request.params.command.scope, "thread");
});

test("a turn's changes open its diff in the page, read with orchestration.getTurnDiff", async () => {
  const patch = [
    "diff --git a/twice.txt b/twice.txt",
    "new file mode 100644",
    "index 0000000..1111111",
    "--- /dev/null",
    "+++ b/twice.txt",
    "@@ -0,0 +1,2 @@",
    "+hi",
    "+hi",
    "",
  ].join("\n");
  page.answerWith("orchestration.getTurnDiff", (params) => ({ ...params, diff: patch }));
  page.answerWith("orchestration.getFullThreadDiff", (params) => ({ ...params, fromTurnCount: 0, diff: patch }));
  try {
    const opened = events("openTurnDiff").length;
    // The Review button of the card that lists twice.txt (turn 2), not probe.txt (turn 1).
    const cardFile = (button) => {
      for (let element = button.parentElement; element; element = element.parentElement) {
        const content = element.textContent ?? "";
        if (content.includes("twice.txt") || content.includes("probe.txt")) return content.includes("probe.txt") ? "probe.txt" : "twice.txt";
      }
      return null;
    };
    const review = await waitFor(
      () => buttonWithText(/^Review/).find((button) => cardFile(button) === "twice.txt"),
      "the turn's Review button",
    );
    review.click();
    const panel = await waitFor(() => document.querySelector("[data-turn-diff-panel]"), "the diff panel");
    const request = await waitFor(
      () => page.requests.find((message) => message.method === "orchestration.getTurnDiff"),
      "the turn diff read",
    );
    assert.deepEqual(
      { threadId: request.params.threadId, from: request.params.fromTurnCount, to: request.params.toTurnCount },
      { threadId: context.threadId, from: 1, to: 2 },
    );
    await waitFor(() => panel.querySelector('[data-diff-file-path="twice.txt"]') || /twice\.txt/.test(panel.textContent ?? ""), "the file's diff");
    assert.match(panel.textContent ?? "", /Turn 2/);
    // Shown in the page: nothing is handed to the app.
    assert.equal(events("openTurnDiff").length, opened);
    buttonLabelled("Close diff").click();
    await waitFor(() => !document.querySelector("[data-turn-diff-panel]"), "the panel to close");
  } finally {
    page.answerWith("orchestration.getTurnDiff", undefined);
    page.answerWith("orchestration.getFullThreadDiff", undefined);
  }
});

test("a follow-up sent during a running turn is held, then sent when the turn ends", async () => {
  pushThread(withRunningTurn(shown, "turn-3"));
  await waitFor(() => /Ask for follow-up changes/.test(text()), "the running composer");
  const turnStarts = () => dispatched("thread.turn.start").filter((m) => m.params.command.message.text === "And a third time.");
  await typeInComposer("And a third time.");
  await new Promise((resolve) => setTimeout(resolve, 50));
  const form = document.querySelector("[data-chat-composer-form]");
  form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  // Held in Synara's queue above the composer, not sent.
  await waitFor(() => /And a third time\./.test(document.querySelector("[data-chat-composer-slot]")?.textContent ?? ""), "the queued row");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(turnStarts().length, 0, "nothing sent while the turn runs");
  // The turn ends: the queue sends it.
  shown = withTurn(shown, {
    userId: "msg-3",
    userText: "Say it again.",
    assistantText: "Said again.",
    turnId: "turn-3",
    turnCount: 3,
    files: [],
  });
  pushThread(shown);
  const request = await waitFor(() => turnStarts()[0], "the queued turn sent", 15_000);
  assert.equal(request.params.command.dispatchMode, "queue");
  assert.equal(request.params.command.threadId, context.threadId);
  shown = withTurn(shown, {
    userId: request.params.command.message.messageId,
    userText: "And a third time.",
    assistantText: "Said a third time.",
    turnId: "turn-4",
    turnCount: 4,
    files: [],
  });
  pushThread(shown);
  await waitFor(() => text().includes("Said a third time."), "the answer");
  await waitFor(() => !/And a third time\./.test(document.querySelector("[data-chat-composer-slot]")?.textContent ?? ""), "the queue to empty");
});

test("/fork forks the thread and asks the app to show the new one", async () => {
  page.answerWith("orchestration.getShellSnapshot", () => ({
    snapshotSequence: 1,
    spaces: [],
    projects: [],
    threads: [],
    updatedAt: new Date().toISOString(),
  }));
  try {
    await typeInComposer("/fork local");
    const send = await waitFor(() => {
      const button = document.querySelector('button[aria-label="Send message"]');
      return button && !button.disabled ? button : null;
    }, "the send button");
    send.click();
    const request = await waitFor(() => dispatched("thread.fork.create")[0], "the fork command");
    const { command } = request.params;
    assert.equal(command.sourceThreadId, context.threadId);
    assert.equal(command.projectId, context.projectId);
    assert.notEqual(command.threadId, context.threadId);
    await waitFor(() => page.requests.some((m) => m.method === "orchestration.getShellSnapshot"), "the shell read");
    const open = await waitFor(() => events("openThread")[0], "the openThread event");
    assert.equal(open.payload.threadId, command.threadId);
    // The page stays on its thread; a shell snapshot without it does not empty the page.
    assert.ok(text().includes("Said a third time."));
    assert.equal(document.body.textContent?.includes("Could not fork thread"), false);
  } finally {
    page.answerWith("orchestration.getShellSnapshot", undefined);
  }
});

test("/fork alone offers only the local fork target", async () => {
  page.answerWith("orchestration.getShellSnapshot", () => ({
    snapshotSequence: 1,
    spaces: [],
    projects: [],
    threads: [],
    updatedAt: new Date().toISOString(),
  }));
  try {
    const before = dispatched("thread.fork.create").length;
    await typeInComposer("/fork");
    const send = await waitFor(() => {
      const button = document.querySelector('button[aria-label="Send message"]');
      return button && !button.disabled ? button : null;
    }, "the send button");
    send.click();
    const local = await waitFor(
      () => [...document.querySelectorAll("[data-composer-item-id], [role='option'], button, li")].find((el) => /Fork Into Local/.test(el.textContent ?? "")),
      "the fork target picker",
    );
    assert.equal(text().includes("Fork Into New Worktree"), false, "the worktree target is not offered");
    local.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    local.click();
    const request = await waitFor(() => dispatched("thread.fork.create")[before], "the fork command");
    // A local fork stays in the source's folder, so it names it (the engine refuses a worktree
    // fork with no path).
    assert.equal(request.params.command.worktreePath, fixture.done.thread.worktreePath);
    assert.ok(request.params.command.worktreePath);
  } finally {
    page.answerWith("orchestration.getShellSnapshot", undefined);
  }
});

test("a user's image attachment is drawn from the page's own scheme path", async () => {
  const id = "thread-claude_00000000-0000-4000-8000-000000000001";
  const user = shown.messages.find((message) => message.role === "user");
  const at = new Date().toISOString();
  shown = {
    ...shown,
    messages: [
      ...shown.messages,
      {
        ...user,
        id: "user-with-image",
        text: "Here is a picture",
        turnId: null,
        createdAt: at,
        updatedAt: at,
        attachments: [{ type: "image", id, name: "shot.png", mimeType: "image/png", sizeBytes: 68 }],
      },
    ],
  };
  pushThread(shown);
  const image = await waitFor(
    () => [...document.querySelectorAll("img")].find((img) => (img.getAttribute("src") ?? "").includes("/attachments/")),
    "the attachment image",
  );
  // Synara's wsHttpUrl.ts resolves the path against the page's origin; on the app's scheme that
  // is cascade-chat://page (ChatTests' chatPageResolvesAttachmentURLsOnItsScheme), which serves it.
  assert.equal(image.getAttribute("src"), new URL(`/attachments/${id}`, window.location.origin).href);
});

test("Cmd-F opens Synara's find bar", async () => {
  const mac = /Mac/.test(window.navigator.platform ?? "");
  window.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "f", code: "KeyF", metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true }),
  );
  const input = await waitFor(() => document.querySelector('input[aria-label="Find in thread"]'), "the find input");
  assert.ok(input);
});

test("a read-only page hides edit, revert, undo, fork and the queue", async () => {
  assert.ok(buttonLabelled("Edit message"), "edit is offered on a conversation");
  assert.ok(buttonWithText(/^Undo/).length > 0, "undo is offered on a conversation");
  page.push("context", { ...context, readOnly: true });
  await waitFor(() => !document.querySelector("[data-chat-composer-form]"), "the composer to go");
  await waitFor(() => !buttonLabelled("Edit message"), "edit to go");
  assert.equal(buttonLabelled("Revert to this message"), null);
  assert.equal(buttonWithText(/^Undo/).length, 0);
  assert.equal(buttonLabelled("Fork thread from this turn"), null);
  assert.ok(text().includes("Said a third time."), "the transcript stays");
  page.push("context", context);
  await waitFor(() => document.querySelector("[data-chat-composer-form]"), "the composer to return");
});

test("a lost event makes the page read the thread again, and the newer read closes the gap", async () => {
  const reads = () => page.requests.filter((m) => m.method === SNAPSHOT_READ).length;
  const before = reads();
  const last = fixture.events.at(-1);
  const gapSequence = applied + 5;
  page.answerWith(SNAPSHOT_READ, () => ({
    snapshotSequence: gapSequence,
    thread: withMessage(fixture.done.thread, "assistant-gap", "Caught up after the gap."),
  }));
  page.push("thread", { kind: "event", event: { ...last, eventId: "gap-event", sequence: gapSequence } });
  await waitFor(() => reads() > before, "the snapshot request");
  await waitFor(() => text().includes("Caught up after the gap."), "the newer snapshot on screen");
  page.answerWith(SNAPSHOT_READ, undefined);
  // The stream goes on from the read: the next event applies at once, with no further read.
  const afterRead = reads();
  page.push("thread", { kind: "event", event: assistantMessage(gapSequence + 1, "And the stream goes on.") });
  await waitFor(() => text().includes("And the stream goes on."), "the event after the gap");
  assert.equal(reads(), afterRead);
  applied = gapSequence + 1;
});

test("answering a question refreshes the thread without an error banner", async () => {
  const question = {
    id: "q-color",
    header: "Color",
    question: "Which color should the probe be?",
    options: [
      { label: "Red", description: "A red probe" },
      { label: "Blue", description: "A blue probe" },
    ],
  };
  const atApproval = fixture.atApproval.thread;
  const approval = atApproval.activities.find((activity) => activity.kind === "approval.requested");
  const asked = {
    ...approval,
    id: "activity-question-1",
    kind: "user-input.requested",
    summary: "User input requested",
    tone: "info",
    payload: { requestId: "question-1", questions: [question] },
  };
  const asking = {
    ...atApproval,
    updatedAt: new Date().toISOString(),
    activities: [...atApproval.activities.filter((activity) => activity !== approval), asked],
  };
  const answered = withMessage(fixture.done.thread, "assistant-red", "Red it is.");
  answered.updatedAt = new Date(Date.now() + 1000).toISOString();
  answered.activities = [
    ...answered.activities,
    asked,
    {
      ...asked,
      id: "activity-question-1-resolved",
      kind: "user-input.resolved",
      summary: "User input resolved",
      payload: { requestId: "question-1", answers: { "q-color": "Red" } },
    },
  ];
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: applied + 10, thread: asking } });
  await waitFor(() => text().includes("Which color should the probe be?"), "the question card");
  applied += 10;
  const answeredSequence = applied + 2;
  page.answerWith(SNAPSHOT_READ, () => ({ snapshotSequence: answeredSequence, thread: answered }));
  const readsBefore = page.requests.filter((m) => m.method === SNAPSHOT_READ).length;
  const red = await waitFor(
    () => [...document.querySelectorAll("button")].find((button) => /^\s*(1\s*)?Red/.test(button.textContent ?? "")),
    "the Red option",
  );
  red.click();
  const submit = () =>
    [...document.querySelectorAll("button")].find((button) => /^(Submit|Send|Continue)/i.test((button.textContent ?? "").trim()));
  const respond = () =>
    page.requests.find((m) => m.method === "orchestration.dispatchCommand" && m.params?.command?.type === "thread.user-input.respond");
  // A single-choice question may go at once; otherwise its submit button sends it.
  await new Promise((resolve) => setTimeout(resolve, 100));
  if (!respond()) {
    const button = await waitFor(() => submit() ?? respond(), "the submit button or the answer");
    if (button !== respond()) button.click();
  }
  const request = await waitFor(respond, "the answer");
  assert.equal(request.params.command.requestId, "question-1");
  assert.deepEqual(Object.keys(request.params.command.answers), ["q-color"]);
  // Synara's subscribeThread after the answer is a fresh read of the thread.
  await waitFor(() => page.requests.filter((m) => m.method === SNAPSHOT_READ).length > readsBefore, "the refresh read");
  await waitFor(() => text().includes("Red it is."), "the refreshed thread");
  await waitFor(() => !text().includes("Which color should the probe be?"), "the question card to go");
  assert.equal(text().includes("Could not submit or refresh the answer"), false, "no error banner");
  assert.equal(
    events("log").some((m) => /subscribeThread/.test(m.payload.message)),
    false,
    "subscribeThread is answered in the page",
  );
  page.answerWith(SNAPSHOT_READ, undefined);
  applied = answeredSequence;
});

test("a link in the transcript goes to the app and the page does not navigate", async () => {
  applied += 1;
  page.push("thread", {
    kind: "event",
    event: assistantMessage(applied, "See [the docs](https://example.com/docs) or [write](mailto:team@example.com)."),
  });
  const link = await waitFor(() => document.querySelector('a[href="https://example.com/docs"]'), "the link");
  const href = window.location.href;
  const click = (anchor) => anchor.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
  assert.equal(click(link), false, "the click's default is prevented");
  await waitFor(() => events("openLink").some((m) => m.payload.url === "https://example.com/docs"), "the openLink event");
  const mail = document.querySelector('a[href="mailto:team@example.com"]');
  assert.ok(mail, "the mail link");
  assert.equal(click(mail), false);
  await waitFor(() => events("openLink").some((m) => m.payload.url === "mailto:team@example.com"), "the mail openLink");
  // Another scheme is not followed and not handed over.
  const other = document.createElement("a");
  other.href = "file:///etc/hosts";
  other.textContent = "hosts";
  document.getElementById("chat").appendChild(other);
  const opened = events("openLink").length;
  assert.equal(click(other), false);
  other.remove();
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(events("openLink").length, opened);
  assert.equal(window.location.href, href, "the page stayed where it was");
});

test("a read the app never answers times out, and the page asks again", async () => {
  window.__cascadeChatTest = { requestTimeoutMs: 300 };
  page.hold(SNAPSHOT_READ);
  try {
    const heldReads = () => page.held.filter((m) => m.method === SNAPSHOT_READ);
    const before = heldReads().length;
    const gapSequence = applied + 3;
    page.push("thread", { kind: "event", event: assistantMessage(gapSequence, "Past the timeout.") });
    await waitFor(() => heldReads().length > before, "the first read");
    // Unanswered, it times out, and the events waiting on it get another read.
    const retry = await waitFor(() => heldReads().length > before + 1 && heldReads().at(-1), "the read asked again");
    page.reply(retry.id, {
      ok: true,
      result: { snapshotSequence: gapSequence, thread: withMessage(fixture.done.thread, "assistant-late", "Read after the timeout.") },
    });
    await waitFor(() => text().includes("Read after the timeout."), "the retried read applied");
    // The first read's reply, arriving late, is ignored.
    page.reply(heldReads()[before].id, { ok: true, result: fixture.atApproval });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.ok(text().includes("Read after the timeout."));
    assert.ok(events("log").some((m) => /did not answer orchestration\.getThreadDetailSnapshot/.test(m.payload.message)));
    applied = gapSequence;
  } finally {
    delete window.__cascadeChatTest;
    page.hold(SNAPSHOT_READ, false);
  }
});

test("dark appearance sets Synara's dark theme", async () => {
  page.push("context", { ...context, appearance: "dark" });
  await waitFor(() => document.documentElement.classList.contains("dark"), "the dark class");
  page.push("context", context);
  await waitFor(() => !document.documentElement.classList.contains("dark"), "the light theme");
});

test("a read-only context hides the composer and keeps the transcript", async () => {
  page.push("context", { ...context, readOnly: true });
  await waitFor(() => !document.querySelector("[data-chat-composer-form]"), "the composer to go");
  await waitFor(() => text().includes("Done."), "the transcript");
  page.push("context", context);
  await waitFor(() => document.querySelector("[data-chat-composer-form]"), "the composer to return");
});

test("a read-only context still draws a pending approval, without the editor, and answers it", async () => {
  const atApproval = fixture.atApproval.thread;
  const approval = atApproval.activities.find((activity) => activity.kind === "approval.requested");
  const requested = {
    ...approval,
    id: "activity-read-only-approval",
    payload: { ...approval.payload, requestId: "read-only-approval" },
  };
  const waiting = {
    ...atApproval,
    updatedAt: new Date().toISOString(),
    activities: [...atApproval.activities.filter((activity) => activity !== approval), requested],
  };
  page.push("context", { ...context, readOnly: true });
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: applied + 10, thread: waiting } });
  applied += 10;
  await waitFor(() => text().includes("Approve this command?"), "the approval panel");
  assert.equal(document.querySelector("[data-chat-composer-form]"), null, "no composer form");
  assert.equal(document.querySelector("[data-chat-composer-slot] [contenteditable]"), null, "no editor");
  assert.ok(document.querySelector("[data-chat-pending-only]"), "the panel stands alone");
  const respond = () =>
    page.requests.find(
      (message) =>
        message.method === "orchestration.dispatchCommand" &&
        message.params?.command?.type === "thread.approval.respond" &&
        message.params.command.requestId === "read-only-approval",
    );
  const approve = await waitFor(
    () => [...document.querySelectorAll("button")].find((button) => /Approve once/.test(button.textContent ?? "")),
    "the Approve once button",
  );
  approve.click();
  const request = await waitFor(respond, "the approval response");
  assert.equal(request.params.command.threadId, context.threadId);
  assert.equal(request.params.command.decision, "accept");
  // The thread moves on; with nothing pending, the read-only page draws nothing at the bottom.
  const done = { ...fixture.done.thread, updatedAt: new Date(Date.now() + 1000).toISOString() };
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: applied + 10, thread: done } });
  applied += 10;
  await waitFor(() => !text().includes("Approve this command?"), "the panel to go");
  assert.equal(document.querySelector("[data-chat-composer-slot]"), null);
  page.push("context", context);
  await waitFor(() => document.querySelector("[data-chat-composer-form]"), "the composer to return");
});

test("switching threads shows the new thread, even with a read of the old one in flight", async () => {
  page.hold(SNAPSHOT_READ);
  try {
    const heldReads = () => page.held.filter((m) => m.method === SNAPSHOT_READ);
    const before = heldReads().length;
    // A lost event on the old thread leaves a read of it in flight.
    page.push("thread", { kind: "event", event: assistantMessage(applied + 4, "Never shown.") });
    await waitFor(() => heldReads().length > before, "the old thread's read");
    const oldRead = heldReads().at(-1);
    const second = {
      ...fixture.done.thread,
      id: "thread-two",
      title: "Second thread",
      session: { ...fixture.done.thread.session, threadId: "thread-two" },
      messages: fixture.done.thread.messages.map((message) =>
        message.role === "user" ? { ...message, text: "The second thread's question" } : { ...message, text: "The second thread's answer" },
      ),
    };
    // The app pushes the new context and the new thread's snapshot in one go.
    page.push("context", { ...context, threadId: "thread-two" });
    page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: 3, thread: second } });
    await waitFor(() => text().includes("The second thread's question"), "the new thread");
    assert.equal(text().includes("Run the shell command"), false, "the old thread is gone");
    // The old read no longer holds the new thread's events back.
    page.push("thread", { kind: "event", event: assistantMessage(4, "Thread two goes on.", "thread-two") });
    await waitFor(() => text().includes("Thread two goes on."), "the new thread's event");
    // The old read's answer, arriving now, changes nothing.
    page.reply(oldRead.id, { ok: true, result: fixture.done });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.ok(text().includes("The second thread's question"));
  } finally {
    page.hold(SNAPSHOT_READ, false);
  }
});

test("nothing failed: no page errors and every push matched Synara's contract", () => {
  assert.deepEqual(events("error"), []);
  const decodeFailures = events("log").filter((message) => /does not match Synara's contract/.test(message.payload.message));
  assert.deepEqual(decodeFailures, []);
});
