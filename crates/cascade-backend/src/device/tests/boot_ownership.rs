//! Which simulators Cascade booted, remembered across process death.
//!
//! Ported from `apps/server/src/device/bootOwnership.test.ts`.

use crate::device::boot_ownership::{
    orphaned_boot_udids, process_is_alive, BootOwnershipRecord, BootOwnershipStore,
};

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

fn record(pid: u32, udids: &[&str]) -> BootOwnershipRecord {
    BootOwnershipRecord { pid, udids: strings(udids) }
}

// the boot ownership record

#[test]
fn the_record_survives_the_process_that_wrote_it() {
    // The whole point: a crash runs no finalizer, so the only way the next run can know which
    // simulators were ours is to have written it down.
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("ownership.json");
    BootOwnershipStore::new(&file, 4242).write(&strings(&["A", "B"]));

    let read = BootOwnershipStore::new(&file, 9999).read();

    assert_eq!(read, Some(record(4242, &["A", "B"])));
}

#[test]
fn reads_as_owning_nothing_when_the_file_is_absent_or_corrupt() {
    // Shutting down a device we cannot prove is ours is worse than leaking one, so every
    // unreadable state degrades to "own nothing".
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("ownership.json");
    assert_eq!(BootOwnershipStore::new(&file, 1).read(), None);

    let corrupt = dir.path().join("corrupt.json");
    std::fs::write(&corrupt, "{ not json").unwrap();
    assert_eq!(BootOwnershipStore::new(&corrupt, 1).read(), None);

    let wrong_version = dir.path().join("v2.json");
    std::fs::write(&wrong_version, r#"{"version":2,"udids":["A"]}"#).unwrap();
    assert_eq!(BootOwnershipStore::new(&wrong_version, 1).read(), None);
}

#[test]
fn clears_to_an_empty_list_rather_than_deleting_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("ownership.json");
    let owned = BootOwnershipStore::new(&file, 7);
    owned.write(&strings(&["A"]));
    owned.clear();

    assert_eq!(owned.read().map(|read| read.udids), Some(Vec::new()));
    // Still valid JSON, so the next read is a clean empty rather than a parse failure that looks
    // identical to corruption.
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(json["version"], 1);
    assert_eq!(json["udids"], serde_json::json!([]));
}

#[test]
fn writes_into_a_folder_that_does_not_exist_yet_and_leaves_no_temporary_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("device/boot-ownership.json");

    BootOwnershipStore::new(&file, 3).write(&strings(&["A"]));

    assert_eq!(BootOwnershipStore::new(&file, 4).read(), Some(record(3, &["A"])));
    let names: Vec<_> = std::fs::read_dir(file.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["boot-ownership.json".to_owned()]);
}

#[test]
fn a_store_without_a_file_remembers_nothing() {
    let store = BootOwnershipStore::null();
    store.write(&strings(&["A"]));
    assert_eq!(store.read(), None);
}

// deciding which boots to reclaim

#[test]
fn reclaims_devices_a_dead_process_left_booted() {
    assert_eq!(
        orphaned_boot_udids(Some(&record(123, &["A", "B"])), &strings(&["A", "B"]), |_| false),
        strings(&["A", "B"])
    );
}

#[test]
fn leaves_a_live_sibling_servers_devices_alone() {
    // Two Cascade processes can run at once; the older record belongs to the one still running,
    // and shutting its simulators down would be a bug.
    assert_eq!(
        orphaned_boot_udids(Some(&record(123, &["A"])), &strings(&["A"]), |_| true),
        Vec::<String>::new()
    );
}

#[test]
fn never_reclaims_a_device_the_user_booted_themselves() {
    // The safety property that matters most: only udids we recorded are candidates, so anything
    // else running stays running.
    assert_eq!(
        orphaned_boot_udids(Some(&record(9, &["OURS"])), &strings(&["OURS", "THEIRS"]), |_| false),
        strings(&["OURS"])
    );
}

#[test]
fn ignores_recorded_devices_that_are_already_shut_down() {
    assert_eq!(
        orphaned_boot_udids(Some(&record(9, &["A"])), &[], |_| false),
        Vec::<String>::new()
    );
}

#[test]
fn does_nothing_without_a_record() {
    assert_eq!(orphaned_boot_udids(None, &strings(&["A"]), |_| false), Vec::<String>::new());
    assert_eq!(
        orphaned_boot_udids(Some(&record(9, &[])), &strings(&["A"]), |_| false),
        Vec::<String>::new()
    );
}

// processIsAlive

#[test]
fn recognises_this_very_process() {
    assert!(process_is_alive(std::process::id()));
}

#[test]
fn reports_a_pid_that_cannot_exist_as_dead() {
    // Above the usual pid_max, so it is safe to assume nothing owns it.
    assert!(!process_is_alive(0x7fff_ffff));
    assert!(!process_is_alive(0));
}
