// What is added to the composer goes one of two ways: an image is attached and uploaded, any other
// file and every folder is mentioned by its absolute path (`@/abs/path`) and never uploaded. The
// app's open panel pushes the paths it picked on "paths"; a Finder drag pushes its files on "drag"
// as it enters, and the drop is matched against them.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, providers, unload, waitFor } from "./harness.mjs";

const DRAFTS_KEY = "synara:composer-drafts:v1";

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

test("paths picked in the app's open panel become @path mentions", async () => {
  page.push("paths", { paths: ["/Users/me/project/src", "/tmp/notes and more.txt", "relative/ignored"] });
  const written = await waitFor(() => (prompt().includes("@/Users/me/project/src") ? prompt() : null), "the folder mention");
  assert.match(written, /@"\/tmp\/notes and more\.txt"/);
  assert.doesNotMatch(written, /relative\/ignored/);
  assert.deepEqual(draft().files ?? [], []);
  assert.deepEqual(uploads(), []);
});

function drop(files) {
  const shell = document.querySelector("[data-chat-composer-form] [contenteditable]");
  // What WebKit hands a drop from Finder. happy-dom's DataTransfer lists no "Files" type, and its
  // DragEvent leaves out an init's dataTransfer.
  const data = {
    types: ["Files"],
    files,
    items: files.map((file) => ({ kind: "file", type: file.type, getAsFile: () => file })),
    getData: () => "",
    dropEffect: "none",
  };
  const event = new window.DragEvent("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "dataTransfer", { value: data });
  shell.dispatchEvent(event);
}

test("a Finder drop mentions a file by the path the app pushed, and attaches an image", async () => {
  page.push("drag", {
    files: [
      { name: "README.md", path: "/Users/me/project/README.md", size: 5 },
      { name: "shot.png", path: "/Users/me/Desktop/shot.png", size: 4 },
    ],
  });
  drop([
    new window.File(["hello"], "README.md", { type: "text/markdown" }),
    new window.File([new Uint8Array([137, 80, 78, 71])], "shot.png", { type: "image/png" }),
  ]);
  await waitFor(() => prompt().includes("@/Users/me/project/README.md"), "the dropped file's mention");
  assert.doesNotMatch(prompt(), /shot\.png/, "an image is not mentioned");
  assert.deepEqual(draft().files ?? [], [], "no file is attached for upload");
  // The image goes Synara's way: prepared and attached, to be uploaded when the message is sent.
  const images = await waitFor(() => (draft().attachments?.length ? draft().attachments : null), "the attached image");
  assert.deepEqual(images.map((image) => image.name), ["shot.png"]);
});

test("a file whose path the page cannot learn is refused, not uploaded", async () => {
  // A drop with nothing pushed for it (a drag the app did not see).
  const before = prompt();
  drop([new window.File(["x"], "orphan.log", { type: "text/plain" })]);
  await waitFor(() => /Couldn't tell where orphan\.log is on disk/.test(document.body.textContent ?? ""), "the error");
  assert.equal(prompt(), before);
  assert.deepEqual(draft().files ?? [], []);
  assert.deepEqual(uploads(), []);
});
