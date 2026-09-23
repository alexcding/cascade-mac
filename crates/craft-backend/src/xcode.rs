//! Everything that knows how Xcode works: finding what `xcodebuild` should open, the
//! schemes it offers, the destinations a scheme runs on and the settings of a build.
//! Another IDE gets a module of its own beside this one; `local.rs` only decides which
//! file an IDE opens.
//!
//! Every `xcodebuild` here loads the project and resolves its Swift package graph before it
//! answers, into the same checkouts the build uses. Two of them on one worktree clone into
//! the same folders at once, which corrupts them. So they queue on the worktree's gate
//! (`Warmup::gate`), the one the package warm-up holds. Their answers only change when the
//! project files do, so each one is kept in `data.db` with a fingerprint of those files.
//! Asking again is instant, even after a relaunch.

use std::{
    cmp::Reverse,
    fs,
    future::Future,
    path::{Path, PathBuf},
    time::{Duration, UNIX_EPOCH},
};

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{
    cli,
    error::ApiError,
    local::{foreign_origin, resolve_launch, resolve_path, PROJECT_WALK_SKIP},
    warmup::{stamp_of, Plan},
    AppState,
};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// How long a question waits for a warm-up, or another question, to finish with the worktree.
/// Past it the answer is an error, never a collision. With xcodebuild's own 90 seconds on
/// top, this stays inside the app's 600-second timeout for these requests.
const ANSWER_WAIT: Duration = Duration::from_secs(480);
const STILL_RESOLVING: &str =
    "Swift packages are still resolving in this worktree. Try again when that finishes.";

#[derive(Default, Deserialize)]
pub struct XcodeQuery {
    path: Option<String>,
    rel: Option<String>,
    scheme: Option<String>,
    /// The destination's id. The name predates Macs and devices.
    sim: Option<String>,
    configuration: Option<String>,
    /// "1" skips the kept answer and asks `xcodebuild` again.
    refresh: Option<String>,
}

fn target_args(target: &Path) -> Vec<String> {
    let value = target.to_string_lossy();
    if value.ends_with(".xcworkspace") {
        vec!["-workspace".into(), value.into_owned()]
    } else if value.ends_with(".xcodeproj") {
        vec!["-project".into(), value.into_owned()]
    } else {
        vec![]
    }
}
fn xcode_cwd(root: &Path, target: &Path) -> PathBuf {
    if target_args(target).is_empty() {
        if target.file_name().and_then(|v| v.to_str()) == Some("Package.swift") {
            target.parent().unwrap_or(root).to_path_buf()
        } else {
            target.to_path_buf()
        }
    } else {
        root.to_path_buf()
    }
}
fn xcode_request(query: &XcodeQuery) -> Result<(PathBuf, PathBuf), ApiError> {
    let raw = query
        .path
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(raw);
    let (target, _) = resolve_launch(&root, query.rel.as_deref().unwrap_or(""), "xcode")?;
    Ok((root, target))
}

/// What Xcode resolves before a fresh checkout can build: the Swift package graph. Every
/// worktree is a path Xcode has never seen, so this is paid once per worktree, and paying it
/// during the build is what reads as a hang.
///
/// No `Package.resolved` means no packages to fetch, and no plan — an Xcode project without
/// dependencies never spawns anything.
pub(crate) async fn warmup_plan(root: &Path, rel: &str) -> Option<Plan> {
    plan_in(root, rel, &xcode_locations().await.roots)
}

fn plan_in(root: &Path, rel: &str, roots: &[PathBuf]) -> Option<Plan> {
    const LABEL: &str = "Resolving Swift packages";
    let (target, _) = resolve_launch(root, rel, "xcode").ok()?;
    if target.file_name().and_then(|v| v.to_str()) == Some("Package.swift") {
        let cwd = target.parent()?.to_path_buf();
        let stamp = cwd.join("Package.resolved");
        if !stamp.exists() {
            return None;
        }
        let sources = cwd.join(".build");
        return Some(Plan {
            label: LABEL,
            program: "swift",
            args: vec!["package".into(), "resolve".into()],
            satisfied: pins_checked_out(&stamp, &sources),
            cwd,
            stamp,
        });
    }
    let document = target_args(&target);
    if document.is_empty() {
        return None;
    }
    let stamp = resolved_versions(&target)?;
    let satisfied = !workspace_moves_derived_data(&target)
        && derived_data_folder(&target, roots)
            .is_some_and(|folder| pins_checked_out(&stamp, &folder.join("SourcePackages")));
    let mut args = vec!["-resolvePackageDependencies".to_string()];
    args.extend(document);
    Some(Plan {
        label: LABEL,
        program: "xcodebuild",
        args,
        cwd: root.to_path_buf(),
        stamp,
        satisfied,
    })
}

/// Where Xcode keeps the versions it resolved: inside the workspace, or inside the implicit
/// workspace every project carries.
fn resolved_versions(target: &Path) -> Option<PathBuf> {
    let name = target.file_name()?.to_str()?;
    let base = if name.ends_with(".xcworkspace") {
        target.to_path_buf()
    } else {
        target.join("project.xcworkspace")
    };
    let path = base.join("xcshareddata/swiftpm/Package.resolved");
    path.exists().then_some(path)
}

/// The preferences that move what Xcode builds: the derived data location and the build
/// locations under Advanced. Per-workspace equivalents live in `*.xcsettings`, which the
/// project fingerprint follows.
const LOCATION_KEYS: &[&str] = &[
    "IDECustomDerivedDataLocation",
    "IDEBuildLocationStyle",
    "IDECustomBuildLocationType",
    "IDECustomBuildProductsPath",
    "IDECustomBuildIntermediatesPath",
];

/// Where Xcode puts what it builds, as its preferences say.
#[derive(Clone, Default)]
struct Locations {
    /// Where to look for a worktree's derived data folder: the custom folder when one is set,
    /// otherwise the default. A location relative to each workspace, or one that cannot be
    /// read, gives nowhere to look, and the warm-up then runs as it always did.
    roots: Vec<PathBuf>,
    /// The location preferences, verbatim. An answer that holds a build path depends on them.
    settings: String,
    /// False when the preferences could not be read. Then no kept answer that holds a build
    /// path can be trusted.
    readable: bool,
}

