//! Where the device helper is built, and from what.
//!
//! Port of Synara's `packages/shared/src/deviceHelperCache.ts`, plus what replaces its
//! source-directory lookup (`resolveDeviceHelperSourceDir` in `IosSimulatorBackend.ts`): the
//! helper's sources are vendored verbatim under `vendor/synara-device-helper` and compiled into
//! this crate, and written out next to the binary they build, so no app-bundle resource has to
//! be found at runtime.
//!
//! The helper links private CoreSimulator/SimulatorKit frameworks whose symbols move between
//! Xcode releases, so a binary is only valid for the toolchain that produced it, and the cache is
//! keyed on that toolchain and on the helper's own sources:
//! `<root>/<xcode version>-<build>-<fnv1a32 of Sources/* and build.sh>/`.

use std::{
    io,
    path::{Path, PathBuf},
};

/// Overrides the cache root, for tests and for a development build that wants its own.
pub const DEVICE_HELPER_CACHE_ENV: &str = "CASCADE_DEVICE_HELPER_CACHE";

/// The binary `build.sh` writes; the name is the helper's own.
pub const DEVICE_HELPER_BINARY_NAME: &str = "synara-device-helper";

/// Where, inside a key's folder, the sources the binary was built from are written.
pub const DEVICE_HELPER_SOURCE_FOLDER: &str = "source";

macro_rules! vendored {
    ($($path:literal),* $(,)?) => {
        &[$(($path, include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/vendor/synara-device-helper/", $path)) as &[u8])),*]
    };
}

/// The vendored helper, path relative to its folder and bytes, exactly as Synara ships it.
/// `tests::vendored_files_match_their_manifest` keeps this list and the folder in step.
pub const VENDORED_FILES: &[(&str, &[u8])] = vendored![
    "HEADER.md",
    "LICENSE",
    "MANIFEST.json",
    "Sources/AXBridge.h",
    "Sources/AXBridge.m",
    "Sources/CapabilityProbe.swift",
    "Sources/CoreSimulatorBridge.swift",
    "Sources/DTUHIDTransport.h",
    "Sources/DTUHIDTransport.m",
    "Sources/DeviceHelper-Bridging-Header.h",
    "Sources/FrameStream.swift",
    "Sources/HIDBridge.h",
    "Sources/HIDBridge.m",
    "Sources/Screenshot.swift",
    "Sources/SymbolManifest.swift",
    "Sources/main.swift",
    "Tests/InputDeliveryTests.m",
    "build.sh",
    "device-helper.sb",
];

/// `~/Library/Caches/Cascade/device-helper`, unless `CASCADE_DEVICE_HELPER_CACHE` names another.
pub fn device_helper_cache_root() -> PathBuf {
    if let Some(root) = std::env::var_os(DEVICE_HELPER_CACHE_ENV).filter(|root| !root.is_empty()) {
        return PathBuf::from(root);
    }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    home.join("Library/Caches/Cascade/device-helper")
}

/// The cache key from `xcodebuild -version` output (`Xcode 26.2\nBuild version 17C52`), with the
/// sources' digest appended. None when the output is unrecognizable, so a caller reports a setup
/// problem rather than caching under a garbage key.
pub fn device_helper_cache_key(xcodebuild_version_output: &str, source_revision: Option<&str>) -> Option<String> {
    let version = regex::Regex::new(r"Xcode\s+([\d.]+)")
        .expect("valid pattern")
        .captures(xcodebuild_version_output)
        .map(|captures| captures[1].to_owned());
    let build = regex::Regex::new(r"Build version\s+(\S+)")
        .expect("valid pattern")
        .captures(xcodebuild_version_output)
        .map(|captures| captures[1].to_owned());
    if version.is_none() && build.is_none() {
        return None;
    }
    let toolchain = format!(
        "{}-{}",
        version.as_deref().unwrap_or("unknown"),
        build.as_deref().unwrap_or("unknown")
    );
    Some(match source_revision.filter(|revision| !revision.is_empty()) {
        Some(revision) => format!("{toolchain}-{revision}"),
        None => toolchain,
    })
}

/// A short digest of the helper's sources: FNV-1a, 32-bit, over `name\0contents` joined by `\0`,
/// sorted by name, and taken over UTF-16 code units as Synara's JavaScript takes it, so the same
/// tree gives the same key in both.
pub fn device_helper_source_revision(files: &[(String, String)]) -> String {
    let mut files: Vec<&(String, String)> = files.iter().collect();
    files.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
    let canonical = files
        .iter()
        .map(|(name, contents)| format!("{name}\0{contents}"))
        .collect::<Vec<_>>()
        .join("\0");
    let mut hash: u32 = 0x811c_9dc5;
    for unit in canonical.encode_utf16() {
        hash ^= u32::from(unit);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

/// The digest of the vendored sources: every file directly in `Sources/`, and `build.sh`, which
/// drives the compile.
pub fn vendored_source_revision() -> String {
    let files: Vec<(String, String)> = VENDORED_FILES
        .iter()
        .filter_map(|(path, bytes)| {
            let name = match path.strip_prefix("Sources/") {
                Some(name) if !name.contains('/') => name,
                _ if *path == "build.sh" => path,
                _ => return None,
            };
            Some((name.to_owned(), String::from_utf8_lossy(bytes).into_owned()))
        })
        .collect();
    device_helper_source_revision(&files)
}

/// The folder a key's binary and sources live in.
pub fn key_directory(root: &Path, key: &str) -> PathBuf {
    root.join(key)
}

/// Writes the vendored sources into `directory` wherever a file is missing or differs, and
/// returns it. Each file goes through a temporary name and a rename, so a build or a sandboxed
/// helper reading one never sees it half written.
pub fn materialize_sources(directory: &Path) -> io::Result<PathBuf> {
    for (path, bytes) in VENDORED_FILES {
        let target = directory.join(path);
        if std::fs::read(&target).is_ok_and(|existing| existing == *bytes) {
            continue;
        }
        let parent = target.parent().expect("a vendored file has a folder");
        std::fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(
            ".{}.{}.tmp",
            target.file_name().and_then(|name| name.to_str()).unwrap_or("file"),
            std::process::id()
        ));
        std::fs::write(&temporary, bytes)?;
        std::fs::rename(&temporary, &target)?;
    }
    Ok(directory.to_path_buf())
}

/// `materialize_sources` off the runtime's workers: it compares and may write the whole tree.
pub async fn materialize_sources_blocking(directory: PathBuf) -> io::Result<PathBuf> {
    tokio::task::spawn_blocking(move || materialize_sources(&directory))
        .await
        .unwrap_or_else(|error| Err(io::Error::other(error)))
}
