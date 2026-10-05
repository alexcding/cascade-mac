// A follow-up queued while a turn runs lives in the page's localStorage (Synara's composer
// drafts), and the app's chat pages share one persistent data store: leaving the chat closes its
// page, and the page made when it comes back finds the queue. This queues one in a page, then
// loads fresh pages (each in a process of its own, test/remount.mjs) on what it left.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, typeInComposer, unload, waitFor } from "./harness.mjs";

const DRAFTS_KEY = "synara:composer-drafts:v1";
const FOLLOW_UP = "Queued for after the turn.";
const here = dirname(fileURLToPath(import.meta.url));

let page;
before(async () => {
  page = await loadPage();
});
after(async () => {
  await unload();
});

const idle = fixture.done.thread;
const at = new Date().toISOString();
const running = {
  ...idle,
  latestTurn: { ...idle.latestTurn, turnId: "turn-2", assistantMessageId: null, requestedAt: at, startedAt: at, completedAt: null, state: "running" },
  session: { ...idle.session, status: "running", activeTurnId: "turn-2", updatedAt: at },
};

/** A new page on `storage`, shown `thread` under `pageContext`. */
function remount(storage, pageContext, thread, waitMs = 2500) {
  const result = spawnSync(process.execPath, [join(here, "remount.mjs")], {
    input: JSON.stringify({ storage, context: pageContext, snapshot: { snapshotSequence: 100, thread }, waitMs }),
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

const queued = (storage, threadId) =>
  JSON.parse(storage[DRAFTS_KEY] ?? "{}").state?.draftsByThreadId?.[threadId]?.queuedTurns ?? [];

let left;

test("a follow-up queued during a running turn is written to the page's storage", async () => {
  page.push("context", context);
  page.push("providers", providers);
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: 50, thread: running } });
  await waitFor(() => /Ask for follow-up changes/.test(document.getElementById("chat")?.textContent ?? ""), "the running composer");
  await typeInComposer(FOLLOW_UP);
  await new Promise((resolve) => setTimeout(resolve, 50));
  document.querySelector("[data-chat-composer-form]").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  // The app has the page write what it holds back before it closes it (ChatPageHost.close).
  const turns = await waitFor(() => {
    window.nativeChat.flush();
    left = { [DRAFTS_KEY]: window.localStorage.getItem(DRAFTS_KEY) };
    const turns = queued(left, context.threadId);
    return turns.length > 0 ? turns : null;
  }, "the queued follow-up in storage");
  assert.equal(turns.length, 1);
  assert.equal(turns[0].prompt, FOLLOW_UP);
  // Queued, not sent.
  const sent = page.requests.filter((m) => m.params?.command?.type === "thread.turn.start");
  assert.deepEqual(sent, []);
});

test("another chat's page neither sends nor drops the queue", () => {
  const other = { ...idle, id: "thread-two", session: { ...idle.session, threadId: "thread-two" } };
  const result = remount(left, { ...context, threadId: "thread-two" }, other, 1500);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.turnStarts, []);
  assert.equal(queued(result.storage, "thread-two").length, 0);
  assert.equal(queued(result.storage, context.threadId)[0]?.prompt, FOLLOW_UP);
});

for (const [status, why] of [
  ["ready", "its session idle"],
  ["stopped", "its CLI gone, as after a restart"],
]) {
  test(`the chat's page, back on the thread with its turn over and ${why}, sends the queued follow-up`, () => {
    const thread = { ...idle, session: { ...idle.session, status } };
    const result = remount(left, context, thread);
    assert.deepEqual(result.errors, []);
    assert.equal(result.turnStarts.length, 1, JSON.stringify(result.turnStarts));
    const [command] = result.turnStarts;
    assert.equal(command.threadId, context.threadId);
    assert.equal(command.message.text, FOLLOW_UP);
    assert.equal(command.dispatchMode, "queue");
    // Sent, it leaves the queue.
    assert.equal(queued(result.storage, context.threadId).length, 0);
  });
}
