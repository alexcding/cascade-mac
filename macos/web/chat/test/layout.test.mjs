// Where the composer sits: the session chat overlay's margins (TranscriptChatOverlay: 24pt
// either side, 18pt under the card) inside Synara's centred chat column, with the transcript's
// viewport ending at the composer's bottom edge.
//
// happy-dom lays nothing out, so the page it draws is laid out by headless Chrome, with the
// built stylesheet, at a full-window width and at a narrow pane's (500px, the narrowest window
// headless Chrome opens). Without Chrome only the structure is checked.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { after, before, test } from "node:test";

import { context, fixture, loadPage, pageDir, providers, unload, waitFor } from "./harness.mjs";

const CHROME = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const SIDE = 24;
const BOTTOM = 18;
const COLUMN = 736; // Synara's --app-chat-max-width default, 46rem

let html;
before(async () => {
  const page = await loadPage();
  page.push("context", context);
  page.push("providers", providers);
  page.push("thread", { kind: "snapshot", snapshot: fixture.done });
  await waitFor(() => document.querySelector("[data-chat-composer-form]"), "the composer");
  html = document.documentElement.outerHTML;
});
after(async () => {
  await unload();
});

test("the composer floats on a dock under the transcript, with a bottom margin", () => {
  const root = document.querySelector("[data-chat-root]");
  const dock = root.querySelector(":scope > [data-chat-composer-dock]");
  assert.ok(dock, "the dock is the root's child");
  const slot = dock.querySelector(":scope > [data-chat-composer-slot]");
  assert.ok(slot, "the composer is in the dock");
  assert.match(slot.className, /\bbottom-full\b/);
  assert.match(slot.className, /app-density-chat-gutter-x/);
  assert.ok(dock.querySelector(":scope > .chat-composer-bottom-margin"), "the margin under the composer");
});

/** Lays the drawn page out in Chrome at `width`×`height` and measures it. */
function measure(width, height) {
  const dir = mkdtempSync(join(tmpdir(), "chat-layout-"));
  try {
    const probe = `<script>
      const root = document.querySelector("[data-chat-root]").getBoundingClientRect();
      const frame = document.querySelector("[data-chat-composer-form]").firstElementChild.getBoundingClientRect();
      const pane = document.querySelector("[data-chat-root]").firstElementChild.getBoundingClientRect();
      document.body.setAttribute("data-measured", JSON.stringify({
        bottom: root.bottom - frame.bottom, left: frame.left - root.left, right: root.right - frame.right,
        width: frame.width, transcriptBottom: pane.bottom, composerBottom: frame.bottom,
      }));
    </script>`;
    const page = html
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, "")
      .replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, "")
      .replace("<head>", `<head><base href="${pathToFileURL(pageDir).href}/"><link rel="stylesheet" href="ChatPage.css">`)
      .replace("</body>", `${probe}</body>`);
    const file = join(dir, "page.html");
    writeFileSync(file, page);
    const dom = execFileSync(
      CHROME,
      ["--headless=new", "--disable-gpu", "--allow-file-access-from-files", `--window-size=${width},${height}`, "--dump-dom", pathToFileURL(file).href],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 60_000 },
    );
    const json = /data-measured="([^"]*)"/.exec(dom)?.[1];
    assert.ok(json, "the page was measured");
    return JSON.parse(json.replaceAll("&quot;", '"'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const chrome = existsSync(CHROME) ? false : "needs Chrome to lay the page out";

test("full window: the column is centred at its max width, 18px off the bottom", { skip: chrome }, () => {
  const m = measure(1400, 900);
  assert.equal(Math.round(m.bottom), BOTTOM);
  assert.equal(Math.round(m.width), COLUMN);
  assert.ok(Math.abs(m.left - m.right) <= 1, `centred: ${m.left} vs ${m.right}`);
  assert.ok(Math.abs(m.transcriptBottom - m.composerBottom) <= 1, "the transcript ends at the composer's bottom");
});

test("narrow pane: 24px either side, 18px off the bottom", { skip: chrome }, () => {
  const m = measure(500, 800);
  assert.equal(Math.round(m.bottom), BOTTOM);
  assert.equal(Math.round(m.left), SIDE);
  assert.equal(Math.round(m.right), SIDE);
  assert.ok(Math.abs(m.transcriptBottom - m.composerBottom) <= 1, "the transcript ends at the composer's bottom");
});
