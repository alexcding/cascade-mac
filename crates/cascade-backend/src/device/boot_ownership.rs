//! Which simulators Cascade booted, remembered across process death.
//!
//! Port of Synara's `apps/server/src/device/bootOwnership.ts`. The manager tracks this in memory,
//! which is enough for a clean quit; a crash or a SIGKILL runs no finalizer, and the orphan then
//! reappears as booted by the user, outside the boot cap, the idle sweep and the next quit's
//! shutdown. So the set is also written to a small JSON file, read once at startup.
//!
//! A corrupt or missing file degrades to "own nothing" rather than failing a boot, and recovery
//! is conservative: a device is reclaimed only when it is still booted and was recorded by a
//! process that is gone, so a udid the user has since booted themselves is never shut down.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The file, under the data folder.
pub const BOOT_OWNERSHIP_FILE: &str = "device/boot-ownership.json";

/// What the file says: who wrote it, and which devices it booted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BootOwnershipRecord {
    pub pid: u32,
    pub udids: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct BootOwnershipFile {
    version: u32,
    pid: u32,
    udids: Vec<String>,
}

/// The record's file, written atomically so a crash mid-write cannot leave it half written.
#[derive(Clone, Debug)]
pub struct BootOwnershipStore {
    file: Option<PathBuf>,
    process_id: u32,
}

impl BootOwnershipStore {
    pub fn new(file: impl Into<PathBuf>, process_id: u32) -> Self {
        Self { file: Some(file.into()), process_id }
    }

    /// The store in Cascade's data folder, written as this process.
    pub fn in_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join(BOOT_OWNERSHIP_FILE), std::process::id())
    }

    /// A store that remembers nothing, for tests and unsupported platforms.
    pub fn null() -> Self {
        Self { file: None, process_id: std::process::id() }
    }

    /// The record, or none when there is no file or it cannot be read: unparsable means
    /// ownership cannot be proved, and shutting down a device we do not own is worse than
    /// leaking one.
    pub fn read(&self) -> Option<BootOwnershipRecord> {
        let raw = std::fs::read_to_string(self.file.as_ref()?).ok()?;
        let parsed: Value = serde_json::from_str(&raw).ok()?;
        if parsed.get("version").and_then(Value::as_f64) != Some(1.0) {
            return None;
        }
        let udids = parsed.get("udids")?.as_array()?.iter().filter_map(Value::as_str).map(str::to_owned).collect();
        let pid = parsed.get("pid").and_then(Value::as_u64).and_then(|pid| u32::try_from(pid).ok()).unwrap_or(0);
        Some(BootOwnershipRecord { pid, udids })
    }

    /// Records `udids` as this process's. Best effort: a failed write costs the recovery, not the
    /// boot.
    pub fn write(&self, udids: &[String]) {
        let _ = self.write_atomically(udids);
    }

    /// Records that this process owns nothing, keeping the file rather than deleting it.
    pub fn clear(&self) {
        let _ = self.write_atomically(&[]);
    }

    fn write_atomically(&self, udids: &[String]) -> std::io::Result<()> {
        let Some(file) = &self.file else { return Ok(()) };
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let contents = serde_json::to_string(&BootOwnershipFile { version: 1, pid: self.process_id, udids: udids.to_vec() })?;
        let mut temporary = file.clone().into_os_string();
        temporary.push(format!(".{}.tmp", self.process_id));
        std::fs::write(&temporary, contents)?;
        // Rename is atomic within a filesystem: a reader sees the old file or the new one.
        std::fs::rename(&temporary, file)
    }
}

/// Which recorded udids to shut down at startup: those still booted, recorded by a process that
/// is no longer running. A record left by a live sibling belongs to it.
pub fn orphaned_boot_udids(
    recorded: Option<&BootOwnershipRecord>,
    booted_udids: &[String],
    is_process_alive: impl Fn(u32) -> bool,
) -> Vec<String> {
    let Some(recorded) = recorded.filter(|recorded| !recorded.udids.is_empty()) else {
        return Vec::new();
    };
    if recorded.pid > 0 && is_process_alive(recorded.pid) {
        return Vec::new();
    }
    recorded.udids.iter().filter(|udid| booted_udids.contains(udid)).cloned().collect()
}

/// Whether a pid is still running: signal 0 checks without delivering, and EPERM means it exists
/// but belongs to someone else, which still counts.
pub fn process_is_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 delivers nothing; it only asks whether the process exists.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}
