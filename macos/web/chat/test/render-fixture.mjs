// `npm run dev:fixture`: renders the recorded thread in the built page (happy-dom) and prints
// what the page shows and what it said to the app, at the approval and after the turn.
import { writeFileSync } from "node:fs";
import { context, fixture, loadPage, providers, text, unload, waitFor } from "./harness.mjs";

const { posted, push } = await loadPage();
push("context", context);
push("providers", providers);
push("thread", { kind: "snapshot", snapshot: fixture.atApproval });
await waitFor(() => document.querySelector("[data-chat-composer-form]"), "the composer").catch((e) => console.error(e.message));
await new Promise((r) => setTimeout(r, 1500));
console.log("--- at the approval\n" + text().replace(/\s+/g, " ").slice(0, 3000));
for (const event of fixture.events.slice(fixture.atApproval.snapshotSequence)) push("thread", { kind: "event", event });
await new Promise((r) => setTimeout(r, 1500));
console.log("--- after the turn\n" + text().replace(/\s+/g, " ").slice(0, 3000));
console.log("--- the page said\n" + posted.map((m) => JSON.stringify(m).slice(0, 300)).join("\n"));
if (process.env.HTML_OUT) writeFileSync(process.env.HTML_OUT, document.documentElement.outerHTML);
await unload();
process.exit(0);
