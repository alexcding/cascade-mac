// Every chat page shares one WebKit data store (ChatPageModel.swift `ChatPageHost.dataStore`), so
// two pages open at once share one localStorage. Synara's stores are written whole: zustand's
// persist writes `{ state, version }` with every thread's draft, as this page last knew them. A
// page that wrote that over another page's newer write would drop the other's drafts and queued
// follow-ups. A shared key is merged instead, entry by entry: what this page changed since it
// last read or wrote the key is its own, and everything else is kept as stored.
//
// No imports: the tests load this file directly.

type Json = unknown;

function isRecord(value: Json): value is Record<string, Json> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function same(a: Json, b: Json): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function parse(raw: string | null): Json {
  if (raw === null) return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

/** One field of a state: what this page changed wins, what it left alone is taken as stored. */
function mergeField(base: Json, next: Json, stored: Json): Json {
  if (isRecord(next) && isRecord(stored) && (base === undefined || isRecord(base))) {
    const result: Record<string, Json> = {};
    const before = (base ?? {}) as Record<string, Json>;
    for (const key of new Set([...Object.keys(stored), ...Object.keys(next), ...Object.keys(before)])) {
      const value = same(next[key], before[key]) ? stored[key] : next[key];
      if (value !== undefined) result[key] = value;
    }
    return result;
  }
  return same(next, base) && stored !== undefined ? stored : next;
}

/**
 * The value to store for a shared key: `next`, this page's whole value, merged onto `stored`,
 * what is stored now, given `base`, what this page last read or wrote. A value that is not
 * zustand's `{ state, version }`, or one of another version, is written as it is.
 */
export function mergeSharedValue(base: string | null, next: string, stored: string | null): string {
  if (stored === null || stored === base) return next;
  const nextValue = parse(next);
  const storedValue = parse(stored);
  const baseValue = parse(base);
  if (!isRecord(nextValue) || !isRecord(storedValue) || !isRecord(nextValue.state) || !isRecord(storedValue.state)) return next;
  if (nextValue.version !== storedValue.version) return next;
  const baseState = isRecord(baseValue) && baseValue.version === nextValue.version && isRecord(baseValue.state) ? baseValue.state : {};
  const state: Record<string, Json> = {};
  for (const key of new Set([...Object.keys(storedValue.state), ...Object.keys(nextValue.state)])) {
    const value = mergeField(baseState[key], nextValue.state[key], storedValue.state[key]);
    if (value !== undefined) state[key] = value;
  }
  return JSON.stringify({ ...nextValue, state });
}
