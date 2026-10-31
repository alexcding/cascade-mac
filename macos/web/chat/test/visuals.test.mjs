// Inline visuals: a `visual.shown` activity (what the backend records when a chat's agent calls
// synara_show_visual) draws with Synara's own components where the reply places it, its source
// read over orchestration.getInlineVisual; a follow-up choice in it is sent as the next message.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, unload, waitFor } from "./harness.mjs";

const VISUAL_ID = "vis_0123456789abcdef0123456789abcdef";
const spec = {
  blocks: [
    { type: "stats", items: [{ label: "p95 latency", value: "120 ms", trend: "down", tone: "success" }] },
    {
      type: "bar-chart",
      unit: "ms",
      items: [
        { label: "api", value: 120, highlight: true },
        { label: "database", value: 40 },
      ],
    },
    { type: "choices", options: [{ label: "Profile the api", message: "Profile the api handler." }] },
  ],
};

let page;
before(async () => {
  page = await loadPage();
  page.answerWith("orchestration.getInlineVisual", (params) => {
    if (params.visualId !== VISUAL_ID) throw Object.assign(new Error("This visual is no longer available."), { code: "inline-visual-missing" });
    return { visualId: VISUAL_ID, html: JSON.stringify(spec) };
  });
});
after(async () => {
  await unload();
});

test("a visual.shown activity draws its component spec in the reply and sends its choice", async () => {
  const done = fixture.done.thread;
  const turnId = done.latestTurn.turnId;
  const assistant = done.messages.find((message) => message.role === "assistant");
  const fence = "```synara-visual\n" + VISUAL_ID + "\n```";
  const thread = {
    ...done,
    messages: done.messages.map((message) =>
      message === assistant ? { ...message, text: `The api is the slow part.\n\n${fence}\n\nProfile it first.` } : message,
    ),
    activities: [
      ...done.activities,
      {
        id: "gateway:0123456789abcdef0123456789abcdef:inline-visual",
        tone: "info",
        kind: "visual.shown",
        summary: "Visual: Latency",
        payload: {
          visualId: VISUAL_ID,
          format: "components",
          title: "Latency",
          height: 240,
          byteLength: JSON.stringify(spec).length,
          sha256: "0".repeat(64),
        },
        turnId,
        sequence: fixture.events.at(-1).sequence + 1,
        createdAt: assistant.createdAt,
      },
    ],
  };
  page.push("context", context);
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: fixture.events.at(-1).sequence + 1, thread } });

  const figure = await waitFor(() => document.querySelector("[data-inline-visual-blocks]"), "the visual's blocks");
  assert.equal(figure.getAttribute("aria-label"), "Latency");
  const read = page.requests.find((message) => message.method === "orchestration.getInlineVisual");
  assert.deepEqual(read.params, { threadId: done.id, visualId: VISUAL_ID });
  await waitFor(() => /p95 latency/.test(figure.textContent) && /120 ms/.test(figure.textContent), "the stats tile");
  assert.match(figure.textContent, /database/, "the bar chart's rows");
  // Placed by its fence, inside the reply between the text around it, not as code.
  const reply = figure.closest("[data-assistant-message-id]");
  assert.equal(reply?.getAttribute("data-assistant-message-id"), assistant.id);
  assert.match(reply.textContent, /The api is the slow part\.[^]*p95 latency[^]*Profile it first\./);
  assert.doesNotMatch(document.getElementById("chat").textContent, /synara-visual/);

  const choice = [...figure.querySelectorAll("button")].find((button) => /Profile the api/.test(button.textContent));
  assert.ok(choice, "the follow-up choice");
  choice.click();
  const sent = await waitFor(
    () =>
      page.requests.find(
        (message) =>
          message.method === "orchestration.dispatchCommand" && message.params?.command?.type === "thread.turn.start",
      ),
    "the choice sent as the next message",
  );
  assert.equal(sent.params.command.message.text, "Profile the api handler.");
});
