// What is added to the composer goes one of two ways: an image is attached and uploaded, any other
// file and every folder is mentioned by its absolute path (`@/abs/path`) and never uploaded. The
// app pushes on "files" what its open panel picked and what a drop or paste of Finder files
// carries (that gesture is the app's whole, and never reaches the page): the paths to mention and
// the images it read. A drop or paste with no Finder files in it reaches the page and goes
// Synara's way.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, unload, waitFor } from "./harness.mjs";

const DRAFTS_KEY = "synara:composer-drafts:v1";
const MAX_ATTACHMENTS = 8; // Synara's PROVIDER_SEND_TURN_MAX_ATTACHMENTS

let page;
before(async () => {
  page = await loadPage();
  page.push("context", context);
  page.push("providers", providers);
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: 50, thread: fixture.done.thread } });
  await waitFor(() => document.querySelector("[data-chat-composer-form] [contenteditable]"), "the composer");
});
after(async () => {
  await unload();
});

/** The thread's composer draft, as the page writes it. */
function draft() {
  window.nativeChat.flush();
  const drafts = JSON.parse(window.localStorage.getItem(DRAFTS_KEY) ?? "{}");
  return drafts.state?.draftsByThreadId?.[context.threadId] ?? {};
}
const prompt = () => draft().prompt ?? "";
const uploads = () => page.requests.filter((m) => m.method === "attachments.save");

/** What WebKit hands a drop or paste of `files`. happy-dom's DataTransfer lists no "Files" type. */
function transfer(files) {
  return {
    types: ["Files"],
    files,
    items: files.map((file) => ({ kind: "file", type: file.type, getAsFile: () => file })),
    getData: () => "",
    dropEffect: "none",
  };
}
const editor = () => document.querySelector("[data-chat-composer-form] [contenteditable]");

function drop(files) {
  // happy-dom's DragEvent leaves out an init's dataTransfer.
  const event = new window.DragEvent("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", { value: transfer(files) });
  editor().dispatchEvent(event);
  return event;
}

function paste(files) {
  const event = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: transfer(files) });
  editor().dispatchEvent(event);
  return event;
}

/** An image as the app sends it on "files". */
const pushed = (name, mimeType = "image/png") => ({
  name,
  mimeType,
  dataBase64: Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).toString("base64"),
});
const attachments = () => draft().attachments ?? [];
const bodyText = () => document.body.textContent ?? "";

test("paths picked in the app's open panel become @path mentions", async () => {
  page.push("files", { paths: ["/Users/me/project/src", "/tmp/notes and more.txt", "relative/ignored"], images: [] });
  const written = await waitFor(() => (prompt().includes("@/Users/me/project/src") ? prompt() : null), "the folder mention");
  assert.match(written, /@"\/tmp\/notes and more\.txt"/);
  assert.doesNotMatch(written, /relative\/ignored/);
  assert.deepEqual(draft().files ?? [], []);
  assert.deepEqual(uploads(), []);
});

test("a Finder drop's push mentions its paths and attaches its images", async () => {
  const attached = attachments().length;
  page.push("files", {
    paths: ["/Users/me/project/README.md", "/Users/me/Desktop/raw.cr2", "/Users/me/Screenshots.png"],
    images: [pushed("shot.png"), { name: "broken.png", mimeType: "image/png", dataBase64: "%%%" }, { name: "x", dataBase64: "AA==" }],
  });
  await waitFor(() => prompt().includes("@/Users/me/project/README.md"), "the dropped file's mention");
  assert.match(prompt(), /@\/Users\/me\/Desktop\/raw\.cr2/);
  // A folder named like an image comes as a path, and is mentioned, never attached.
  assert.match(prompt(), /@\/Users\/me\/Screenshots\.png/);
  assert.doesNotMatch(prompt(), /shot\.png/, "an image is not mentioned");
  assert.deepEqual(draft().files ?? [], [], "no file is attached for upload");
  const images = await waitFor(() => (attachments().length > attached ? attachments() : null), "the attached image");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(attachments().slice(attached).map((image) => image.name), ["shot.png"], "only images that decode");
  assert.ok(images.length > attached);
  assert.doesNotMatch(bodyText(), /Couldn't tell where/);
});

test("a drop or paste with no Finder files uploads any image, as Synara does", async () => {
  const attached = attachments().length;
  // A BMP dragged from a web page, then one pasted from the clipboard: no path, still an image.
  drop([new window.File([new Uint8Array([66, 77, 0, 0])], "picture.bmp", { type: "image/bmp" })]);
  paste([new window.File([new Uint8Array([66, 77, 0, 1])], "clip.bmp", { type: "image/bmp" })]);
  const names = await waitFor(
    () => (attachments().length >= attached + 2 ? attachments().slice(attached).map((image) => image.name) : null),
    "the two BMP images",
  );
  assert.deepEqual(names, ["picture.bmp", "clip.bmp"]);
  assert.doesNotMatch(bodyText(), /Couldn't tell where/);
});

test("a file with no path is refused, without pointing at + or Finder", async () => {
  drop([new window.File(["x"], "orphan.log", { type: "text/plain" })]);
  const message = await waitFor(
    () => (/Couldn't tell where orphan\.log is on disk[^.]*\./.test(bodyText()) ? bodyText() : null),
    "the error",
  );
  assert.doesNotMatch(message, /Finder| with \+/);
  assert.doesNotMatch(prompt(), /orphan\.log/);
  assert.deepEqual(draft().files ?? [], []);
  assert.deepEqual(uploads(), []);
});

test("images pushed past the attachment limit are refused with Synara's message", async () => {
  const room = MAX_ATTACHMENTS - attachments().length;
  assert.ok(room > 0, "the earlier tests leave room");
  page.push("files", { paths: [], images: Array.from({ length: room + 1 }, (_, index) => pushed(`many-${index}.png`)) });
  await waitFor(() => attachments().length === MAX_ATTACHMENTS, "the draft full");
  await waitFor(() => bodyText().includes(`You can attach up to ${MAX_ATTACHMENTS} references per message.`), "the limit");
  assert.ok(!attachments().some((image) => image.name === `many-${room}.png`));
});

test("while a plan question waits, the app's files are refused, not mentioned or attached", async () => {
  const atApproval = fixture.atApproval.thread;
  const approval = atApproval.activities.find((activity) => activity.kind === "approval.requested");
  const asked = {
    ...approval,
    id: "activity-question-attach",
    kind: "user-input.requested",
    summary: "User input requested",
    tone: "info",
    payload: {
      requestId: "question-attach",
      questions: [{ id: "q", header: "Pick", question: "Which one?", options: [{ label: "A", description: "a" }] }],
    },
  };
  const asking = {
    ...atApproval,
    updatedAt: new Date().toISOString(),
    activities: [...atApproval.activities.filter((activity) => activity !== approval), asked],
  };
  page.push("thread", { kind: "snapshot", snapshot: { snapshotSequence: 60, thread: asking } });
  await waitFor(() => (document.body.textContent ?? "").includes("Which one?"), "the question card");
  const before = prompt();
  const attached = attachments().length;
  page.push("files", { paths: ["/Users/me/project/later.md"], images: [pushed("later.png")] });
  await waitFor(
    () => /Attach files after answering plan questions/.test(document.body.textContent ?? ""),
    "the refusal",
  );
  assert.equal(prompt(), before);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(attachments().length, attached);
});