/// Builds `Locations` from a `defaults read com.apple.dt.Xcode` dump and the custom derived
/// data location read on its own (`None` when the dump has no such key).
fn parse_locations(dump: &str, custom: Option<&str>, home: Option<&Path>) -> Locations {
    let mut settings: Vec<String> = dump
        .lines()
        .map(str::trim)
        .filter(|line| line.split_once(" = ").is_some_and(|(key, _)| LOCATION_KEYS.contains(&key)))
        .map(str::to_owned)
        .collect();
    settings.sort();
    let roots = match custom {
        None => home.map(|home| home.join("Library/Developer/Xcode/DerivedData")),
        Some(value) if value.starts_with('/') => Some(PathBuf::from(value)),
        Some(value) => value.strip_prefix("~/").and_then(|rest| home.map(|home| home.join(rest))),
    };
    Locations {
        roots: roots.into_iter().collect(),
        settings: settings.join("\n"),
        readable: true,
    }
}

/// Xcode's build locations, read again whenever its preferences file changes, so a location
/// moved while the app runs moves the answers that point into it.
async fn xcode_locations() -> Locations {
    static KNOWN: std::sync::Mutex<Option<(String, Locations)>> = std::sync::Mutex::new(None);
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let preferences = home
        .as_ref()
        .map(|home| stamp_of(&home.join("Library/Preferences/com.apple.dt.Xcode.plist")))
        .unwrap_or_default();
    let known = KNOWN
        .lock()
        .unwrap()
        .as_ref()
        .filter(|(stamp, _)| *stamp == preferences)
        .map(|(_, locations)| locations.clone());
    if let Some(locations) = known {
        return locations;
    }
    let read = |args: Vec<&'static str>| cli::run("defaults", args, Duration::from_secs(5));
    let dump = match read(vec!["read", "com.apple.dt.Xcode"]).await {
        Ok(dump) => Some(dump),
        // No preferences at all: Xcode has never run here, so every location is the default.
        // macOS words it "Domain … not found"; older releases, "… does not exist".
        Err(error) if ["not found", "does not exist"].iter().any(|w| error.to_string().contains(w)) => {
            Some(String::new())
        }
        Err(_) => None,
    };
    // The dump escapes strings ("\U00e9", "\""); a read of the one key prints the path as is.
    let custom = match &dump {
        Some(dump) if dump.lines().any(|line| line.trim().starts_with("IDECustomDerivedDataLocation = ")) => {
            match read(vec!["read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"]).await {
                Ok(value) => Some(Some(value.trim_end_matches('\n').to_owned())),
                Err(_) => None,
            }
        }
        Some(_) => Some(None),
        None => None,
    };
    match (dump, custom) {
        (Some(dump), Some(custom)) => {
            let locations = parse_locations(&dump, custom.as_deref(), home.as_deref());
            *KNOWN.lock().unwrap() = Some((preferences, locations.clone()));
            locations
        }
        // A read that failed may pass: nowhere to look and nothing to trust this time, and a
        // fresh read next time.
        _ => Locations::default(),
    }
}

/// Whether a workspace sets a derived data location of its own (File > Workspace Settings),
/// shared or per user. Xcode's global location then says nothing about where it resolves.
fn workspace_moves_derived_data(target: &Path) -> bool {
    let workspace = if target.extension().is_some_and(|e| e == "xcworkspace") {
        target.to_path_buf()
    } else {
        target.join("project.xcworkspace")
    };
    let mut files = vec![workspace.join("xcshareddata/WorkspaceSettings.xcsettings")];
    for user in fs::read_dir(workspace.join("xcuserdata")).into_iter().flatten().flatten() {
        files.push(user.path().join("WorkspaceSettings.xcsettings"));
    }
    files.iter().filter_map(|file| fs::read_to_string(file).ok()).any(|plist| {
        plist
            .split("<key>DerivedDataLocationStyle</key>")
            .nth(1)
            .and_then(|rest| rest.split("<string>").nth(1))
            .and_then(|value| value.split("</string>").next())
            .is_some_and(|style| style.trim() != "Default")
    })
}

/// RFC 1321 MD5, used only to name folders the way Xcode does. Nothing here relies on it
/// being a secure hash.
fn md5(input: &[u8]) -> [u8; 16] {
    const SHIFTS: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const TABLE: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];
    let mut message = input.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&(input.len() as u64).wrapping_mul(8).to_le_bytes());
    let mut state = [0x67452301u32, 0xefcdab89, 0x98badcfe, 0x10325476];
    for block in message.chunks_exact(64) {
        let word = |i: usize| u32::from_le_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        let [mut a, mut b, mut c, mut d] = state;
        for i in 0..64 {
            let (mix, index) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let rotated = mix
                .wrapping_add(a)
                .wrapping_add(TABLE[i])
                .wrapping_add(word(index))
                .rotate_left(SHIFTS[i]);
            (a, d, c) = (d, c, b);
            b = b.wrapping_add(rotated);
        }
        for (value, add) in state.iter_mut().zip([a, b, c, d]) {
            *value = value.wrapping_add(add);
        }
    }
    let mut digest = [0u8; 16];
    for (chunk, value) in digest.chunks_exact_mut(4).zip(state) {
        chunk.copy_from_slice(&value.to_le_bytes());
    }
    digest
}

/// The spelling of a path that Xcode records and hashes: Foundation's standardized one, which
/// drops a leading "/private" when the shorter path exists too, so "/private/tmp/x" becomes
/// "/tmp/x".
fn xcode_spelling(path: &Path) -> PathBuf {
    match path.strip_prefix("/private") {
        Ok(rest) if Path::new("/").join(rest).exists() => Path::new("/").join(rest),
        _ => path.to_path_buf(),
    }
}

/// The folder name Xcode gives a workspace's derived data: its name, a dash, and the MD5 of
/// its path as 28 letters, each half of the digest read as a big-endian number and written
/// in base 26.
fn derived_data_name(workspace: &Path) -> Option<String> {
    use std::os::unix::ffi::OsStrExt;
    let stem = workspace.file_stem()?.to_str()?.replace(' ', "_");
    let digest = md5(xcode_spelling(workspace).as_os_str().as_bytes());
    let letters = |half: &[u8]| {
        let mut value = u64::from_be_bytes(half.try_into().unwrap());
        let mut out = [b'a'; 14];
        for slot in out.iter_mut().rev() {
            *slot = b'a' + (value % 26) as u8;
            value /= 26;
        }
        String::from_utf8_lossy(&out).into_owned()
    };
    Some(format!("{stem}-{}{}", letters(&digest[..8]), letters(&digest[8..])))
}

