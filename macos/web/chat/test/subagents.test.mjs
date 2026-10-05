// The subagent strip: a Claude turn that ran a subagent (recorded through cascade-chat's engine,
// test/fixtures/claude-subagent.json) draws Synara's ComposerSubagentStrip, reads the subagent's
// thread to tell whether it still runs, and asks the app to show it; on the subagent's own
// (read-only) page the strip leads back to the parent.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { context, loadPage, text, unload, waitFor } from "./harness.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const recorded = JSON.parse(readFileSync(join(here, "fixtures/claude-subagent.json"), "utf8"));
const parentId = recorded.parentRunning.id;
const childId = recorded.childRunning.id;
const SNAPSHOT_READ = "orchestration.getThreadDetailSnapshot";

let page;
let threads = { [parentId]: recorded.parentRunning, [childId]: recorded.childRunning };
let sequence = 100;
before(async () => {
  page = await loadPage();
  page.answerWith(SNAPSHOT_READ, (params) => {
    const thread = threads[params.threadId];
    return thread ? { snapshotSequence: sequence, thread } : null;
  });
});
after(async () => {
  await unload();
});

const events = (name) => page.posted.filter((message) => message.kind === "event" && message.name === name);
const reads = (threadId) => page.requests.filter((m) => m.method === SNAPSHOT_READ && m.params?.threadId === threadId);
const strip = () => document.querySelector('[data-testid="composer-subagent-strip"]');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function show(thread, extra = {}) {
  sequence += 10;
  page.push("context", { ...context, threadId: thread.id, projectId: thread.projectId, ...extra });
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: sequence, thread } });
}

test("a running subagent shows in the strip, read from its own thread, and opens it", async () => {
  show(recorded.parentRunning);
  await waitFor(strip, "the subagent strip");
  await waitFor(() => reads(childId).length > 0, "the subagent's thread read");
  await waitFor(() => /1 of 1 subagent running/.test(strip()?.textContent ?? ""), "the running count");
  assert.match(strip().textContent, /List files in current directory/);
  assert.match(strip().textContent, /general-purpose/);
  // A subagent still running is read again as the parent changes.
  const runningReads = reads(childId).length;
  show(recorded.parentRunning);
  await waitFor(() => reads(childId).length > runningReads, "the running subagent read again");

  const row = strip().querySelector('[data-testid="composer-subagent-row"] button');
  row.click();
  const open = await waitFor(() => events("openThread").at(-1), "the openThread event");
  assert.equal(open.payload.threadId, childId);

  const stop = strip().querySelector('button[aria-label="Stop subagent"]');
  assert.ok(stop, "a running subagent can be stopped");
  stop.click();
  const interrupt = await waitFor(
    () =>
      page.requests.find(
        (m) => m.method === "orchestration.dispatchCommand" && m.params?.command?.type === "thread.turn.interrupt",
      ),
    "the interrupt",
  );
  assert.equal(interrupt.params.command.threadId, childId);
});

test("once the parent's turn and the subagent are done, the strip retires", async () => {
  threads = { [parentId]: recorded.parentDone, [childId]: recorded.childDone };
  show(recorded.parentDone);
  await waitFor(() => !strip(), "the strip to retire");
  await waitFor(() => text().includes("The directory contains five files"), "the parent's answer");
});

test("a settled subagent is read once, not again on every push", async () => {
  threads = { [parentId]: recorded.parentDone, [childId]: recorded.childDone };
  show(recorded.parentDone);
  await sleep(700);
  const settledReads = reads(childId).length;
  assert.ok(settledReads > 0);
  for (let i = 0; i < 3; i++) {
    show(recorded.parentDone);
    await sleep(600);
  }
  assert.equal(reads(childId).length, settledReads, "no read of a subagent seen settled");
});

test("a subagent's page is read-only and its strip leads back to the parent", async () => {
  threads = { [parentId]: recorded.parentRunning, [childId]: recorded.childRunning };
  const before = events("openThread").length;
  show(recorded.childRunning, { readOnly: true });
  await waitFor(() => reads(parentId).length > 0, "the parent's thread read");
  const back = await waitFor(
    () => document.querySelector('[data-testid="composer-subagent-parent-row"] button'),
    "the parent row",
  );
  assert.equal(document.querySelector("[data-chat-composer-form]"), null, "no composer");
  const viewed = strip().querySelector('[data-testid="composer-subagent-row"][data-viewed]');
  assert.ok(viewed, "the subagent on screen is marked");
  back.click();
  const open = await waitFor(() => events("openThread").slice(before).at(-1), "the openThread event");
  assert.equal(open.payload.threadId, parentId);
});
