//! Ported from Synara `apps/server/src/provider/attachmentProjection.ts`: the prompt text for
//! attachments a provider must read from disk.
//!
//! Synara resolves an attachment's file through `providerAttachmentPaths.ts`, which falls back to
//! the flat layout of `attachmentStore.ts` (`<attachmentsDir>/<id><ext>`). Managed attachments
//! (a repository record per blob) are not ported, so the flat layout is the only one: the app
//! saves each attachment as `<attachments dir>/<id><ext>`, the extension inferred as
//! [`attachment_relative_path`] does, and hands the adapter that directory.

use std::path::{Component, Path, PathBuf};

use crate::contracts::orchestration::{ChatAttachment, ChatFileAttachment, ChatImageAttachment};

/// Which file attachments a provider takes as a path block (attachmentProjection.ts:15).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectedAttachments {
    AllFiles,
    NonPdfFiles,
}

/// An image or file attachment: the two kinds that live on disk.
#[derive(Clone, Copy, Debug)]
pub enum StoredAttachment<'a> {
    Image(&'a ChatImageAttachment),
    File(&'a ChatFileAttachment),
}

impl StoredAttachment<'_> {
    fn id(&self) -> &str {
        match self {
            Self::Image(image) => &image.id,
            Self::File(file) => &file.id,
        }
    }

    fn name(&self) -> &str {
        match self {
            Self::Image(image) => &image.name,
            Self::File(file) => &file.name,
        }
    }

    fn mime_type(&self) -> &str {
        match self {
            Self::Image(image) => &image.mime_type,
            Self::File(file) => &file.mime_type,
        }
    }

    fn size_bytes(&self) -> u64 {
        match self {
            Self::Image(image) => image.size_bytes,
            Self::File(file) => file.size_bytes,
        }
    }
}

fn is_projected_file_attachment<'a>(
    attachment: &'a ChatAttachment,
    include: ProjectedAttachments,
    include_image: Option<&dyn Fn(&ChatImageAttachment) -> bool>,
) -> Option<StoredAttachment<'a>> {
    match attachment {
        ChatAttachment::Image(image) => {
            include_image.is_some_and(|include| include(image)).then_some(StoredAttachment::Image(image))
        }
        ChatAttachment::File(file) => match include {
            ProjectedAttachments::AllFiles => Some(StoredAttachment::File(file)),
            ProjectedAttachments::NonPdfFiles => {
                (file.mime_type.to_lowercase() != "application/pdf").then_some(StoredAttachment::File(file))
            }
        },
        ChatAttachment::AssistantSelection(_) => None,
    }
}

fn quote_prompt_value(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| format!("\"{value}\""))
}

/// Synara `buildFileAttachmentsPromptBlock` (attachmentProjection.ts:33): a stable path-reference
/// block for regular files and selected non-native image types.
pub fn build_file_attachments_prompt_block(
    attachments: Option<&[ChatAttachment]>,
    attachments_dir: &Path,
    include: ProjectedAttachments,
    include_image: Option<&dyn Fn(&ChatImageAttachment) -> bool>,
) -> Option<String> {
    let mut lines = Vec::new();
    for attachment in attachments.unwrap_or_default() {
        let Some(stored) = is_projected_file_attachment(attachment, include, include_image) else {
            continue;
        };
        let Some(path) = resolve_provider_attachment_path(attachments_dir, stored) else {
            tracing::warn!("[attachments] Skipping unresolved file attachment path for {}.", stored.id());
            continue;
        };
        lines.push(format!(
            "- {} - {} - {} - {}",
            quote_prompt_value(stored.name()),
            stored.mime_type(),
            format_bytes(stored.size_bytes()),
            path.display()
        ));
    }
    if lines.is_empty() {
        return None;
    }
    let mut block = vec![
        "<attached_files>".to_owned(),
        "The user attached the following file(s), saved on disk. Read/extract them with your tools as needed; do not assume their contents.".to_owned(),
    ];
    block.extend(lines);
    block.push("</attached_files>".to_owned());
    Some(block.join("\n"))
}

/// Synara `appendFileAttachmentsPromptBlock` (attachmentProjection.ts:71)
pub fn append_file_attachments_prompt_block(
    text: Option<&str>,
    attachments: Option<&[ChatAttachment]>,
    attachments_dir: &Path,
    include: ProjectedAttachments,
    include_image: Option<&dyn Fn(&ChatImageAttachment) -> bool>,
) -> Option<String> {
    match build_file_attachments_prompt_block(attachments, attachments_dir, include, include_image) {
        Some(block) => {
            let text = text.unwrap_or_default();
            let separator = if text.is_empty() { "" } else { "\n\n" };
            Some(format!("{text}{separator}{block}"))
        }
        None => text.map(str::to_owned),
    }
}

