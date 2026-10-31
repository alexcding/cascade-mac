// The paths an editor's file tree (VS Code, Cursor, …) drags onto the composer, as Synara reads
// them (composerDropPaths.ts readDroppedPathReferences, from 0cf5ea460's "Accept folders dragged
// from editor file trees"): a folder carries no File, only its path, as `codefiles` (a JSON array
// of absolute paths) and/or a `text/uri-list` of file:// URLs.
//
// Synara reads them only under its desktop shell (`window.desktopBridge`), where the paths are on
// the machine its agent runs on; in a browser they would name another computer's files. The page
// runs beside its agent on the same Mac, as the desktop does, so it reads them too. Most drags
// from an editor carry file URLs on the pasteboard and so are the app's (a Finder-files drop,
// pushed on "files"); this covers one that reaches the page.
import { isLocalAbsolutePath } from "@synara/shared/path";

import { CODE_FILES_DRAG_TYPE } from "~/lib/composerDropPaths";

const URI_LIST_DRAG_TYPE = "text/uri-list";

/** Whether a drag may carry paths. A `text/uri-list` may as well be a web link: read it on drop. */
export function hasEditorPathTypes(types: readonly string[]): boolean {
  return types.includes(CODE_FILES_DRAG_TYPE) || types.includes(URI_LIST_DRAG_TYPE);
}

function fileUrlToAbsolutePath(value: string): string | null {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== "file:") return null;
  let path: string;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    return null;
  }
  if (url.host && url.host !== "localhost") return null;
  return isLocalAbsolutePath(path) && !path.includes("\0") ? path : null;
}

function readCodeFilesPaths(raw: string): string[] {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (entry): entry is string => typeof entry === "string" && isLocalAbsolutePath(entry) && !entry.includes("\0"),
    );
  } catch {
    return [];
  }
}

/** The local absolute paths a drop carries from an editor's tree; none for a web link. */
export function readEditorDropPaths(dataTransfer: Pick<DataTransfer, "types" | "getData">): string[] {
  const types = Array.from(dataTransfer.types);
  let paths: string[] = [];
  if (types.includes(CODE_FILES_DRAG_TYPE)) paths = readCodeFilesPaths(dataTransfer.getData(CODE_FILES_DRAG_TYPE));
  if (paths.length === 0 && types.includes(URI_LIST_DRAG_TYPE)) {
    paths = dataTransfer
      .getData(URI_LIST_DRAG_TYPE)
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith("#"))
      .map(fileUrlToAbsolutePath)
      .filter((path): path is string => path !== null);
  }
  return Array.from(new Set(paths));
}
