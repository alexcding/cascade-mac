// What the page took from Synara 0cf5ea460 beyond the vendored files: the parts of ChatView and
// its hooks that ChatController.tsx ports by hand, and the shims that keep the page English.
//
//   a new /goal on an idle thread is one visible message, sent as Synara sends it
//   a /goal the engine refuses stays in the composer
//   an idle thread blocked by a provider failure still offers Stop
//   a folder dragged from an editor's file tree is mentioned by its path
//   an assistant's inline image the host kept as an attachment is drawn from the page's scheme
//   the interface is English whatever language is stored or preferred
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, text, typeInComposer, unload, waitFor } from "./harness.mjs";

const DRAFTS_KEY = "synara:composer-drafts:v1";
const APP_SETTINGS_KEY = "synara:app-settings:v1";

let page;
before(async () => {
  // A language another Synara would draw the page in: Spanish needs no Beta, Chinese does, and the
  // page's scheme is not Synara's, so its Beta features are on.
  page = await loadPage({ storage: { [APP_SETTINGS_KEY]: JSON.stringify({ language: "es" }) } });
  page.push("context", context);
  page.push("providers", providers);
  push(fixture.done.thread);
  await waitFor(() => document.querySelector("[data-chat-composer-form] [contenteditable]"), "the composer");
});
after(async () => {
  // Let React finish what the last push started before the window goes away under it.
  await new Promise((resolve) => setTimeout(resolve, 200));
  await unload();
});

let sequence = 100;
function push(thread) {
  sequence += 5;
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: sequence, thread } });
}
const dispatched = (type) =>
  page.requests.filter((message) => message.method === "orchestration.dispatchCommand" && message.params?.command?.type === type);
const editor = () => document.querySelector("[data-chat-composer-form] [contenteditable]");
function prompt() {
  window.nativeChat.flush();
  const drafts = JSON.parse(window.localStorage.getItem(DRAFTS_KEY) ?? "{}");
  return drafts.state?.draftsByThreadId?.[context.threadId]?.prompt ?? "";
}
async function sendButton() {
  return waitFor(() => {
    const button = document.querySelector('button[aria-label="Send message"]');
    return button && !button.disabled ? button : null;
  }, "the send button");
}

test("the interface is English with Spanish stored as the language", async () => {
  // Synara's own catalogue keys (common:placeholder_default, chat:composer_sendMessage), drawn
  // from the English catalogue; Spanish would read "Pregunta lo que quieras…", "Enviar mensaje".
  await waitFor(() => text().includes("Ask anything, @tag files/folders"), "the English placeholder");
  await waitFor(() => document.querySelector('button[aria-label="Send message"]'), "the English send button");
  assert.doesNotMatch(document.body.textContent ?? "", /Pregunta lo que quieras/);
  assert.equal(document.querySelector('button[aria-label="Enviar mensaje"]'), null);
  assert.equal(document.documentElement.lang, context.locale, "the document keeps the app's locale");
});

test("a new /goal on an idle thread is saved to start with its visible message", async () => {
  const turnStarts = dispatched("thread.turn.start").length;
  await typeInComposer("/goal Ship the release notes");
  (await sendButton()).click();
  const request = await waitFor(() => dispatched("thread.meta.update").find((m) => m.params.command.goal), "the goal command");
  const { command } = request.params;
  assert.equal(command.threadId, context.threadId);
  assert.equal(command.goal, "Ship the release notes");
  // Synara's host records the goal, the `/goal …` message and its turn together.
  assert.equal(command.goalStartBehavior, "start-with-message");
  await waitFor(() => (editor()?.textContent ?? "").trim() === "", "the composer to clear");
  assert.equal(prompt(), "");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(dispatched("thread.turn.start").length, turnStarts, "the page starts no turn of its own");
  // What the host answers with: the visible message, which the transcript draws.
  const user = fixture.done.thread.messages.find((message) => message.role === "user");
  const at = new Date().toISOString();
  push({
    ...fixture.done.thread,
    updatedAt: at,
    messages: [
      ...fixture.done.thread.messages,
      { ...user, id: `goal:${command.commandId}`, text: "/goal Ship the release notes", turnId: null, createdAt: at, updatedAt: at },
    ],
  });
  await waitFor(() => text().includes("Ship the release notes"), "the goal message in the transcript");
});

test("a /goal the engine refuses keeps its text in the composer and says why", async () => {
  // Cascade's engine keeps no goals (decider.rs `GoalsUnsupported`): it refuses the command, and
  // Synara leaves a refused goal in the composer for another try.
  page.answerWith("orchestration.dispatchCommand", (params) => {
    if (params.command?.type === "thread.meta.update" && "goal" in params.command) {
      throw new Error("Thread goals are not available in Cascade yet.");
    }
    return { sequence: fixture.events.length + 1 };
  });
  try {
    const goals = dispatched("thread.meta.update").length;
    await typeInComposer("/goal Keep the draft");
    (await sendButton()).click();
    await waitFor(() => dispatched("thread.meta.update").length > goals, "the goal command");
    // Toasts render outside the chat's root.
    const whole = () => document.body.textContent ?? "";
    await waitFor(() => whole().includes("Could not update thread goal"), "the refusal's toast");
    assert.match(whole(), /Thread goals are not available in Cascade yet\./);
    // The editor draws the command as a chip; the draft holds what was typed.
    assert.equal(prompt(), "/goal Keep the draft");
  } finally {
    page.answerWith("orchestration.dispatchCommand");
  }
});

