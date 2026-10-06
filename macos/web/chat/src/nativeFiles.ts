// What the app pushes on "files" for the composer: the paths of files and folders to mention, and
// the images to attach. WebKit hands the page a dropped or pasted file with no path, and Synara
// asks Electron's desktop bridge for one, which this page does not have (and must not fake: its
// presence switches Synara into desktop mode). So a drop or paste of Finder files never reaches
// the page: the app takes it, sorts its files on disk (an image the agents take is read and sent
// here; anything else goes by its path) and pushes the lot in one message, as it does the paths
// its open panel picked. The app decides what is an image (`ChatPagePick`, ChatPageModel.swift).

export interface NativeFiles {
  /** Absolute paths, mentioned as `@path`. */
  paths: string[];
  /** Images to attach, as Synara's paste would hand them over. */
  images: File[];
}

/** The push, checked: a path that is not absolute and an image that does not decode are dropped. */
export function readNativeFiles(payload: unknown): NativeFiles {
  const value = (payload ?? {}) as { paths?: unknown; images?: unknown };
  const paths = Array.isArray(value.paths)
    ? value.paths.filter((path): path is string => typeof path === "string" && path.startsWith("/"))
    : [];
  const images: File[] = [];
  for (const image of Array.isArray(value.images) ? value.images : []) {
    const { name, mimeType, dataBase64 } = (image ?? {}) as Record<string, unknown>;
    if (typeof mimeType !== "string" || !mimeType.startsWith("image/") || typeof dataBase64 !== "string") continue;
    let bytes: Uint8Array<ArrayBuffer>;
    try {
      const binary = atob(dataBase64);
      bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    } catch {
      continue;
    }
    images.push(new File([bytes], typeof name === "string" && name ? name : "image", { type: mimeType }));
  }
  return { paths, images };
}