/// The derived data folder Xcode builds `workspace` in, under one of `roots`. First by its
/// name, which is known before anything is built: resolving packages writes no info.plist,
/// so a worktree the warm-up prepared has only its name to be found by. Then by the path an
/// info.plist records, in case a name was spelled differently.
fn derived_data_folder(workspace: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    let named = derived_data_name(workspace)?;
    if let Some(folder) = roots.iter().map(|root| root.join(&named)).find(|f| f.is_dir()) {
        return Some(folder);
    }
    let prefix = format!("{}-", workspace.file_stem()?.to_str()?.replace(' ', "_"));
    let spelled = xcode_spelling(workspace);
    let path = spelled.to_string_lossy();
    let escaped = path.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let recorded = format!("<string>{escaped}</string>");
    roots.iter().find_map(|root| {
        fs::read_dir(root).ok()?.flatten().find_map(|entry| {
            let name = entry.file_name();
            let hash = name.to_str()?.strip_prefix(&prefix)?;
            if hash.len() != 28 || !hash.bytes().all(|b| b.is_ascii_lowercase()) {
                return None;
            }
            let folder = entry.path();
            let plist = fs::read_to_string(folder.join("info.plist")).ok()?;
            plist.contains(&recorded).then_some(folder)
        })
    })
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// Whether the SwiftPM checkouts in `sources` (`workspace-state.json` beside `checkouts/`)
/// already hold every package the lockfile pins, at the pinned revision. A resolve would
/// produce exactly that. So a worktree that passes has nothing left to resolve, whoever
/// resolved it (the warm-up, a build or Xcode) and whenever. A file that cannot be read, or a
/// format this does not know, answers no, and the resolve runs as before.
fn pins_checked_out(resolved: &Path, sources: &Path) -> bool {
    let (Some(lock), Some(state)) = (
        read_json(resolved),
        read_json(&sources.join("workspace-state.json")),
    ) else {
        return false;
    };
    let (Some(pins), Some(dependencies)) = (
        lock["pins"].as_array(),
        state["object"]["dependencies"].as_array(),
    ) else {
        return false;
    };
    let checked_out = |pin: &Value| {
        let Some(dependency) = dependencies
            .iter()
            .find(|d| pin["identity"].is_string() && d["packageRef"]["identity"] == pin["identity"])
        else {
            return false;
        };
        let (wanted, have) = (&pin["state"], &dependency["state"]);
        match have["name"].as_str() {
            Some("sourceControlCheckout") => {
                wanted["revision"].is_string()
                    && have["checkoutState"]["revision"] == wanted["revision"]
                    && dependency["subpath"]
                        .as_str()
                        .is_some_and(|sub| sources.join("checkouts").join(sub).is_dir())
            }
            Some("registryDownload") => {
                wanted["version"].is_string() && have["version"] == wanted["version"]
            }
            // Taken over with `swift package edit`: the developer's copy, not the resolver's.
            Some("edited") => true,
            _ => false,
        }
    };
    let artifacts = state["object"]["artifacts"].as_array();
    let artifacts_present = artifacts.is_none_or(|list| {
        list.iter()
            .filter_map(|artifact| artifact["path"].as_str())
            .all(|path| Path::new(path).exists())
    });
    pins.iter().all(checked_out) && artifacts_present
}

/// Files whose contents decide a scheme list, a destination list or a build setting. Workspace
/// settings (`WorkspaceSettings.xcsettings`) can move derived data, and the app path with it.
fn decides_project(name: &str) -> bool {
    matches!(
        name,
        "project.pbxproj"
            | "contents.xcworkspacedata"
            | "xcschememanagement.plist"
            | "Package.swift"
            | "Package.resolved"
    ) || name.ends_with(".xcscheme")
        || name.ends_with(".xcconfig")
        || name.ends_with(".xcsettings")
}

/// How far below the worktree root, and through how many folders, the fingerprint looks for
/// xcconfigs and manifests. Bounded so a monorepo costs milliseconds.
const FINGERPRINT_DEPTH: usize = 6;
const FINGERPRINT_FOLDERS: usize = 20_000;

/// Folder extensions for resources and build products, which never hold project settings.
/// Every other folder is walked, dotted names such as "Client.iOS" included.
const RESOURCE_FOLDERS: &[&str] = &[
    "app", "appex", "bundle", "docc", "dSYM", "framework", "iconset", "lproj", "mlmodelc",
    "mlpackage", "momd", "playground", "rcproject", "scnassets", "storyboardc", "xcarchive",
    "xcassets", "xcdatamodel", "xcdatamodeld", "xcframework", "xcresult", "xctemplate",
];

fn fingerprint_walk(
    root: &Path,
    dir: &Path,
    depth: usize,
    budget: &mut usize,
    lines: &mut Vec<String>,
) {
    if *budget == 0 {
        return;
    }
    *budget -= 1;
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    // Sorted, so a walk cut short by the budget always stops at the same folder.
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if kind.is_dir() {
            // Inside a project or workspace every folder counts, since schemes live deep in
            // xcuserdata. Elsewhere skip hidden, dependency, build and resource folders, all
            // but the SwiftPM one that holds package schemes.
            let bundle = name.ends_with(".xcodeproj") || name.ends_with(".xcworkspace");
            let inside = dir
                .ancestors()
                .take_while(|a| *a != root)
                .any(|a| a.extension().is_some_and(|e| e == "xcodeproj" || e == "xcworkspace"));
            let resource = Path::new(name.as_ref())
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| RESOURCE_FOLDERS.contains(&e));
            let plain = !name.starts_with('.')
                && !resource
                && !PROJECT_WALK_SKIP.contains(&name.as_ref());
            if bundle || inside || name == ".swiftpm" || (plain && depth < FINGERPRINT_DEPTH) {
                fingerprint_walk(root, &entry.path(), depth + 1, budget, lines);
            }
        } else if kind.is_file() && decides_project(&name) {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            let modified = meta
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |time| time.as_nanos());
            let path = entry.path();
            let relative = path.strip_prefix(root).unwrap_or(&path).to_string_lossy();
            lines.push(format!("{relative}\t{}\t{modified}", meta.len()));
        }
    }
}

