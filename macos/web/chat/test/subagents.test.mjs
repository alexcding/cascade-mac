// Subagents: a Claude turn that ran a subagent (recorded through cascade-chat's engine,
// test/fixtures/claude-subagent.json) draws Synara's subagent run card in the transcript and the
// composer's "N agents running" capsule (which stands in for the card's "N running" chip), reads the subagent's thread to tell whether it still runs, and asks the app to
// show it; the subagent's own (read-only) page opens with Synara's subagent intro, which leads
// back to the parent.
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
const card = () => document.querySelector('[data-testid="subagent-run-card"]');
const chip = () => document.querySelector('[data-testid="subagent-running-chip"]');
const capsule = () => document.querySelector('[data-testid="running-agents-capsule"]');
const rows = () => [...(card()?.querySelectorAll('[data-testid="subagent-run-row"]') ?? [])];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function show(thread, extra = {}) {
  sequence += 10;
  page.push("context", { ...context, threadId: thread.id, projectId: thread.projectId, ...extra });
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: sequence, thread } });
}

/** Opens the card's rows (it starts folded, as an expanded tool group would not). */
async function expandCard() {
  const toggle = await waitFor(() => card()?.querySelector("button[aria-expanded]"), "the card's header");
  if (toggle.getAttribute("aria-expanded") !== "true") toggle.click();
  return waitFor(() => (rows().length > 0 ? rows() : null), "the card's rows");
}

test("a running subagent shows in its transcript card, read from its own thread, and opens it", async () => {
  show(recorded.parentRunning);
  await waitFor(card, "the subagent run card");
  await waitFor(() => reads(childId).length > 0, "the subagent's thread read");
  await waitFor(() => /1 agent running/.test(capsule()?.textContent ?? ""), "the running agents capsule");
  // One indicator is enough: while the capsule counts the agent, the card's chip stays hidden.
  assert.equal(chip(), null, "no running chip beside the capsule");
  // A subagent still running is read again as the parent changes.
  const runningReads = reads(childId).length;
  show(recorded.parentRunning);
  await waitFor(() => reads(childId).length > runningReads, "the running subagent read again");

  const [row] = await expandCard();
  await waitFor(() => row.getAttribute("data-phase") === "running" || row.getAttribute("data-phase") === "waiting", "the running row");
  assert.equal(row.querySelector('button[aria-label="Run in background (ctrl+b)"]'), null, "no background offer");
  row.querySelector('button[aria-label^="Open "]').click();
  const open = await waitFor(() => events("openThread").at(-1), "the openThread event");
  assert.equal(open.payload.threadId, childId);

  const stop = row.querySelector('button[aria-label^="Stop "]');
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

test("once the parent's turn and the subagent are done, the card settles and the capsule goes", async () => {
  threads = { [parentId]: recorded.parentDone, [childId]: recorded.childDone };
  show(recorded.parentDone);
  await waitFor(() => !capsule() && !chip(), "the running agents capsule to go");
  await waitFor(() => text().includes("The directory contains five files"), "the parent's answer");
  const [row] = await expandCard();
  await waitFor(() => row.getAttribute("data-phase") === "done", "the settled row");
  assert.equal(row.querySelector('button[aria-label^="Stop "]'), null, "nothing left to stop");
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

test("a subagent's page is read-only and its intro leads back to the parent", async () => {
  threads = { [parentId]: recorded.parentRunning, [childId]: recorded.childRunning };
  const before = events("openThread").length;
  show(recorded.childRunning, { readOnly: true });
  await waitFor(() => reads(parentId).length > 0, "the parent's thread read");
  const back = await waitFor(
    () => document.querySelector('[data-testid="subagent-thread-intro"] button[aria-label^="Open parent thread"]'),
    "the way back to the parent",
  );
  assert.equal(document.querySelector("[data-chat-composer-form]"), null, "no composer");
  back.click();
  const open = await waitFor(() => events("openThread").slice(before).at(-1), "the openThread event");
  assert.equal(open.payload.threadId, parentId);
});

test("a read-only page with a running subagent keeps the card's chip, having no composer for the capsule", async () => {
  threads = { [parentId]: recorded.parentRunning, [childId]: recorded.childRunning };
  show(recorded.parentRunning, { readOnly: true });
  await waitFor(card, "the subagent run card");
  await waitFor(chip, "the running chip");
  assert.equal(capsule(), null, "no capsule without a composer");
});
