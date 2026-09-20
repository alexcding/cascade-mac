//! Standalone snapshots: never open application stores or run schema migrations.
//! Format 1 remains readable by the previous Node recovery utility.
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use rusqlite::{
    backup::{Backup, StepResult},
    Connection, OpenFlags,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const MAX_JSON: u64 = 16 * 1024 * 1024;
const PAGE_CACHE: &str = "ptyd-native-spike/page-tabs.json";

#[derive(Serialize, Deserialize)]
pub struct Manifest {
    format: u32,
    #[serde(rename = "createdAt")]
    created_at: String,
    files: Vec<Entry>,
}

#[derive(Serialize, Deserialize)]
struct Entry {
    path: String,
    kind: String,
    size: u64,
    sha256: String,
}

/// The durable database under every name it has had, newest first. Older data directories and
/// older backups still carry the earlier names; `Database::open` renames the file it finds.
pub(crate) const DURABLE_NAMES: [&str; 3] = ["craft.db", "taskhub.db", "config.db"];

fn kind(name: &str) -> Option<&'static str> {
    match name {
        name if DURABLE_NAMES.contains(&name) => Some("sqlite"),
        "logs.db" => Some("sqlite"),
        PAGE_CACHE => Some("json"),
        _ => None,
    }
}

fn directory(path: &Path) -> Result<PathBuf> {
    let root = fs::canonicalize(path)?;
    ensure!(
        root.is_dir(),
        "Expected an existing directory: {}",
        path.display()
    );
    Ok(root)
}