/// The Xcode that answers: another one lists other SDKs and simulators.
fn xcode_identity() -> String {
    let developer = std::env::var_os("DEVELOPER_DIR")
        .map(PathBuf::from)
        .or_else(|| fs::read_link("/var/db/xcode_select_link").ok())
        .unwrap_or_else(|| PathBuf::from("/Applications/Xcode.app/Contents/Developer"));
    let version = developer.parent().map(|contents| contents.join("version.plist"));
    format!(
        "{}|{}",
        developer.display(),
        version.map(|v| stamp_of(&v)).unwrap_or_default()
    )
}

/// The simulators that exist. Creating or deleting one changes the Devices folder. A device
/// plugged in since leaves no trace here; the destination sheet asks with `refresh` for that.
fn simulator_identity() -> String {
    let Some(home) = std::env::var_os("HOME") else {
        return String::new();
    };
    let devices = PathBuf::from(home).join("Library/Developer/CoreSimulator/Devices");
    format!(
        "{}|{}",
        stamp_of(&devices),
        stamp_of(&devices.join("device_set.plist"))
    )
}

/// A fingerprint of everything that decides what `xcodebuild` says about `target` in the
/// worktree at `root`: the size and modification time of every project, workspace, scheme,
/// xcconfig and package manifest in reach, the selected Xcode, the simulators when `devices`
/// is set, and `context`. The same fingerprint means `xcodebuild` would give the same answer.
/// A branch switch or an edit in Xcode changes it.
///
/// The project itself and its folder are walked first, each on a budget of its own, so a
/// large sibling tree that uses up the walk from the root never leaves them out.
fn fingerprint(root: &Path, target: &Path, devices: bool, context: &str, folders: usize) -> String {
    let mut lines = Vec::new();
    let near = target.parent().filter(|dir| dir.starts_with(root) && *dir != root);
    for start in [Some(target), near, Some(root)].into_iter().flatten() {
        let mut budget = folders;
        fingerprint_walk(root, start, 0, &mut budget, &mut lines);
    }
    lines.sort();
    lines.dedup();
    lines.push(xcode_identity());
    if devices {
        lines.push(simulator_identity());
    }
    lines.push(context.to_owned());
    let digest = Sha256::digest(lines.join("\n").as_bytes());
    digest.iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// One question put to `xcodebuild` about a worktree, and what its answer depends on.
struct Question<'a> {
    root: &'a Path,
    target: &'a Path,
    /// What is asked, such as "schemes" and the target, kept under the worktree's prefix.
    key: String,
    /// The answer also depends on which simulators exist.
    devices: bool,
    /// Anything else the answer depends on, such as where derived data lives.
    context: String,
    refresh: bool,
    /// Past this, waiting for the worktree's gate gives up.
    deadline: tokio::time::Instant,
}

impl Question<'_> {
    async fn fingerprint(&self) -> String {
        let (root, target) = (self.root.to_path_buf(), self.target.to_path_buf());
        let (devices, context) = (self.devices, self.context.clone());
        tokio::task::spawn_blocking(move || {
            fingerprint(&root, &target, devices, &context, FINGERPRINT_FOLDERS)
        })
        .await
        .unwrap_or_default()
    }
}

/// Where a worktree's answers are kept: its path without stray separators, then a newline, so
/// that one worktree's prefix is never the prefix of another's.
fn answer_prefix(worktree: &Path) -> String {
    format!("{}\n", worktree.components().collect::<PathBuf>().display())
}

/// Forgets every answer kept for a worktree that is gone.
pub(crate) fn forget_answers(app: &AppState, worktree: &Path) {
    if let Err(error) = app.db.forget_xcode_answers(&answer_prefix(worktree)) {
        tracing::warn!("could not forget xcodebuild answers for {}: {error}", worktree.display());
    }
}