/// Synara `resolveProviderAttachmentPath` (providerAttachmentPaths.ts:64) on the legacy flat
/// layout: `resolveAttachmentPath` (attachmentStore.ts:81).
pub fn resolve_provider_attachment_path(attachments_dir: &Path, attachment: StoredAttachment<'_>) -> Option<PathBuf> {
    resolve_attachment_relative_path(attachments_dir, &attachment_relative_path(attachment))
}

/// Synara `attachmentRelativePath` (attachmentStore.ts:61), image and file kinds.
pub fn attachment_relative_path(attachment: StoredAttachment<'_>) -> String {
    let extension = match attachment {
        StoredAttachment::Image(image) => infer_image_extension(&image.mime_type, &image.name),
        StoredAttachment::File(file) => infer_attachment_extension(&file.mime_type, &file.name),
    };
    format!("{}{}", attachment.id(), extension)
}

/// Synara `resolveAttachmentRelativePath` (attachmentPaths.ts:22): the path under the directory,
/// or `None` when the relative path would leave it.
pub fn resolve_attachment_relative_path(attachments_dir: &Path, relative_path: &str) -> Option<PathBuf> {
    let trimmed = relative_path.trim_start_matches(['/', '\\']).replace('\\', "/");
    if trimmed.is_empty() || trimmed.contains('\0') {
        return None;
    }
    let mut normalized = PathBuf::new();
    for component in Path::new(&trimmed).components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    if normalized.as_os_str().is_empty() {
        return None;
    }
    Some(attachments_dir.join(normalized))
}

/// Synara `ATTACHMENT_ID_PATTERN` (attachmentStore.ts:20), as `parseThreadSegmentFromAttachmentId`
/// applies it: `<thread segment>-<uuid>`, the segment ASCII letters, digits and `_` in runs joined
/// by single `-`, at most 80 characters. Nothing else names an attachment: no `/`, `.` or `\`.
pub fn is_attachment_id(id: &str) -> bool {
    const UUID_LEN: usize = 36;
    if !id.is_ascii() || id.len() < UUID_LEN + 2 {
        return false;
    }
    let (segment, uuid) = id.split_at(id.len() - UUID_LEN);
    let Some(segment) = segment.strip_suffix('-') else { return false };
    let uuid_ok = uuid.char_indices().all(|(i, c)| match i {
        8 | 13 | 18 | 23 => c == '-',
        _ => c.is_ascii_hexdigit(),
    });
    let segment_ok = !segment.is_empty()
        && segment.len() <= 80
        && segment.split('-').all(|run| !run.is_empty() && run.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
    uuid_ok && segment_ok
}

/// Synara `resolveAttachmentPathById` (attachmentStore.ts:96) for the flat layout the app saves
/// into: the regular file `<id><ext>` in `attachments_dir`, whatever extension
/// [`attachment_relative_path`] gave it. `None` for an id that is not one, or no such file.
///
/// Every extension an image can be given, and every one a file gets from its MIME type, is looked
/// up directly; only a file whose extension came from its own name, which can be any, needs the
/// folder listed.
pub fn resolve_attachment_path_by_id(attachments_dir: &Path, id: &str) -> Option<PathBuf> {
    if !is_attachment_id(id) {
        return None;
    }
    let known = SAFE_IMAGE_FILE_EXTENSIONS.iter().copied().chain(KNOWN_MIME_EXTENSIONS.iter().copied()).chain([".bin"]);
    for extension in known {
        let path = attachments_dir.join(format!("{id}{extension}"));
        // A link is not followed: only a file the app wrote is served.
        if std::fs::symlink_metadata(&path).is_ok_and(|meta| meta.file_type().is_file()) {
            return Some(path);
        }
    }
    let entries = std::fs::read_dir(attachments_dir).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(extension) = name.strip_prefix(id).and_then(|rest| rest.strip_prefix('.')) else { continue };
        let valid = (1..=8).contains(&extension.len()) && extension.chars().all(|c| c.is_ascii_alphanumeric());
        // A link is not followed: only a file the app wrote is served.
        if valid && entry.file_type().is_ok_and(|kind| kind.is_file()) {
            return Some(attachments_dir.join(name));
        }
    }
    None
}

/// Synara `IMAGE_EXTENSION_BY_MIME_TYPE` (imageMime.ts:3)
fn image_extension_by_mime_type(mime_type: &str) -> Option<&'static str> {
    Some(match mime_type {
        "image/avif" => ".avif",
        "image/bmp" => ".bmp",
        "image/gif" => ".gif",
        "image/heic" => ".heic",
        "image/heif" => ".heif",
        "image/jpeg" | "image/jpg" => ".jpg",
        "image/png" => ".png",
        "image/svg+xml" => ".svg",
        "image/tiff" => ".tiff",
        "image/webp" => ".webp",
        _ => return None,
    })
}