test("an idle thread blocked by an earlier provider failure still offers Stop", async () => {
  const at = new Date().toISOString();
  const blocked = {
    ...fixture.done.thread,
    updatedAt: at,
    // The engine's quarantine, as Synara's provider command reactor reports it on the session.
    session: {
      ...fixture.done.thread.session,
      status: "ready",
      activeTurnId: null,
      lastError: "Thread is blocked by an earlier provider failure: the provider runtime did not stop",
      updatedAt: at,
    },
  };
  push(blocked);
  const stop = await waitFor(() => document.querySelector('button[aria-label="Stop generation"]'), "the Stop button");
  assert.match(stop.getAttribute("title") ?? "", /Stop the provider runtime before unblocking this thread/);
  const before = dispatched("thread.turn.interrupt").length;
  stop.click();
  const request = await waitFor(() => dispatched("thread.turn.interrupt")[before], "the interrupt");
  assert.equal(request.params.command.threadId, context.threadId);
  // Once the error is gone the composer sends again.
  push({ ...blocked, updatedAt: new Date().toISOString(), session: { ...blocked.session, lastError: null } });
  await waitFor(() => !document.querySelector('button[aria-label="Stop generation"]'), "Stop to go");
});

/** A drop with no File in it, as an editor's file tree drags a folder. Dispatched on the composer's
 *  drop target, under the editor: Lexical's own drop handling needs a layout happy-dom has not. */
function dropData(data) {
  const transfer = { types: Object.keys(data), files: [], items: [], getData: (type) => data[type] ?? "", dropEffect: "none" };
  const over = new window.DragEvent("dragover", { bubbles: true, cancelable: true });
  Object.defineProperty(over, "dataTransfer", { value: transfer });
  const target = document.querySelector("[data-chat-composer-surface]").parentElement;
  target.dispatchEvent(over);
  const drop = new window.DragEvent("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: transfer });
  target.dispatchEvent(drop);
  return { over, drop, transfer };
}

test("a folder dragged from an editor's file tree is mentioned by its path", async () => {
  const { over, drop, transfer } = dropData({ codefiles: JSON.stringify(["/Users/me/project/src", "relative/ignored"]) });
  assert.equal(over.defaultPrevented, true, "the drag is taken");
  assert.equal(transfer.dropEffect, "copy");
  assert.equal(drop.defaultPrevented, true);
  await waitFor(() => prompt().includes("@/Users/me/project/src"), "the folder mention");
  assert.doesNotMatch(prompt(), /relative\/ignored/);
  // A text/uri-list of file URLs, as an editor may carry instead.
  dropData({ "text/uri-list": "# a comment\r\nfile:///Users/me/project/docs%20and%20notes\r\n" });
  await waitFor(() => prompt().includes("docs and notes"), "the uri-list mention");
  // A web link is not a path: it goes on as a link drop.
  const before = prompt();
  const link = dropData({ "text/uri-list": "https://example.com/page" });
  assert.equal(link.drop.defaultPrevented, false, "a link drop is left to the editor");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(prompt(), before);
  assert.equal(page.requests.filter((m) => m.method === "attachments.save").length, 0);
});

test("an assistant's inline image kept as an attachment is drawn from the page's scheme", async () => {
  const id = "thread-claude_00000000-0000-4000-8000-0000000000aa";
  const assistant = fixture.done.thread.messages.find((message) => message.role === "assistant");
  const at = new Date().toISOString();
  push({
    ...fixture.done.thread,
    updatedAt: at,
    messages: [
      ...fixture.done.thread.messages,
      {
        ...assistant,
        id: "assistant-with-chart",
        text: "Here is the chart:\n\n![chart](/Users/me/project/out/chart.png)",
        turnId: null,
        createdAt: at,
        updatedAt: at,
        attachments: [
          { type: "image", sourcePath: "/Users/me/project/out/chart.png", id, name: "chart.png", mimeType: "image/png", sizeBytes: 68 },
        ],
      },
    ],
  });
  const image = await waitFor(
    () => [...document.querySelectorAll("img")].find((img) => (img.getAttribute("src") ?? "").includes(id)),
    "the inline image",
  );
  assert.equal(image.getAttribute("src"), new URL(`/attachments/${id}`, window.location.origin).href);
  // Drawn from the attachment, not read as a local file (which the page cannot reach).
  assert.equal(page.requests.some((m) => /LocalFilePreviewGrant/.test(m.method)), false);
});

test("nothing failed: every push matched Synara's contract", () => {
  const logs = page.posted.filter((m) => m.kind === "event" && (m.name === "error" || (m.name === "log" && /decode|did not/i.test(m.payload?.message ?? ""))));
  assert.deepEqual(logs, []);
});
