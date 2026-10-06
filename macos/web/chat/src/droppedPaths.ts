// Where the files of a Finder drag are on disk. WebKit hands the page File objects with no path,
// and Synara asks Electron's desktop bridge for one, which this page does not have (and must not
// fake: its presence switches Synara into desktop mode). So the app reads the drag's file URLs as
// it enters the web view and pushes them on the "drag" channel; a drop matches its Files against
// them by name, and by size when two share a name.
import { onPush } from "./bridge";

/** One file or folder of the drag, as the app pushes it. */
export interface DraggedFile {
  name: string;
  path: string;
  size?: number;
  directory?: boolean;
}

let dragged: DraggedFile[] = [];

onPush<{ files?: unknown }>("drag", (payload) => {
  const files = Array.isArray(payload?.files) ? payload.files : [];
  dragged = files.filter(
    (file): file is DraggedFile =>
      typeof file === "object" &&
      file !== null &&
      typeof (file as DraggedFile).name === "string" &&
      typeof (file as DraggedFile).path === "string" &&
      (file as DraggedFile).path.startsWith("/"),
  );
});

/**
 * The absolute paths of `files`, dropped from the drag the app last pushed, in order; null for a
 * file the drag does not name. Each pushed entry is used once.
 */
export function droppedFilePaths(files: readonly File[]): Array<string | null> {
  const unused = [...dragged];
  return files.map((file) => {
    const named = unused.filter((entry) => entry.name === file.name);
    const match =
      named.find((entry) => !entry.directory && entry.size === file.size) ??
      named.find((entry) => entry.directory) ??
      named[0];
    if (!match) return null;
    unused.splice(unused.indexOf(match), 1);
    return match.path;
  });
}

/** The drop is over: what was pushed for it names nothing later. */
export function forgetDrag(): void {
  dragged = [];
}
