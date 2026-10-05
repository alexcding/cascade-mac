// Smoke test of the built page: renders a recorded Claude turn (captured from cascade-chat's
// engine, test/fixtures) through the bridge, the way the app drives it, and checks what
// Synara's chat draws and what the page asks of the app.
//
//   npm test            builds, then runs this
//   node --test test/   runs it against the current build
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, text, unload, waitFor } from "./harness.mjs";

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

/** Puts `value` into the composer as a paste (happy-dom has no keyboard input). */
async function typeInComposer(value) {
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
  const data = new window.DataTransfer();
  data.setData("text/plain", value);
  editor.dispatchEvent(new window.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
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
});

test("copying a message hands its text to the app", async () => {
  const copies = () => events("copy").length;
  const before = copies();
  const buttons = [...document.querySelectorAll('button[aria-label="Copy message"]')];
  assert.ok(buttons.length >= 2, "a copy button on each message");
  buttons.at(-1).click();
  await waitFor(() => copies() > before, "the copy event");
  assert.equal(events("copy").at(-1).payload.text, "Done.");
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

test("a typed /fork is refused in the page, with nothing sent", async () => {
  const before = page.requests.length;
  await typeInComposer("/fork local");
  const send = await waitFor(() => {
    const button = document.querySelector('button[aria-label="Send message"]');
    return button && !button.disabled ? button : null;
  }, "the send button");
  send.click();
  await waitFor(() => document.body.textContent?.includes("Fork is unavailable"), "the unavailable toast");
  const sent = page.requests.slice(before);
  assert.equal(sent.filter((m) => m.method === "orchestration.dispatchCommand").length, 0, "no command sent");
  assert.equal(sent.filter((m) => m.method === "orchestration.getShellSnapshot").length, 0);
  assert.equal(document.body.textContent?.includes("Could not fork thread"), false);
});

test("a lost event makes the page read the thread again, and the newer read closes the gap", async () => {
  const reads = () => page.requests.filter((m) => m.method === SNAPSHOT_READ).length;
  const before = reads();
  const last = fixture.events.at(-1);
  const gapSequence = last.sequence + 5;
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
