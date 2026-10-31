//! The vendored helper is Synara's, byte for byte, and what the crate embeds is what is vendored.

use std::{collections::BTreeMap, path::Path};

use sha2::{Digest, Sha256};

use crate::device::cache::{materialize_sources, vendored_source_revision, VENDORED_FILES};

fn vendor_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor/synara-device-helper")
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn files_on_disk(root: &Path, folder: &Path, found: &mut Vec<String>) {
    for entry in std::fs::read_dir(folder).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files_on_disk(root, &path, found);
        } else {
            found.push(path.strip_prefix(root).unwrap().to_string_lossy().into_owned());
        }
    }
}

#[test]
fn vendored_files_match_their_manifest() {
    let manifest: serde_json::Value =
        serde_json::from_slice(&std::fs::read(vendor_dir().join("MANIFEST.json")).unwrap()).unwrap();
    assert_eq!(manifest["commit"], "566efb1b132b97a1d76e86229be8a177abb9e435");
    let listed: BTreeMap<String, String> = manifest["files"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(path, hash)| (path.clone(), hash.as_str().unwrap().to_owned()))
        .collect();

    let mut on_disk = Vec::new();
    files_on_disk(&vendor_dir(), &vendor_dir(), &mut on_disk);
    on_disk.retain(|path| path != "MANIFEST.json");
    on_disk.sort();
    assert_eq!(on_disk, listed.keys().cloned().collect::<Vec<_>>(), "the folder and MANIFEST.json list different files");

    for (path, hash) in &listed {
        let bytes = std::fs::read(vendor_dir().join(path)).unwrap();
        assert_eq!(&sha256(&bytes), hash, "{path} differs from the vendored Synara file");
    }
}

#[test]
fn the_crate_embeds_every_vendored_file_as_it_is_on_disk() {
    let mut on_disk = Vec::new();
    files_on_disk(&vendor_dir(), &vendor_dir(), &mut on_disk);
    on_disk.sort();
    let mut embedded: Vec<String> = VENDORED_FILES.iter().map(|(path, _)| path.to_string()).collect();
    embedded.sort();
    assert_eq!(embedded, on_disk);
    for (path, bytes) in VENDORED_FILES {
        assert_eq!(*bytes, std::fs::read(vendor_dir().join(path)).unwrap().as_slice(), "{path}");
    }
}

#[test]
fn the_source_revision_is_the_one_synara_computes_for_this_tree() {
    // Synara's `readDeviceHelperSourceRevision` over the same `Sources/` and `build.sh`, run with
    // Node at the vendored commit; a changed tree changes the cache key, which is the point.
    assert_eq!(vendored_source_revision(), "88efa594");
}

#[test]
fn materializing_writes_the_tree_and_repairs_what_changed() {
    let folder = tempfile::tempdir().unwrap();
    let source = materialize_sources(folder.path()).unwrap();
    for (path, bytes) in VENDORED_FILES {
        assert_eq!(std::fs::read(source.join(path)).unwrap(), *bytes);
    }
    std::fs::write(source.join("device-helper.sb"), b"(version 1) (allow default)").unwrap();
    std::fs::remove_file(source.join("Sources/main.swift")).unwrap();
    materialize_sources(folder.path()).unwrap();
    for (path, bytes) in VENDORED_FILES {
        assert_eq!(std::fs::read(source.join(path)).unwrap(), *bytes, "{path}");
    }
}
