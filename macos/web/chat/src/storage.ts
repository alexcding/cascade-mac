// Imported first by main.tsx, before any Synara module reads storage at load. Synara keeps
// its settings, theme, drafts and store snapshot in localStorage; if this page's origin has
// none (a WebKit data store that refuses it), an in-memory Storage stands in, so the page
// runs on the same code for the life of the page instead of throwing on the first write.
//
// Every chat page shares one persistent data store, so drafts and queued follow-ups outlive the
// page. Two pages open at once then share one localStorage, and the keys Synara writes whole
// with every thread in them are merged rather than overwritten (storageMerge.ts).
import { mergeSharedValue } from "./storageMerge";

/** Synara's composer drafts (composerDraftDomain.ts COMPOSER_DRAFT_STORAGE_KEY): every thread's
 *  draft and queued follow-ups, persisted whole. */
export const SHARED_KEYS: ReadonlySet<string> = new Set(["synara:composer-drafts:v1"]);

function usable(storage: Storage | undefined): boolean {
  try {
    if (!storage) return false;
    const key = "__cascade_probe__";
    storage.setItem(key, "1");
    storage.removeItem(key);
    return true;
  } catch {
    return false;
  }
}

class MemoryStorage implements Storage {
  private values = new Map<string, string>();
  get length() {
    return this.values.size;
  }
  clear() {
    this.values.clear();
  }
  getItem(key: string) {
    return this.values.get(String(key)) ?? null;
  }
  key(index: number) {
    return [...this.values.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.values.delete(String(key));
  }
  setItem(key: string, value: string) {
    this.values.set(String(key), String(value));
  }
}

/** A shared localStorage: a shared key's write merges onto what another page stored since. */
class SharedStorage implements Storage {
  /** What this page last read or wrote for each shared key. */
  private seen = new Map<string, string | null>();
  constructor(private readonly inner: Storage) {}
  get length() {
    return this.inner.length;
  }
  clear() {
    this.seen.clear();
    this.inner.clear();
  }
  getItem(key: string) {
    const value = this.inner.getItem(key);
    if (SHARED_KEYS.has(key)) this.seen.set(key, value);
    return value;
  }
  key(index: number) {
    return this.inner.key(index);
  }
  removeItem(key: string) {
    this.seen.delete(key);
    this.inner.removeItem(key);
  }
  setItem(key: string, value: string) {
    if (!SHARED_KEYS.has(key)) {
      this.inner.setItem(key, value);
      return;
    }
    this.inner.setItem(key, mergeSharedValue(this.seen.get(key) ?? null, String(value), this.inner.getItem(key)));
    this.seen.set(key, String(value));
  }
}

for (const name of ["localStorage", "sessionStorage"] as const) {
  let current: Storage | undefined;
  try {
    current = window[name];
  } catch {
    current = undefined;
  }
  if (!usable(current)) {
    Object.defineProperty(window, name, { configurable: true, value: new MemoryStorage() });
  } else if (name === "localStorage" && current) {
    Object.defineProperty(window, name, { configurable: true, value: new SharedStorage(current) });
  }
}

export {};