/// Synara `SAFE_IMAGE_FILE_EXTENSIONS` (imageMime.ts:17)
const SAFE_IMAGE_FILE_EXTENSIONS: &[&str] =
    &[".avif", ".bmp", ".gif", ".heic", ".heif", ".ico", ".jpeg", ".jpg", ".png", ".svg", ".tiff", ".webp"];

/// What [`mime_extension`] answers, as extensions.
const KNOWN_MIME_EXTENSIONS: &[&str] = &[".pdf", ".json", ".zip", ".xml", ".txt", ".md", ".csv", ".html", ".ico"];

/// The few `Mime.getExtension` answers attachments need (Synara asks a full MIME database).
fn mime_extension(mime_type: &str) -> Option<&'static str> {
    Some(match mime_type.to_lowercase().as_str() {
        "application/pdf" => "pdf",
        "application/json" => "json",
        "application/zip" => "zip",
        "application/xml" | "text/xml" => "xml",
        "text/plain" => "txt",
        "text/markdown" => "md",
        "text/csv" => "csv",
        "text/html" => "html",
        "image/x-icon" | "image/vnd.microsoft.icon" => "ico",
        _ => return None,
    })
}

fn file_name_extension(file_name: &str) -> Option<String> {
    let (stem, extension) = file_name.rsplit_once('.')?;
    let valid = !stem.is_empty()
        && (1..=8).contains(&extension.len())
        && extension.chars().all(|c| c.is_ascii_alphanumeric());
    valid.then(|| format!(".{}", extension.to_lowercase()))
}

/// Synara `inferImageExtension` (imageMime.ts:32)
pub fn infer_image_extension(mime_type: &str, file_name: &str) -> String {
    if let Some(extension) = image_extension_by_mime_type(&mime_type.to_lowercase()) {
        return extension.to_owned();
    }
    if let Some(extension) = mime_extension(mime_type).map(|e| format!(".{e}")) {
        if SAFE_IMAGE_FILE_EXTENSIONS.contains(&extension.as_str()) {
            return extension;
        }
    }
    if let Some(extension) = file_name_extension(file_name.trim()) {
        if SAFE_IMAGE_FILE_EXTENSIONS.contains(&extension.as_str()) {
            return extension;
        }
    }
    ".bin".to_owned()
}

/// Synara `inferAttachmentExtension` (imageMime.ts:56)
pub fn infer_attachment_extension(mime_type: &str, file_name: &str) -> String {
    let file_name = file_name.trim();
    if !file_name.is_empty() && !file_name.contains(['/', '\\']) {
        if let Some(extension) = file_name_extension(file_name) {
            return extension;
        }
    }
    if let Some(extension) = mime_extension(mime_type) {
        return format!(".{extension}");
    }
    ".bin".to_owned()
}