// Names come from a fixed allowlist, including every component of nested paths.
fn regular_file(root: &Path, name: &str) -> Result<Option<PathBuf>> {
    let mut path = root.to_path_buf();
    let parts: Vec<_> = name.split('/').collect();
    for (index, part) in parts.iter().enumerate() {
        path.push(part);
        let metadata = match fs::symlink_metadata(&path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        ensure!(
            if index + 1 == parts.len() {
                metadata.is_file()
            } else {
                metadata.is_dir()
            },
            "Expected a regular file without symlinks: {}",
            path.display()
        );
    }
    Ok(Some(path))
}

fn required_file(root: &Path, name: &str) -> Result<PathBuf> {
    regular_file(root, name)?.with_context(|| format!("Missing snapshot file: {name}"))
}

fn open_read(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    ensure!(
        file.metadata()?.is_file(),
        "Expected a regular file: {}",
        path.display()
    );
    Ok(file)
}

fn new_file(path: &Path) -> Result<File> {
    Ok(OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?)
}

fn read_json(path: &Path, limit: u64) -> Result<(Vec<u8>, Value)> {
    let file = open_read(path)?;
    ensure!(
        file.metadata()?.len() <= limit,
        "JSON file exceeds size limit"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "JSON file exceeds size limit");
    let value = serde_json::from_slice(&bytes)?;
    Ok((bytes, value))
}

fn digest(path: &Path) -> Result<(u64, String)> {
    let mut file = open_read(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    let mut size = 0;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
        size += count as u64;
    }
    Ok((size, format!("{:x}", hash.finalize())))
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = new_file(path)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn new_directory(path: &Path) -> Result<PathBuf> {
    // Existing destinations, including empty directories and symlinks, are refused.
    fs::DirBuilder::new().mode(0o700).create(path)?;
    directory(path)
}

fn sqlite_sidecars(path: &Path, forbidden: bool) -> Result<()> {
    let parent = path.parent().context("Missing database parent")?;
    let name = path
        .file_name()
        .context("Missing database name")?
        .to_string_lossy();
    for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = regular_file(parent, &format!("{name}{suffix}"))?;
        ensure!(
            !forbidden || sidecar.is_none(),
            "Snapshot database depends on a SQLite sidecar"
        );
    }
    Ok(())
}

fn check_database(path: &Path) -> Result<()> {
    sqlite_sidecars(path, true)?;
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    let mut statement = db.prepare("PRAGMA quick_check")?;
    let checks = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    ensure!(
        checks == ["ok"],
        "SQLite integrity check failed: {}",
        path.display()
    );
    Ok(())
}

fn snapshot_database(source: &Path, destination: &Path) -> Result<()> {
    sqlite_sidecars(source, false)?;
    let db = Connection::open_with_flags(
        source,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    db.busy_timeout(Duration::from_secs(5))?;
    // Pin a committed WAL read view before copying; writers cannot restart the copy.
    db.execute_batch("BEGIN; SELECT count(*) FROM sqlite_schema;")?;
    new_file(destination)?;
    let mut output = Connection::open_with_flags(
        destination,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    {
        let backup = Backup::new(&db, &mut output)?;
        let deadline = Instant::now() + Duration::from_secs(90);
        loop {
            ensure!(Instant::now() < deadline, "SQLite backup timed out");
            match backup.step(256)? {
                StepResult::Done => break,
                StepResult::More => {}
                StepResult::Busy | StepResult::Locked => {
                    std::thread::sleep(Duration::from_millis(25))
                }
                _ => bail!("Unexpected SQLite backup result"),
            }
        }
    }
    db.execute_batch("ROLLBACK")?;
    output.execute_batch("PRAGMA journal_mode=DELETE;")?;
    drop(output);
    check_database(destination)?;
    open_read(destination)?.sync_all()?;
    Ok(())
}

pub fn backup(source: &Path, destination: &Path) -> Result<Manifest> {
    let source = directory(source)?;
    let mut primary = None;
    for name in DURABLE_NAMES {
        if regular_file(&source, name)?.is_some() {
            primary = Some(name);
            break;
        }
    }
    let Some(primary) = primary else {
        bail!("No durable craft.db or legacy taskhub.db or config.db was found")
    };
    let mut inputs = Vec::new();
    for name in [primary, "logs.db", PAGE_CACHE] {
        if let Some(path) = regular_file(&source, name)? {
            inputs.push((name, path));
        }
    }
    let target = new_directory(destination)?;
    let mut files = Vec::new();
    for (name, input) in inputs {
        let output = target.join(name);
        if name.contains('/') {
            new_directory(output.parent().unwrap())?;
        }
        let kind = kind(name).unwrap();
        if kind == "sqlite" {
            snapshot_database(&input, &output)?;
        } else {
            let (bytes, _) = read_json(&input, MAX_JSON)?;
            let mut file = new_file(&output)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        sync_directory(output.parent().unwrap())?;
        let (size, sha256) = digest(&output)?;
        files.push(Entry {
            path: name.into(),
            kind: kind.into(),
            size,
            sha256,
        });
    }
    let manifest = Manifest {
        format: 1,
        created_at: Utc::now().to_rfc3339(),
        files,
    };
    write_json(&target.join("manifest.json"), &manifest)?;
    sync_directory(&target)?;
    sync_directory(target.parent().unwrap())?;
    Ok(manifest)
}

fn check_entry(root: &Path, entry: &Entry) -> Result<PathBuf> {
    let path = required_file(root, &entry.path)?;
    ensure!(
        digest(&path)? == (entry.size, entry.sha256.clone()),
        "Snapshot checksum mismatch: {}",
        entry.path
    );
    if entry.kind == "sqlite" {
        check_database(&path)?;
    } else {
        read_json(&path, MAX_JSON)?;
    }
    Ok(path)
}

pub fn verify(source: &Path) -> Result<Manifest> {
    let root = directory(source)?;
    let (_, value) = read_json(&required_file(&root, "manifest.json")?, 64 * 1024)?;
    let manifest: Manifest = serde_json::from_value(value)?;
    ensure!(
        manifest.format == 1 && (1..=3).contains(&manifest.files.len()),
        "Unsupported or incomplete snapshot manifest"
    );
    let mut seen = HashSet::new();
    for entry in &manifest.files {
        ensure!(
            kind(&entry.path) == Some(entry.kind.as_str())
                && seen.insert(entry.path.as_str())
                && valid_hash(&entry.sha256),
            "Invalid snapshot file entry"
        );
        check_entry(&root, entry)?;
    }
    ensure!(
        DURABLE_NAMES.iter().filter(|name| seen.contains(**name)).count() == 1,
        "Snapshot must contain exactly one durable database"
    );
    Ok(manifest)
}

pub fn restore(source: &Path, destination: &Path) -> Result<Manifest> {
    let source = directory(source)?;
    let manifest = verify(&source)?;
    let target = new_directory(destination)?;
    for entry in &manifest.files {
        let input = required_file(&source, &entry.path)?;
        let output = target.join(&entry.path);
        if entry.path.contains('/') {
            new_directory(output.parent().unwrap())?;
        }
        let mut file = new_file(&output)?;
        std::io::copy(&mut open_read(&input)?, &mut file)?;
        file.sync_all()?;
        check_entry(&target, entry)?;
        sync_directory(output.parent().unwrap())?;
    }
    write_json(&target.join("restore-manifest.json"), &manifest)?;
    sync_directory(&target)?;
    sync_directory(target.parent().unwrap())?;
    Ok(manifest)
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

// An unchanged OS-locked inode coordinates with older packaged Node backends too.
// Keep this connection alive until the backend has completely stopped.
pub struct NativeLease {
    _connection: Connection,
}

pub fn prepare_packaged(data: &Path) -> Result<NativeLease> {
    let data = directory(data)?;
    let root = data.join("native-backups");
    match fs::DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(&root)?;
    ensure!(
        metadata.is_dir()
            && metadata.mode() & 0o077 == 0
            && metadata.uid() == unsafe { libc::getuid() },
        "Native checkpoint directory must be private, owned by this user, and not a symlink"
    );
    sync_directory(&data)?;
    let owner = root.join("owner.db");
    for suffix in ["", "-wal", "-shm", "-journal"] {
        regular_file(&root, &format!("owner.db{suffix}"))?;
    }
    if regular_file(&root, "owner.db")?.is_none() {
        match new_file(&owner) {
            Ok(_) => {}
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                required_file(&root, "owner.db")?;
            }
            Err(error) => return Err(error),
        }
    }
    let connection = Connection::open_with_flags(
        &owner,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    connection.execute_batch("PRAGMA busy_timeout=0; BEGIN EXCLUSIVE;")
        .context("Another native backend may be using this data directory; checkpoint ownership could not be acquired")?;
    let lease = NativeLease {
        _connection: connection,
    };
    let release_id = release_identity()?;
    let previous = match regular_file(&root, "last-launch.json")? {
        Some(path) => Some(read_json(&path, 64 * 1024)?.1),
        None => None,
    };
    if let Some(previous) = &previous {
        ensure!(previous["format"] == 1 && previous["releaseID"].as_str().is_some_and(valid_hash)
            && previous.get("snapshot").is_some_and(|v| v.is_null() || v.as_str().is_some_and(|v|
                v.strip_prefix("checkpoint-").is_some_and(|id| id.len() == 36 && Uuid::parse_str(id).is_ok()))),
            "Invalid native checkpoint state; preserve native-backups and inspect it before retrying");
        // Verify before every transition as well as repeat launch. Never hide damage.
        if let Some(snapshot) = previous["snapshot"].as_str() {
            let path = root.join(snapshot);
            ensure!(
                fs::symlink_metadata(&path)?.is_dir(),
                "Native checkpoint must not be a symlink"
            );
            verify(&path)?;
        }
        if previous["releaseID"] == release_id {
            return Ok(lease);
        }
    }
    let mut has_data = false;
    for name in DURABLE_NAMES {
        has_data = has_data || regular_file(&data, name)?.is_some();
    }
    let snapshot = if has_data {
        let name = format!("checkpoint-{}", Uuid::new_v4());
        backup(&data, &root.join(&name))?;
        verify(&root.join(&name))?;
        Some(name)
    } else {
        None
    };
    let receipt = json!({"format":1,"releaseID":release_id,"snapshot":snapshot,
        "previousReleaseID":previous.as_ref().and_then(|p|p.get("releaseID")),"preparedAt":Utc::now().to_rfc3339()});
    let temporary = root.join(format!("last-launch.{}.tmp", Uuid::new_v4()));
    write_json(&temporary, &receipt)?;
    fs::rename(&temporary, root.join("last-launch.json"))?;
    sync_directory(&root)?;
    tracing::info!(?snapshot, "Native startup checkpoint prepared");
    Ok(lease)
}

fn release_identity() -> Result<String> {
    let executable = std::env::current_exe()?;
    let mut hash = Sha256::new();
    hash.update(digest(&executable)?.1);
    if let Some(helpers) = executable
        .parent()
        .filter(|p| p.file_name().is_some_and(|n| n == "Helpers"))
    {
        let contents = helpers
            .parent()
            .context("Missing bundle Contents directory")?;
        for name in ["MacOS/Craft", "Info.plist"] {
            hash.update(digest(&required_file(contents, name)?)?.1);
        }
    }
    Ok(format!("{:x}", hash.finalize()))
}

/// Returns true for recovery/help commands so they never enter server startup.
pub fn run_command(arguments: &[std::ffi::OsString]) -> Result<bool> {
    if arguments.is_empty() {
        return Ok(false);
    }
    let usage = "Usage: craft-backend [backup DATA_DIR NEW_SNAPSHOT_DIR | verify SNAPSHOT_DIR | restore SNAPSHOT_DIR NEW_DATA_DIR]";
    if arguments.len() == 1 && (arguments[0] == "--help" || arguments[0] == "-h") {
        println!("{usage}");
        return Ok(true);
    }
    let manifest = match (arguments[0].to_str(), arguments.len()) {
        (Some("backup"), 3) => backup(Path::new(&arguments[1]), Path::new(&arguments[2])),
        (Some("verify"), 2) => verify(Path::new(&arguments[1])),
        (Some("restore"), 3) => restore(Path::new(&arguments[1]), Path::new(&arguments[2])),
        _ => bail!("{usage}"),
    }?;
    println!(
        "{}: verified {} snapshot files.",
        arguments[0].to_string_lossy(),
        manifest.files.len()
    );
    Ok(true)
}
