//! Synara `apps/server/src/inlineVisualStore.ts`: where inline visual documents live on disk, and
//! how they are written, read and removed.
//!
//! Visual documents sit in a folder below the chat engine's attachments root,
//! `visuals/<sha256(threadId)>/vis_<32 hex>.html`. Nothing serves that folder as a file (the
//! page reads a visual through `orchestration.getInlineVisual`, and `attachments.read` takes only
//! a flat attachment id), and the thread's folder is removed when the thread is deleted.

use std::{
    io,
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};

use super::MAX_HTML_BYTES;

/// Synara `INLINE_VISUALS_DIRECTORY`.
pub const VISUALS_DIRECTORY: &str = "visuals";

/// Synara `InlineVisualId`: `vis_` and 32 lower-case hex digits.
pub fn is_visual_id(id: &str) -> bool {
    id.len() == 36
        && id.starts_with("vis_")
        && id[4..].bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Synara `toSafeThreadAttachmentSegment` reduced to the question the store asks of it: whether
/// the thread's id names an attachment segment at all (lower-cased, it keeps a letter or digit).
fn has_safe_segment(thread_id: &str) -> bool {
    thread_id.trim().to_lowercase().chars().any(|c| c.is_ascii_alphanumeric())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Synara `inlineVisualThreadDirectory`: directory ownership hashes the complete thread id.
pub fn thread_directory(attachments: &Path, thread_id: &str) -> Option<PathBuf> {
    has_safe_segment(thread_id).then(|| attachments.join(VISUALS_DIRECTORY).join(sha256_hex(thread_id.as_bytes())))
}

/// Synara `inlineVisualFilePath`.
pub fn file_path(attachments: &Path, thread_id: &str, visual_id: &str) -> Option<PathBuf> {
    if !is_visual_id(visual_id) {
        return None;
    }
    thread_directory(attachments, thread_id).map(|directory| directory.join(format!("{visual_id}.html")))
}

/// Synara `writeInlineVisual`: through a temporary file, so a reader never sees half a page, in a
/// folder and file only the user can read. Returns the file and whether it already existed: an
/// identical retry rewrites the same id, and only the call that created the file may remove it.
pub fn write(attachments: &Path, thread_id: &str, visual_id: &str, source: &str) -> io::Result<(PathBuf, bool)> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let path = file_path(attachments, thread_id, visual_id)
        .ok_or_else(|| io::Error::other("The visual could not be stored for this thread."))?;
    let existed = std::fs::metadata(&path).is_ok_and(|meta| meta.is_file());
    let directory = path.parent().expect("a visual's file is in its thread's folder");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
    let temporary = path.with_file_name(format!("{visual_id}.html.{}.tmp", uuid::Uuid::new_v4()));
    let written = (|| {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(source.as_bytes())?;
        std::fs::rename(&temporary, &path)
    })();
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok((path, existed))
}

/// Synara `readInlineVisual`: the stored source, or `None` when it is missing, oversized, or the
/// id is not a visual's.
pub fn read(attachments: &Path, thread_id: &str, visual_id: &str) -> io::Result<Option<String>> {
    let Some(path) = file_path(attachments, thread_id, visual_id) else { return Ok(None) };
    match std::fs::metadata(&path) {
        Ok(meta) if meta.is_file() && meta.len() <= MAX_HTML_BYTES as u64 => std::fs::read_to_string(&path).map(Some),
        Ok(_) => Ok(None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// Synara's thread-deletion side effect (`ProjectionPipeline.ts`): the thread's visuals go with it.
pub fn remove_thread(attachments: &Path, thread_id: &str) -> io::Result<()> {
    let Some(directory) = thread_directory(attachments, thread_id) else { return Ok(()) };
    match std::fs::remove_dir_all(&directory) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    const ID: &str = "vis_0123456789abcdef0123456789abcdef";

    #[test]
    fn a_visual_is_written_privately_read_back_and_removed_with_its_thread() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let (path, existed) = write(root, "thread-1", ID, "<p>hi</p>").unwrap();
        assert!(!existed);
        assert_eq!(path, root.join("visuals").join(sha256_hex(b"thread-1")).join(format!("{ID}.html")));
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(path.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(std::fs::read_dir(path.parent().unwrap()).unwrap().count(), 1, "no temporary file is left");
        assert!(write(root, "thread-1", ID, "<p>hi</p>").unwrap().1, "a retry finds the file it wrote");
        assert_eq!(read(root, "thread-1", ID).unwrap().as_deref(), Some("<p>hi</p>"));

        // Another thread's visual, an id that is not a visual's, and an unsafe thread id read nothing.
        assert_eq!(read(root, "thread-2", ID).unwrap(), None);
        assert_eq!(read(root, "thread-1", "vis_../../etc").unwrap(), None);
        assert_eq!(read(root, "thread-1", "vis_0123456789ABCDEF0123456789ABCDEF").unwrap(), None);
        assert!(write(root, " -_ ", ID, "x").is_err());

        // An oversized file is not read.
        std::fs::write(&path, "x".repeat(MAX_HTML_BYTES + 1)).unwrap();
        assert_eq!(read(root, "thread-1", ID).unwrap(), None);

        write(root, "thread-2", ID, "kept").unwrap();
        remove_thread(root, "thread-1").unwrap();
        assert!(!path.parent().unwrap().exists());
        remove_thread(root, "thread-1").unwrap();
        assert_eq!(read(root, "thread-2", ID).unwrap().as_deref(), Some("kept"));
    }
}
