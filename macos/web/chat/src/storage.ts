// Imported first by main.tsx, before any Synara module reads storage at load. Synara keeps
// its settings, theme, drafts and store snapshot in localStorage; if this page's origin has
// none (a WebKit data store that refuses it), an in-memory Storage stands in, so the page
// runs on the same code for the life of the page instead of throwing on the first write.
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

for (const name of ["localStorage", "sessionStorage"] as const) {
  let current: Storage | undefined;
  try {
    current = window[name];
  } catch {
    current = undefined;
  }
  if (!usable(current)) {
    Object.defineProperty(window, name, { configurable: true, value: new MemoryStorage() });
  }
}

export {};
