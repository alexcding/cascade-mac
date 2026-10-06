// Two chat pages share one localStorage (one WebKit data store for every chat page). Synara writes
// its composer drafts whole; storage.ts merges a page's write onto what the other page stored.
import assert from "node:assert/strict";
import { test } from "node:test";

import { mergeSharedValue } from "../src/storageMerge.ts";

const value = (drafts, extra = {}) => JSON.stringify({ state: { draftsByThreadId: drafts, stickyActiveProvider: null, ...extra }, version: 6 });
const drafts = (raw) => JSON.parse(raw).state.draftsByThreadId;

test("a page's write keeps the drafts another page stored since it read them", () => {
  const empty = value({});
  // Both pages read an empty store; page B then queues a follow-up on thread B.
  const stored = value({ b: { prompt: "", queuedTurns: [{ id: "q-b" }] } });
  // Page A writes its own draft, knowing nothing of B's.
  const merged = mergeSharedValue(empty, value({ a: { prompt: "draft a", queuedTurns: [] } }), stored);
  assert.deepEqual(drafts(merged), {
    a: { prompt: "draft a", queuedTurns: [] },
    b: { prompt: "", queuedTurns: [{ id: "q-b" }] },
  });
});

test("what a page changed or removed is its own; what it left alone is taken as stored", () => {
  const base = value({ a: { prompt: "1" }, b: { prompt: "old b" }, c: { prompt: "c" } });
  // Another page changed b since.
  const stored = value({ a: { prompt: "1" }, b: { prompt: "new b" }, c: { prompt: "c" } });
  // This page changed a and removed c (sent its queue), and still holds the old b.
  const next = value({ a: { prompt: "2" }, b: { prompt: "old b" } });
  assert.deepEqual(drafts(mergeSharedValue(base, next, stored)), { a: { prompt: "2" }, b: { prompt: "new b" } });
});

test("with nothing stored, or nothing changed under it, the page's value is written as it is", () => {
  const next = value({ a: { prompt: "x" } });
  assert.equal(mergeSharedValue(null, next, null), next);
  const base = value({ a: { prompt: "y" } });
  assert.equal(mergeSharedValue(base, next, base), next);
  // Another version, or a value that is not zustand's: the page's own.
  const other = JSON.stringify({ state: { draftsByThreadId: { z: {} } }, version: 5 });
  assert.equal(mergeSharedValue(base, next, other), next);
  assert.equal(mergeSharedValue(base, next, "not json"), next);
});
