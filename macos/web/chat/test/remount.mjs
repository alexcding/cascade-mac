// A page loaded afresh, as the app makes one when a chat's screen comes back: it reads the
// localStorage an earlier page left (stdin: { storage, context, snapshot, waitMs }), is handed
// the context, the providers and the thread, and runs for `waitMs`. Prints what it sent as
// thread.turn.start, and its localStorage once it has written what it holds back.
// Run by queue-restore.test.mjs, one process per page: a page's bundle loads once per process.
import { readFileSync } from "node:fs";

import { loadPage, providers, unload } from "./harness.mjs";

const input = JSON.parse(readFileSync(0, "utf8"));
const page = await loadPage({ storage: input.storage });
page.push("context", input.context);
page.push("providers", providers);
page.push("thread", { kind: "snapshot", snapshot: input.snapshot });
await new Promise((resolve) => setTimeout(resolve, input.waitMs));
window.nativeChat.flush();
const storage = {};
for (let index = 0; index < window.localStorage.length; index += 1) {
  const key = window.localStorage.key(index);
  storage[key] = window.localStorage.getItem(key);
}
const turnStarts = page.requests
  .filter((m) => m.method === "orchestration.dispatchCommand" && m.params?.command?.type === "thread.turn.start")
  .map((m) => m.params.command);
const errors = page.posted.filter((m) => m.kind === "event" && m.name === "error").map((m) => m.payload.message);
process.stdout.write(JSON.stringify({ turnStarts, storage, errors }));
await unload();
process.exit(0);
