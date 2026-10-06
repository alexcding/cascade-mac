// Shim of the npm package @tanstack/react-router.
//
// The page has no router: it shows one thread. Synara's vendored modules still read route
// params (toast.tsx scopes thread toasts by the route's threadId), the diff route's search
// (useDiffRouteSearch) and the app history (appNavigation.ts, and the model picker's
// "Manage providers" link). This answers them with the page's one thread and a history that
// goes nowhere; a push to Synara's settings page is reported to the app as `openSettings`.
import { emit } from "../../bridge";

let currentThreadId: string | null = null;
/** ChatController sets the thread on screen, which the route would carry in Synara. */
export function setRouteThreadId(threadId: string | null): void {
  currentThreadId = threadId;
}

type Location = { pathname: string; search: string; hash: string; href: string; state: Record<string, unknown> };
type Listener = (event: { location: Location; action: { type: string } }) => void;

function createHistory() {
  const listeners = new Set<Listener>();
  const location: Location = { pathname: "/", search: "", hash: "", href: "/", state: { __TSR_index: 0 } };
  return {
    location,
    length: 1,
    subscribe(listener: Listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    push(path: string) {
      if (path.startsWith("/settings")) emit("openSettings", { path });
    },
    replace() {},
    go() {},
    back() {},
    forward() {},
    canGoBack: () => false,
    flush() {},
    block: () => () => undefined,
    createHref: (path: string) => path,
    destroy() {},
    notify() {},
  };
}

export const createBrowserHistory = createHistory;
export const createHashHistory = createHistory;
export const createMemoryHistory = (_options?: unknown) => createHistory();

type SelectOptions<T> = { strict?: boolean; select?: (value: Record<string, unknown>) => T };

export function useParams<T = Record<string, unknown>>(options?: SelectOptions<T>): T {
  const params: Record<string, unknown> = currentThreadId ? { threadId: currentThreadId } : {};
  return (options?.select ? options.select(params) : params) as T;
}

const EMPTY_SEARCH: Record<string, unknown> = {};
export function useSearch<T = Record<string, unknown>>(options?: SelectOptions<T>): T {
  return (options?.select ? options.select(EMPTY_SEARCH) : EMPTY_SEARCH) as T;
}

export function useNavigate() {
  return async (_options?: unknown) => undefined;
}
