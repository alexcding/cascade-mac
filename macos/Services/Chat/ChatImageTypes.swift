import Foundation

/// The images a chat sends as images: the types every agent takes as they are (Claude's
/// `SUPPORTED_CLAUDE_IMAGE_MIME_TYPES`, `crates/cascade-chat/src/provider/claude/adapter.rs`).
/// Any other file, an image of another type included, is sent by its path or converted first.
enum ChatImageTypes {
    static let sent: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
}
