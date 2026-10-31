//! The helper's cache key and cache location.
//!
//! Ported from `packages/shared/src/deviceHelperCache.test.ts` and the path part of
//! `apps/server/src/device/helperCachePath.test.ts`. The build-directory test there drives
//! `IosSimulatorBackend.compileHelperIfNeeded`, which `tests/ios_simulator.rs` covers.

use std::path::{Path, PathBuf};

use crate::device::cache::{
    device_helper_cache_key, device_helper_cache_root, device_helper_source_revision, key_directory,
    materialize_sources, vendored_source_revision, DEVICE_HELPER_BINARY_NAME, DEVICE_HELPER_CACHE_ENV,
    VENDORED_FILES,
};

const XCODEBUILD_OUTPUT: &str = "Xcode 26.2\nBuild version 17C52";

fn file(name: &str, contents: &str) -> (String, String) {
    (name.to_owned(), contents.to_owned())
}

#[test]
fn combines_the_marketing_version_and_the_build_number() {
    assert_eq!(device_helper_cache_key(XCODEBUILD_OUTPUT, None).as_deref(), Some("26.2-17C52"));
}

#[test]
fn tolerates_surrounding_whitespace_and_trailing_newlines() {
    assert_eq!(
        device_helper_cache_key("  Xcode 26.2  \n  Build version 17C52  \n", None).as_deref(),
        Some("26.2-17C52")
    );
}

#[test]
fn changes_when_the_toolchain_changes() {
    // The whole point of the key: a helper built against one Xcode must never be reused after an
    // upgrade, because it links private frameworks.
    let first = device_helper_cache_key(XCODEBUILD_OUTPUT, None);
    assert_ne!(device_helper_cache_key("Xcode 26.3\nBuild version 17D10", None), first);
    assert_ne!(device_helper_cache_key("Xcode 26.2\nBuild version 17C60", None), first);
}

#[test]
fn still_produces_a_key_when_only_one_field_is_recognizable() {
    assert_eq!(device_helper_cache_key("Xcode 26.2", None).as_deref(), Some("26.2-unknown"));
    assert_eq!(device_helper_cache_key("Build version 17C52", None).as_deref(), Some("unknown-17C52"));
}

#[test]
fn returns_none_rather_than_caching_under_a_garbage_key() {
    assert_eq!(device_helper_cache_key("", None), None);
    assert_eq!(
        device_helper_cache_key("xcode-select: error: tool 'xcodebuild' requires Xcode", None),
        None
    );
}

#[test]
fn changes_when_the_helpers_own_sources_change() {
    // Without this the cache never invalidates on a helper fix: the toolchain is identical, so
    // every existing user keeps running the binary they already built and the fix silently never
    // reaches them.
    let before = device_helper_source_revision(&[file("HIDBridge.m", "volume = 0x2;")]);
    let after = device_helper_source_revision(&[file("HIDBridge.m", "volume = 0xe9;")]);
    assert_ne!(after, before);
    assert_ne!(
        device_helper_cache_key(XCODEBUILD_OUTPUT, Some(&after)),
        device_helper_cache_key(XCODEBUILD_OUTPUT, Some(&before))
    );
    assert_eq!(
        device_helper_cache_key(XCODEBUILD_OUTPUT, Some(&after)),
        Some(format!("26.2-17C52-{after}"))
    );
}

#[test]
fn treats_a_rename_as_a_change_and_file_order_as_irrelevant() {
    let a = vec![file("A.swift", "x"), file("B.swift", "y")];
    // Same tree, listed the other way round: readdir order must not shift the key.
    let reversed: Vec<_> = a.iter().rev().cloned().collect();
    assert_eq!(device_helper_source_revision(&reversed), device_helper_source_revision(&a));
    // A rename with identical contents is still a different build.
    assert_ne!(
        device_helper_source_revision(&[file("A.swift", "x"), file("Renamed.swift", "y")]),
        device_helper_source_revision(&a)
    );
}

#[test]
fn digests_the_sources_as_synaras_javascript_does() {
    // Values computed with Synara's `deviceHelperSourceRevision`, so the same tree gives the
    // same key in both implementations: FNV-1a over UTF-16 code units.
    assert_eq!(
        device_helper_source_revision(&[file("A.swift", "x"), file("B.swift", "y")]),
        "cf2185d5"
    );
    assert_eq!(device_helper_source_revision(&[]), "811c9dc5");
    assert_eq!(device_helper_source_revision(&[file("é.swift", "日本")]), "f7a43c22");
}

#[test]
fn keys_on_the_toolchain_alone_when_the_sources_cannot_be_read() {
    // Falling back beats failing the attach outright.
    assert_eq!(device_helper_cache_key(XCODEBUILD_OUTPUT, None).as_deref(), Some("26.2-17C52"));
    assert_eq!(device_helper_cache_key(XCODEBUILD_OUTPUT, Some("")).as_deref(), Some("26.2-17C52"));
}

#[test]
fn pins_the_cache_location_and_binary_name() {
    // The helper's binary keeps Synara's name; the cache root is Cascade's own. Setting the
    // override would mean mutating the process environment, so the default is checked only when
    // no override is set.
    assert_eq!(DEVICE_HELPER_CACHE_ENV, "CASCADE_DEVICE_HELPER_CACHE");
    assert_eq!(DEVICE_HELPER_BINARY_NAME, "synara-device-helper");
    match std::env::var_os(DEVICE_HELPER_CACHE_ENV).filter(|root| !root.is_empty()) {
        Some(root) => assert_eq!(device_helper_cache_root(), PathBuf::from(root)),
        None => {
            let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
            assert_eq!(device_helper_cache_root(), home.join("Library/Caches/Cascade/device-helper"));
        }
    }
}

#[test]
fn builds_into_the_directory_the_shared_key_names() {
    let root = Path::new("/tmp/cascade-helper-cache");
    let key = device_helper_cache_key(XCODEBUILD_OUTPUT, None).unwrap();
    assert_eq!(key_directory(root, &key), root.join("26.2-17C52"));
}

#[test]
fn the_vendored_sources_have_a_stable_eight_digit_revision() {
    let revision = vendored_source_revision();
    assert_eq!(revision.len(), 8);
    assert!(revision.chars().all(|character| character.is_ascii_hexdigit()));
    assert_eq!(revision, vendored_source_revision());
}

#[test]
fn writes_the_vendored_sources_and_rewrites_only_what_differs() {
    let directory = tempfile::tempdir().unwrap();

    assert_eq!(materialize_sources(directory.path()).unwrap(), directory.path());
    for (path, bytes) in VENDORED_FILES {
        assert_eq!(&std::fs::read(directory.path().join(path)).unwrap(), bytes, "{path}");
    }
    // No temporary name is left behind.
    let leftovers = std::fs::read_dir(directory.path().join("Sources"))
        .unwrap()
        .filter(|entry| entry.as_ref().unwrap().file_name().to_string_lossy().ends_with(".tmp"))
        .count();
    assert_eq!(leftovers, 0);

    // A file edited in place is put back; one that matches is left alone.
    let edited = directory.path().join("build.sh");
    std::fs::write(&edited, b"tampered").unwrap();
    materialize_sources(directory.path()).unwrap();
    let (_, original) = VENDORED_FILES.iter().find(|(path, _)| *path == "build.sh").unwrap();
    assert_eq!(&std::fs::read(&edited).unwrap(), original);
}