/// Synara `formatBytes` (packages/shared/src/formatBytes.ts:11)
pub fn format_bytes(bytes: u64) -> String {
    fn trim_trailing_zero(value: String) -> String {
        value.strip_suffix(".0").map(str::to_owned).unwrap_or(value)
    }
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let kib = bytes as f64 / 1024.0;
    if kib < 1024.0 {
        return format!("{} KB", trim_trailing_zero(format!("{kib:.1}")));
    }
    let mib = kib / 1024.0;
    if mib < 1024.0 {
        return format!("{mib:.1} MB");
    }
    format!("{:.1} GB", mib / 1024.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(id: &str, name: &str, mime: &str, size: u64) -> ChatAttachment {
        ChatAttachment::File(ChatFileAttachment {
            id: id.into(),
            name: name.into(),
            mime_type: mime.into(),
            size_bytes: size,
        })
    }

    #[test]
    fn formats_bytes_as_synara_does() {
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(1024), "1 KB");
        assert_eq!(format_bytes(1536), "1.5 KB");
        assert_eq!(format_bytes(3 * 1024 * 1024), "3.0 MB");
    }

    #[test]
    fn builds_the_attached_files_block() {
        let dir = Path::new("/data/attachments");
        let attachments = vec![
            file("t-1", "notes.md", "text/markdown", 2048),
            file("t-2", "spec.pdf", "application/pdf", 10),
        ];
        let block = build_file_attachments_prompt_block(
            Some(&attachments),
            dir,
            ProjectedAttachments::NonPdfFiles,
            None,
        )
        .unwrap();
        assert_eq!(
            block,
            "<attached_files>\nThe user attached the following file(s), saved on disk. Read/extract them with your tools as needed; do not assume their contents.\n- \"notes.md\" - text/markdown - 2 KB - /data/attachments/t-1.md\n</attached_files>"
        );
        let appended = append_file_attachments_prompt_block(
            Some("Look"),
            Some(&attachments),
            dir,
            ProjectedAttachments::AllFiles,
            None,
        )
        .unwrap();
        assert!(appended.starts_with("Look\n\n<attached_files>"));
        assert!(appended.contains("t-2.pdf"));
    }

    #[test]
    fn refuses_paths_that_leave_the_directory() {
        let dir = Path::new("/data/attachments");
        assert_eq!(resolve_attachment_relative_path(dir, "../etc/passwd"), None);
        assert_eq!(resolve_attachment_relative_path(dir, "a/../b.png"), Some(dir.join("b.png")));
    }

    #[test]
    fn attachment_ids_are_strict() {
        let uuid = "0f8fad5b-d9cb-469f-a165-70867728950e";
        assert!(is_attachment_id(&format!("thread_1-{uuid}")));
        assert!(is_attachment_id(&format!("Thread-1_a-{uuid}")));
        for bad in [
            uuid.to_owned(),
            format!("-{uuid}"),
            format!("a--b-{uuid}"),
            format!("../x-{uuid}"),
            format!("a/b-{uuid}"),
            format!("a.b-{uuid}"),
            format!("a-{uuid}.png"),
            format!("a-{}", uuid.replace('-', "_")),
            "a-not-a-uuid".to_owned(),
            format!("{}-{uuid}", "x".repeat(81)),
        ] {
            assert!(!is_attachment_id(&bad), "{bad}");
        }
    }

    #[test]
    fn resolves_attachments_by_id() {
        let dir = tempfile::tempdir().unwrap();
        let id = "t-0f8fad5b-d9cb-469f-a165-70867728950e";
        std::fs::write(dir.path().join(format!("{id}.png")), b"png").unwrap();
        std::fs::write(dir.path().join("other.txt"), b"x").unwrap();
        assert_eq!(resolve_attachment_path_by_id(dir.path(), id), Some(dir.path().join(format!("{id}.png"))));
        assert_eq!(resolve_attachment_path_by_id(dir.path(), "t-0f8fad5b-d9cb-469f-a165-70867728950f"), None);
        assert_eq!(resolve_attachment_path_by_id(dir.path(), "../other"), None);
        #[cfg(unix)]
        {
            let link = "l-0f8fad5b-d9cb-469f-a165-70867728950e";
            std::os::unix::fs::symlink(dir.path().join("other.txt"), dir.path().join(format!("{link}.txt"))).unwrap();
            assert_eq!(resolve_attachment_path_by_id(dir.path(), link), None);
        }
    }

    /// A known extension is looked up, not listed for: it resolves in a folder that cannot be
    /// listed. A file named with an extension of its own still resolves from the listing.
    #[cfg(unix)]
    #[test]
    fn resolves_known_extensions_without_listing_the_folder() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let image = "t-0f8fad5b-d9cb-469f-a165-70867728950e";
        let text = "t-1f8fad5b-d9cb-469f-a165-70867728950e";
        let other = "t-2f8fad5b-d9cb-469f-a165-70867728950e";
        std::fs::write(dir.path().join(format!("{image}.png")), b"png").unwrap();
        std::fs::write(dir.path().join(format!("{text}.md")), b"md").unwrap();
        std::fs::write(dir.path().join(format!("{other}.swift")), b"swift").unwrap();
        assert_eq!(resolve_attachment_path_by_id(dir.path(), other), Some(dir.path().join(format!("{other}.swift"))));
        // Search, not read: a stat by name works, a listing does not.
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o300)).unwrap();
        assert!(std::fs::read_dir(dir.path()).is_err(), "the folder can still be listed");
        let resolved = (
            resolve_attachment_path_by_id(dir.path(), image),
            resolve_attachment_path_by_id(dir.path(), text),
            resolve_attachment_path_by_id(dir.path(), other),
        );
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(resolved.0, Some(dir.path().join(format!("{image}.png"))));
        assert_eq!(resolved.1, Some(dir.path().join(format!("{text}.md"))));
        assert_eq!(resolved.2, None, "an extension of its own needs the listing");
    }

    #[test]
    fn infers_image_extensions() {
        assert_eq!(infer_image_extension("image/png", "x"), ".png");
        assert_eq!(infer_image_extension("application/octet-stream", "photo.HEIC"), ".heic");
        assert_eq!(infer_image_extension("application/octet-stream", "photo"), ".bin");
    }
}
