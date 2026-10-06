// Which files the page may ask the app to open or reveal: those inside the thread's workspace
// (context.cwd) or the user's home folder (context.homeDir). The app checks again; this keeps
// a path a transcript happens to contain from reaching it at all.
import type { ChatContext } from "./bridge";

/** Resolves `.` and `..` in an absolute path; null if it climbs above the root. */
function normalize(path: string): string | null {
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return null;
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  return `/${parts.join("/")}`;
}

function rootOf(value: string | undefined): string | null {
  if (!value || !value.startsWith("/")) return null;
  const root = normalize(value);
  // A root of "/" would admit every file.
  return root && root !== "/" ? root : null;
}

/**
 * The absolute path `path` names (relative to the workspace, `~/` to the home folder, or a
 * file: URL), if it lies inside the workspace or the home folder; null otherwise.
 */
export function containedPath(
  path: string,
  context: Pick<ChatContext, "cwd" | "homeDir"> | null | undefined,
): string | null {
  if (typeof path !== "string" || !path.trim() || path.includes("\0")) return null;
  const cwd = rootOf(context?.cwd);
  const home = rootOf(context?.homeDir);
  let value = path.trim();
  if (/^file:\/\//i.test(value)) {
    try {
      value = decodeURIComponent(new URL(value).pathname);
    } catch {
      return null;
    }
  }
  if (value === "~" || value.startsWith("~/")) {
    if (!home) return null;
    value = home + value.slice(1);
  } else if (!value.startsWith("/")) {
    if (!cwd) return null;
    value = `${cwd}/${value}`;
  }
  const absolute = normalize(value);
  if (!absolute) return null;
  const inside = (root: string | null) => root !== null && (absolute === root || absolute.startsWith(`${root}/`));
  return inside(cwd) || inside(home) ? absolute : null;
}