/// Answers from `data.db` while the fingerprint still matches. Otherwise runs `fetch` on the
/// worktree's gate and keeps what it returns. Failures are never kept. `refresh` skips the
/// kept answer.
async fn remembered<F, Fut>(app: &AppState, question: Question<'_>, fetch: F) -> Result<Value, ApiError>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<Value, ApiError>>,
{
    let key = format!("{}{}", answer_prefix(question.root), question.key);
    if !question.refresh {
        let stamp = question.fingerprint().await;
        if let Ok(Some(value)) = app.db.xcode_answer(&key, &stamp) {
            return Ok(value);
        }
    }
    let gate = app.warmup.gate(&question.root.to_string_lossy());
    let Ok(_turn) = tokio::time::timeout_at(question.deadline, gate.lock()).await else {
        return Err(ApiError::conflict(STILL_RESOLVING));
    };
    // Taken again after the wait. A request queued behind this same question finds the
    // answer; a file edited meanwhile is caught. The fingerprint kept is the one the fetch
    // started from, so an edit during the fetch is caught next time.
    let stamp = question.fingerprint().await;
    if !question.refresh {
        if let Ok(Some(value)) = app.db.xcode_answer(&key, &stamp) {
            return Ok(value);
        }
    }
    let value = fetch().await?;
    if let Err(error) = app.db.set_xcode_answer(&key, &stamp, &value) {
        tracing::warn!("could not keep the xcodebuild answer for {key}: {error}");
    }
    Ok(value)
}

fn refreshing(query: &XcodeQuery) -> bool {
    query.refresh.as_deref() == Some("1")
}

pub async fn schemes(
    headers: HeaderMap,
    State(app): State<AppState>,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let (root, target) = xcode_request(&query)?;
    let question = Question {
        root: &root,
        target: &target,
        key: format!("schemes\n{}", target.display()),
        devices: false,
        context: String::new(),
        refresh: refreshing(&query),
        deadline: tokio::time::Instant::now() + ANSWER_WAIT,
    };
    let value = remembered(&app, question, || async {
        let mut args = vec!["-list".into(), "-json".into()];
        args.extend(target_args(&target));
        let raw = cli::run_in(
            "xcodebuild",
            args,
            Duration::from_secs(90),
            Some(&xcode_cwd(&root, &target)),
        )
        .await
        .map_err(ApiError::internal)?;
        let parsed: Value = serde_json::from_str(&raw).map_err(ApiError::internal)?;
        let info = parsed
            .get("workspace")
            .or_else(|| parsed.get("project"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        Ok(json!({"target":target,"name":info["name"],"schemes":info["schemes"],"targets":info["targets"],"configurations":info["configurations"]}))
    })
    .await?;
    Ok(Json(value))
}

/// The run destinations a scheme accepts, read from `xcodebuild -showdestinations`.
/// Placeholders ("Any Mac") and variants that share My Mac's id are left out, as is
/// the second architecture of the same machine.
///
/// Ordered as a destination menu reads best: this Mac, then connected devices, then
/// simulators; iOS before other platforms; the newest OS first, and iPhones before iPads on
/// the same OS. xcodebuild's own order, by name, settles the rest.
fn parse_destinations(raw: &str) -> Vec<Value> {
    let field = Regex::new(r"(?:^|, )(platform|arch|variant|id|OS|name|error):").unwrap();
    let mut list = Vec::<(_, Value)>::new();
    let mut compatible = false;
    for line in raw.lines().map(str::trim) {
        if !line.starts_with('{') {
            let heading = line.to_lowercase();
            if heading.contains("destinations") {
                compatible = !heading.contains("incompatible")
                    && !heading.contains("ineligible")
                    && (heading.contains("compatible") || heading.contains("available"));
            }
            continue;
        }
        if !compatible {
            continue;
        }
        let body = line.trim_start_matches('{').trim_end_matches('}').trim();
        let marks: Vec<_> = field.captures_iter(body).collect();
        let mut entry = std::collections::HashMap::new();
        for (index, mark) in marks.iter().enumerate() {
            let from = mark.get(0).unwrap().end();
            let to = marks
                .get(index + 1)
                .map_or(body.len(), |next| next.get(0).unwrap().start());
            entry.insert(mark.get(1).unwrap().as_str(), body[from..to].trim());
        }
        let (Some(id), Some(name), Some(platform)) =
            (entry.get("id"), entry.get("name"), entry.get("platform"))
        else {
            continue;
        };
        if id.starts_with("dvtdevice-")
            || entry.contains_key("variant")
            || entry.contains_key("error")
            || list.iter().any(|(_, seen)| seen["udid"] == *id)
        {
            continue;
        }
        let (kind, kind_rank) = if platform.ends_with("Simulator") {
            ("simulator", 2)
        } else if *platform == "macOS" {
            ("mac", 0)
        } else {
            ("device", 1)
        };
        let system = platform.trim_end_matches(" Simulator");
        let runtime = entry
            .get("OS")
            .map_or_else(|| system.to_owned(), |os| format!("{system} {os}"));
        let version: Vec<u32> = entry
            .get("OS")
            .map(|os| os.split('.').map_while(|part| part.parse().ok()).collect())
            .unwrap_or_default();
        let family = if name.starts_with("iPhone") {
            0
        } else if name.starts_with("iPad") {
            1
        } else {
            2
        };
        let order = (
            kind_rank,
            system != "iOS",
            system.to_owned(),
            Reverse(version),
            family,
        );
        list.push((order, json!({"udid":id,"name":name,"platform":platform,"runtime":runtime,"kind":kind})));
    }
    // Stable, so equal keys keep xcodebuild's order.
    list.sort_by(|a, b| a.0.cmp(&b.0));
    list.into_iter().map(|(_, value)| value).collect()
}

pub async fn destinations(
    headers: HeaderMap,
    State(app): State<AppState>,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let scheme = query
        .scheme
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("scheme required"))?;
    let (root, target) = xcode_request(&query)?;
    let question = Question {
        root: &root,
        target: &target,
        key: format!("destinations\n{}\n{scheme}", target.display()),
        devices: true,
        context: String::new(),
        refresh: refreshing(&query),
        deadline: tokio::time::Instant::now() + ANSWER_WAIT,
    };
    let value = remembered(&app, question, || async {
        let mut args = vec!["-showdestinations".into()];
        args.extend(target_args(&target));
        args.extend(["-scheme".into(), scheme.into()]);
        let raw = cli::run_in(
            "xcodebuild",
            args,
            Duration::from_secs(90),
            Some(&xcode_cwd(&root, &target)),
        )
        .await
        .map_err(ApiError::internal)?;
        Ok(Value::Array(parse_destinations(&raw)))
    })
    .await?;
    Ok(Json(value))
}

pub async fn build_settings(
    headers: HeaderMap,
    State(app): State<AppState>,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let scheme = query
        .scheme
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("scheme required"))?;
    let sim = query
        .sim
        .as_deref()
        .map(str::trim)
        .filter(|v| Regex::new(r"^[0-9A-Fa-f-]{16,}$").unwrap().is_match(v))
        .ok_or_else(|| ApiError::bad_request("sim (a destination id) required"))?;
    let (root, target) = xcode_request(&query)?;
    let configuration = query
        .configuration
        .as_deref()
        .filter(|v| !v.is_empty())
        .unwrap_or("Debug");
    // Only Run asks for build settings, and it starts the build as soon as they arrive. That
    // build resolves the package graph itself, outside the gate, so it must not start while a
    // warm-up is still cloning into the same checkouts.
    let deadline = tokio::time::Instant::now() + ANSWER_WAIT;
    if !app.warmup.settle(&root.to_string_lossy(), deadline).await {
        return Err(ApiError::conflict(STILL_RESOLVING));
    }
    let locations = xcode_locations().await;
    let question = Question {
        root: &root,
        target: &target,
        key: format!("settings\n{}\n{scheme}\n{configuration}\n{sim}", target.display()),
        devices: false,
        // The app path is under derived data, or a build location, which the user can move in
        // Xcode's settings. Unread settings could hide such a move, so nothing kept is used.
        context: locations.settings,
        refresh: refreshing(&query) || !locations.readable,
        deadline,
    };
    let value = remembered(&app, question, || async {
        let mut args = vec!["-showBuildSettings".into(), "-json".into()];
        args.extend(target_args(&target));
        args.extend([
            "-scheme".into(),
            scheme.into(),
            "-configuration".into(),
            configuration.into(),
            "-destination".into(),
            format!("id={sim}"),
        ]);
        let raw = cli::run_in(
            "xcodebuild",
            args,
            Duration::from_secs(90),
            Some(&xcode_cwd(&root, &target)),
        )
        .await
        .map_err(ApiError::internal)?;
        let list: Value = serde_json::from_str(&raw).map_err(ApiError::internal)?;
        let entries = list
            .as_array()
            .ok_or_else(|| ApiError::internal("Invalid xcodebuild response"))?;
        let entry = entries
            .iter()
            .find(|e| {
                e["buildSettings"]["FULL_PRODUCT_NAME"]
                    .as_str()
                    .is_some_and(|v| v.ends_with(".app"))
            })
            .or_else(|| entries.first())
            .ok_or_else(|| ApiError::internal(format!("Scheme {scheme} builds no app")))?;
        let settings = &entry["buildSettings"];
        let product = settings["FULL_PRODUCT_NAME"].as_str().unwrap_or("");
        let directory = settings["BUILT_PRODUCTS_DIR"].as_str().unwrap_or("");
        if product.is_empty() || directory.is_empty() {
            return Err(ApiError::internal(format!("Scheme {scheme} builds no app")));
        }
        Ok(json!({"appPath":Path::new(directory).join(product),"executablePath":Path::new(directory).join(settings["EXECUTABLE_PATH"].as_str().unwrap_or("")),"platform":settings["PLATFORM_NAME"],"bundleId":settings["PRODUCT_BUNDLE_IDENTIFIER"],"productName":product,"target":target,"configuration":configuration}))
    })
    .await?;
    Ok(Json(value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn keeps_only_what_the_scheme_can_run_on() {
        let raw = "\tDestinations compatible with the \"App\" scheme:\n\
            \t\t{ platform:macOS, arch:arm64, id:00006041-000811C00204801C, name:My Mac }\n\
            \t\t{ platform:macOS, arch:x86_64, id:00006041-000811C00204801C, name:My Mac }\n\
            \t\t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006041-000811C00204801D, name:My Mac }\n\
            \t\t{ platform:macOS, name:Any Mac }\n\
            \t\t{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }\n\
            \t\t{ platform:iOS, arch:arm64, id:00008140-001A2B3C4D5E6F70, name:Chen's iPhone }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:3E138F84-2AE2-448B-A707-711F689819E4, OS:27.0, name:iPad Pro 11-inch (M5), 2nd }\n\
            \n\tDestinations incompatible with the \"App\" scheme:\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:1FA32F68-3F28-4AD5-A311-D6DDD0374FE1, OS:27.0, name:iPad (A16), error:iPad (A16)'s platform doesn't match. }\n";
        let list = parse_destinations(raw);
        let kinds: Vec<_> = list.iter().map(|d| d["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["mac", "device", "simulator"]);
        assert_eq!(list[2]["name"], "iPad Pro 11-inch (M5), 2nd");
        assert_eq!(list[2]["runtime"], "iOS 27.0");
        assert_eq!(list[0]["runtime"], "macOS");
    }

    #[test]
    fn reads_the_older_available_heading() {
        let raw = "Available destinations for the \"App\" scheme:\n\
            { platform:macOS, arch:arm64, id:0000-1, name:My Mac }\n\
            Ineligible destinations for the \"App\" scheme:\n\
            { platform:iOS, id:0000-2, name:Phone, error:locked }\n";
        assert_eq!(parse_destinations(raw).len(), 1);
    }

    #[test]
    fn lists_the_newest_os_first_and_iphones_before_ipads() {
        // xcodebuild's order: platform, then OS ascending, then name.
        let raw = "\tDestinations compatible with the \"App\" scheme:\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000001, OS:18.5, name:iPhone 16 }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000002, OS:26.4.1, name:iPhone 17 }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000003, OS:27.0, name:iPad Air 13-inch (M4) }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000004, OS:27.0, name:iPhone 18 }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000005, OS:27.0, name:iPhone 18 Pro }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000006, OS:26.4, name:iPhone 17 }\n\
            \t\t{ platform:visionOS Simulator, arch:arm64, id:A0000000-0000-0000-0000-000000000007, OS:27.0, name:Apple Vision Pro }\n\
            \t\t{ platform:iOS, arch:arm64, id:00008140-001A2B3C4D5E6F70, name:Chen's iPhone }\n\
            \t\t{ platform:macOS, arch:arm64, id:00006041-000811C00204801C, name:My Mac }\n";
        let list = parse_destinations(raw);
        let order: Vec<_> = list
            .iter()
            .map(|d| format!("{} · {}", d["name"].as_str().unwrap(), d["runtime"].as_str().unwrap()))
            .collect();
        assert_eq!(
            order,
            [
                "My Mac · macOS",
                "Chen's iPhone · iOS",
                "iPhone 18 · iOS 27.0",
                "iPhone 18 Pro · iOS 27.0",
                "iPad Air 13-inch (M4) · iOS 27.0",
                "iPhone 17 · iOS 26.4.1",
                "iPhone 17 · iOS 26.4",
                "iPhone 16 · iOS 18.5",
                "Apple Vision Pro · visionOS 27.0",
            ]
        );
    }

    /// A checkout whose lockfile pins `revision`, and a derived data root holding the folder
    /// Xcode would build it in, with `recorded` as the checked-out revision when given.
    fn resolved_worktree(revision: &str, recorded: Option<&str>) -> (TempDir, TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("App.xcodeproj");
        let swiftpm = project.join("project.xcworkspace/xcshareddata/swiftpm");
        fs::create_dir_all(&swiftpm).unwrap();
        fs::write(
            swiftpm.join("Package.resolved"),
            json!({"originHash":"x","pins":[{"identity":"dep","kind":"remoteSourceControl","location":"https://example.com/dep.git","state":{"revision":revision,"version":"1.0.0"}}],"version":3}).to_string(),
        )
        .unwrap();
        // Named the way Xcode names it, and with no info.plist: a resolve writes none.
        let derived = tempfile::tempdir().unwrap();
        let folder = derived.path().join(derived_data_name(&project).unwrap());
        fs::create_dir_all(&folder).unwrap();
        if let Some(recorded) = recorded {
            let sources = folder.join("SourcePackages");
            fs::create_dir_all(sources.join("checkouts/dep")).unwrap();
            fs::write(
                sources.join("workspace-state.json"),
                json!({"version":7,"object":{"artifacts":[],"dependencies":[{"packageRef":{"identity":"dep","kind":"remoteSourceControl","location":"https://example.com/dep.git","name":"dep"},"state":{"checkoutState":{"revision":recorded,"version":"1.0.0"},"name":"sourceControlCheckout"},"subpath":"dep"}],"prebuilts":[]}}).to_string(),
            )
            .unwrap();
        }
        (root, derived, folder)
    }

    fn satisfied(root: &TempDir, derived: &TempDir) -> bool {
        plan_in(root.path(), "", &[derived.path().to_path_buf()])
            .expect("a plan")
            .satisfied
    }

    #[test]
    fn a_worktree_whose_checkouts_match_the_pins_is_already_warm() {
        let (root, derived, _) = resolved_worktree("abc123", Some("abc123"));
        assert!(satisfied(&root, &derived));
    }

    #[test]
    fn a_pin_the_checkouts_do_not_hold_still_resolves() {
        let (root, derived, _) = resolved_worktree("def456", Some("abc123"));
        assert!(!satisfied(&root, &derived));
    }

    #[test]
    fn a_checkout_folder_that_is_gone_does_not_count() {
        let (root, derived, folder) = resolved_worktree("abc123", Some("abc123"));
        fs::remove_dir_all(folder.join("SourcePackages/checkouts/dep")).unwrap();
        assert!(!satisfied(&root, &derived));
    }

    #[test]
    fn build_locations_are_read_from_xcodes_preferences() {
        let home = Path::new("/Users/me");
        let default = home.join("Library/Developer/Xcode/DerivedData");
        let read = |dump: &str, custom: Option<&str>| parse_locations(dump, custom, Some(home));

        let plain = read("{\n    DVTTextShowLineNumbers = 1;\n}\n", None);
        assert_eq!(plain.roots, [default.clone()]);
        assert_eq!(plain.settings, "");

        // A custom folder replaces the default: a folder left there from before the move is
        // not the one Xcode resolves into now.
        let dump = "{\n    IDECustomDerivedDataLocation = \"/Volumes/D\\U00e9v/DD\";\n}\n";
        let custom = read(dump, Some("/Volumes/Dév/DD"));
        assert_eq!(custom.roots, [PathBuf::from("/Volumes/Dév/DD")]);
        assert_ne!(custom.settings, plain.settings);
        let tilde = "{\n    IDECustomDerivedDataLocation = \"~/DD\";\n}\n";
        assert_eq!(read(tilde, Some("~/DD")).roots, [home.join("DD")]);

        // Relative to each workspace: nowhere to look, and the answers still move with it.
        let relative = read("{\n    IDECustomDerivedDataLocation = DerivedData;\n}\n", Some("DerivedData"));
        assert!(relative.roots.is_empty());
        assert_ne!(relative.settings, plain.settings);

        let legacy = read("{\n    IDEBuildLocationStyle = Custom;\n    IDECustomBuildLocationType = RelativeToWorkspace;\n}\n", None);
        assert_ne!(legacy.settings, plain.settings, "a build location setting moves the app path too");
    }

    /// A workspace that keeps its derived data elsewhere is never judged by the global folder.
    #[test]
    fn a_workspace_with_its_own_derived_data_location_is_not_judged_warm() {
        let (root, derived, _) = resolved_worktree("abc123", Some("abc123"));
        assert!(satisfied(&root, &derived));
        let settings = root.path().join("App.xcodeproj/project.xcworkspace/xcuserdata/me.xcuserdatad");
        fs::create_dir_all(&settings).unwrap();
        let plist = |style: &str| format!("<plist><dict><key>DerivedDataLocationStyle</key>\n<string>{style}</string></dict></plist>");
        fs::write(settings.join("WorkspaceSettings.xcsettings"), plist("Default")).unwrap();
        assert!(satisfied(&root, &derived), "the default style moves nothing");
        fs::write(settings.join("WorkspaceSettings.xcsettings"), plist("WorkspaceRelativePath")).unwrap();
        assert!(!satisfied(&root, &derived));
    }

    #[test]
    fn md5_matches_the_rfc_1321_test_suite() {
        let hex = |input: &str| md5(input.as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(hex("a"), "0cc175b9c0f1b6a831c399e269772661");
        assert_eq!(hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0");
        assert_eq!(hex("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b");
        assert_eq!(
            hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
            "57edf4a22be3c955ac49da2e2107b67a"
        );
    }

    /// Checked against folders Xcode 27 created.
    #[test]
    fn derived_data_folders_are_named_the_way_xcode_names_them() {
        let name = |path: &str| derived_data_name(Path::new(path)).unwrap();
        assert_eq!(name("/Users/chen/Workspace/craft-mac/macos/Craft.xcodeproj"), "Craft-fzidscgpprcwypbzmzmgubqwsvlr");
        assert_eq!(name("/tmp/worktrees/feature/App.xcodeproj"), "App-frmzzoohvmzijudjgdkmnbaiecav");
    }

    /// Xcode hashes the standardized path, so a checkout reached through "/private" is named
    /// after the shorter spelling of the same folder.
    #[test]
    fn a_path_through_private_is_named_after_its_shorter_spelling() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().canonicalize().unwrap().join("App.xcodeproj");
        fs::create_dir_all(&project).unwrap();
        let short = Path::new("/").join(project.strip_prefix("/private").expect("temp dirs live under /private"));
        assert_eq!(derived_data_name(&project), derived_data_name(&short));
        assert_eq!(xcode_spelling(Path::new("/private/nowhere/App.xcodeproj")), Path::new("/private/nowhere/App.xcodeproj"));
    }

    /// A built folder records its workspace in info.plist, which finds one whose name was
    /// spelled some other way.
    #[test]
    fn a_folder_is_also_found_by_the_path_its_info_plist_records() {
        let (root, derived, folder) = resolved_worktree("abc123", Some("abc123"));
        let project = root.path().join("App.xcodeproj");
        let renamed = derived.path().join("App-abcdefghijklmnopqrstuvwxyzab");
        fs::rename(&folder, &renamed).unwrap();
        assert!(!satisfied(&root, &derived));
        fs::write(
            renamed.join("info.plist"),
            format!("<plist><dict><key>WorkspacePath</key><string>{}</string></dict></plist>", project.display()),
        )
        .unwrap();
        assert!(satisfied(&root, &derived));
    }

    #[test]
    fn a_worktree_xcode_never_resolved_is_not_warm() {
        let (root, derived, own) = resolved_worktree("abc123", None);
        assert!(!satisfied(&root, &derived));
        // Another checkout of the same project, fully resolved, does not stand in for this one.
        fs::remove_dir_all(&own).unwrap();
        let (_sibling, _sibling_derived, folder) = resolved_worktree("abc123", Some("abc123"));
        fs::rename(&folder, derived.path().join("App-zyxwvutsrqponmlkjihgfedcba")).unwrap();
        assert!(!satisfied(&root, &derived));
    }

    #[test]
    fn a_missing_binary_artifact_is_not_warm() {
        let (root, derived, folder) = resolved_worktree("abc123", Some("abc123"));
        let state = folder.join("SourcePackages/workspace-state.json");
        let mut value = read_json(&state).unwrap();
        value["object"]["artifacts"] = json!([{"path": folder.join("SourcePackages/artifacts/dep/Dep.xcframework")}]);
        fs::write(&state, value.to_string()).unwrap();
        assert!(!satisfied(&root, &derived));
    }

    #[test]
    fn the_fingerprint_follows_project_files_and_ignores_the_rest() {
        let (dir, _derived, _) = resolved_worktree("abc123", None);
        let root = dir.path();
        let project = root.join("App.xcodeproj");
        let fingerprint = |root: &Path| fingerprint(root, &project, false, "", FINGERPRINT_FOLDERS);
        fs::write(project.join("project.pbxproj"), "// one").unwrap();
        fs::create_dir_all(root.join("Config")).unwrap();
        fs::write(root.join("Config/Base.xcconfig"), "A = 1").unwrap();
        fs::create_dir_all(root.join("Sources")).unwrap();
        let first = fingerprint(root);

        fs::write(root.join("Sources/View.swift"), "struct V {}").unwrap();
        let state = project.join("project.xcworkspace/xcuserdata/me.xcuserdatad");
        fs::create_dir_all(&state).unwrap();
        fs::write(state.join("UserInterfaceState.xcuserstate"), "x").unwrap();
        fs::create_dir_all(root.join("node_modules/pkg")).unwrap();
        fs::write(root.join("node_modules/pkg/Other.xcconfig"), "B = 2").unwrap();
        assert_eq!(fingerprint(root), first, "source, UI state and dependencies do not count");

        fs::write(root.join("Config/Base.xcconfig"), "A = 22").unwrap();
        let edited = fingerprint(root);
        assert_ne!(edited, first, "an xcconfig edit counts");

        let schemes = project.join("xcuserdata/me.xcuserdatad/xcschemes");
        fs::create_dir_all(&schemes).unwrap();
        fs::write(schemes.join("Mine.xcscheme"), "<Scheme/>").unwrap();
        let scheme = fingerprint(root);
        assert_ne!(scheme, edited, "a user scheme counts");

        let settings = project.join("project.xcworkspace/xcuserdata/me.xcuserdatad");
        fs::write(settings.join("WorkspaceSettings.xcsettings"), "<plist/>").unwrap();
        assert_ne!(fingerprint(root), scheme, "a workspace's own derived data location counts");

        // A dotted folder name is a folder like any other; only resource folders are skipped.
        fs::create_dir_all(root.join("Client.iOS")).unwrap();
        fs::write(root.join("Client.iOS/Shared.xcconfig"), "C = 1").unwrap();
        let dotted = fingerprint(root);
        fs::write(root.join("Client.iOS/Shared.xcconfig"), "C = 10").unwrap();
        assert_ne!(fingerprint(root), dotted, "an xcconfig in a dotted folder counts");
        fs::create_dir_all(root.join("Assets.xcassets")).unwrap();
        fs::write(root.join("Assets.xcassets/Stray.xcconfig"), "D = 1").unwrap();
        let before = fingerprint(root);
        fs::write(root.join("Assets.xcassets/Stray.xcconfig"), "D = 11").unwrap();
        assert_eq!(fingerprint(root), before, "an asset catalog is not walked");
    }

    /// A large tree that sorts before the project cannot use up the walk and leave the
    /// project's own files out of the fingerprint.
    #[test]
    fn the_project_counts_even_when_the_walk_runs_out() {
        let root = tempfile::tempdir().unwrap();
        for sibling in ["a", "b", "c", "d"] {
            fs::create_dir_all(root.path().join(sibling).join("deep")).unwrap();
        }
        let project = root.path().join("zz/App.xcodeproj");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("project.pbxproj"), "// one").unwrap();
        fs::write(root.path().join("zz/Base.xcconfig"), "A = 1").unwrap();
        let print = || fingerprint(root.path(), &project, false, "", 3);
        let first = print();
        fs::write(project.join("project.pbxproj"), "// two!").unwrap();
        let second = print();
        assert_ne!(second, first, "the project file counts");
        fs::write(root.path().join("zz/Base.xcconfig"), "A = 22").unwrap();
        assert_ne!(print(), second, "the xcconfig beside the project counts");
    }

    async fn never() -> Result<Value, ApiError> {
        panic!("asked xcodebuild although the kept answer still held")
    }

    /// The cache and the gate together: a kept answer is served without asking again, a
    /// project edit asks again, and a gate held past the deadline is an error, not a wait
    /// past the app's timeout.
    #[tokio::test]
    async fn a_question_is_answered_once_and_never_waits_past_its_deadline() {
        let data = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(data.path()).unwrap(), None);
        let (root, _derived, _) = resolved_worktree("abc123", None);
        let project = root.path().join("App.xcodeproj");
        fs::write(project.join("project.pbxproj"), "// one").unwrap();
        let question = |wait: u64| Question {
            root: root.path(),
            target: &project,
            key: "schemes\nApp".into(),
            devices: false,
            context: String::new(),
            refresh: false,
            deadline: tokio::time::Instant::now() + Duration::from_millis(wait),
        };

        let gate = app.warmup.gate(&root.path().to_string_lossy());
        let turn = gate.lock().await;
        let blocked = remembered(&app, question(200), || async { Ok(json!(["first"])) }).await;
        assert!(blocked.is_err(), "answered while a warm-up held the gate");
        drop(turn);

        let first = remembered(&app, question(1000), || async { Ok(json!(["first"])) }).await;
        assert_eq!(first.ok(), Some(json!(["first"])));
        assert_eq!(remembered(&app, question(1000), never).await.ok(), Some(json!(["first"])));

        fs::write(project.join("project.pbxproj"), "// two!").unwrap();
        let edited = remembered(&app, question(1000), || async { Ok(json!(["second"])) }).await;
        assert_eq!(edited.ok(), Some(json!(["second"])));

        forget_answers(&app, &root.path().join(""));
        let forgotten = remembered(&app, question(1000), || async { Ok(json!(["third"])) }).await;
        assert_eq!(forgotten.ok(), Some(json!(["third"])), "a removed worktree keeps nothing");
    }
}
