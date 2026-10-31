//! Seatbelt confinement for the native device helper.
//!
//! Port of Synara's `apps/server/src/device/helperSandbox.ts`. The helper dlopens private
//! CoreSimulator/SimulatorKit frameworks and injects HID events driven by a model, with no need
//! for the user's files or the network; `device-helper.sb` takes those away. This is the one
//! place that applies it, so the long-lived RPC process and the one-shot `--probe` are confined
//! identically: a preflight under looser privileges would pass the checklist and then hang on
//! attach.
//!
//! Every profile parameter is resolved at spawn time, because the ones that matter move per
//! machine: Xcode can be a beta or live outside /Applications, and the helper cache is keyed per
//! toolchain.

use std::path::{Path, PathBuf};

/// Set to skip confinement entirely. Logged loudly wherever it is honoured.
pub const SANDBOX_OPT_OUT_ENV: &str = "CASCADE_DEVICE_HELPER_NO_SANDBOX";

pub const SANDBOX_PROFILE_NAME: &str = "device-helper.sb";

pub struct HelperSandboxContext<'a> {
    /// The helper binary about to be run.
    pub binary_path: &'a Path,
    /// The helper's source folder, which holds the profile.
    pub helper_source_dir: &'a Path,
    /// `DEVELOPER_DIR` for this run, resolved the way the helper resolves it.
    pub developer_dir: Option<&'a str>,
    /// The opt-out's value in the environment governing this run.
    pub opt_out: Option<&'a str>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HelperSandboxCommand {
    pub command: String,
    pub args: Vec<String>,
    /// None when the helper runs unconfined, for the message that says so.
    pub profile_path: Option<PathBuf>,
}

/// The Xcode bundle for a developer dir. `DEVELOPER_DIR` points at
/// `Xcode.app/Contents/Developer`, but the helper maps frameworks from all over the bundle, so
/// the profile has to cover the `.app`. CommandLineTools has no enclosing bundle and is returned
/// unchanged (`/Library/Developer` in the profile covers it).
pub fn xcode_app_root(developer_dir: &str) -> String {
    match developer_dir.find("/Contents/Developer") {
        Some(index) => developer_dir[..index].to_owned(),
        None => developer_dir.to_owned(),
    }
}

/// Resolves symlinks for a path used in a profile parameter: Seatbelt matches on the real path,
/// and `$TMPDIR` is really `/private/var/folders/...`. A missing path is returned as it is, so a
/// not-yet-created directory cannot break a spawn.
fn resolved(target: &Path) -> String {
    std::fs::canonicalize(target).unwrap_or_else(|_| target.to_path_buf()).to_string_lossy().into_owned()
}

/// Whether the opt-out is set: anything but empty, `0` or `false`.
pub fn sandbox_disabled(value: Option<&str>) -> bool {
    let value = value.map(str::trim).unwrap_or_default();
    !value.is_empty() && value != "0" && value != "false"
}

/// The opt-out as this process's environment sets it.
pub fn opt_out_from_env() -> Option<String> {
    std::env::var(SANDBOX_OPT_OUT_ENV).ok()
}

/// Wraps `argv` in `sandbox-exec`, or hands it back untouched. A missing profile runs unconfined
/// rather than refusing to start: a packaging mistake should cost the confinement, not the
/// feature. The caller logs the fallback.
pub fn sandboxed_helper_command(argv: &[String], context: &HelperSandboxContext<'_>) -> HelperSandboxCommand {
    let (command, args) = argv.split_first().expect("sandboxed_helper_command needs a command");
    let plain = HelperSandboxCommand { command: command.clone(), args: args.to_vec(), profile_path: None };
    if !cfg!(target_os = "macos") || sandbox_disabled(context.opt_out) {
        return plain;
    }
    let profile_path = context.helper_source_dir.join(SANDBOX_PROFILE_NAME);
    if std::fs::File::open(&profile_path).is_err() {
        return plain;
    }
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let helper_bundle = resolved(context.binary_path.parent().unwrap_or(Path::new("/")));
    let user_home = resolved(&home);
    let core_sim_home = resolved(&home.join("Library/Developer/CoreSimulator"));
    let core_sim_logs = resolved(&home.join("Library/Logs/CoreSimulator"));
    let darwin_tmp = resolved(&std::env::temp_dir());
    // No developer dir yet (Xcode missing) still needs a syntactically valid parameter; the run
    // fails on its own terms rather than on the profile.
    let xcode_app = resolved(Path::new(&xcode_app_root(context.developer_dir.unwrap_or("/Applications/Xcode.app"))));
    let mut wrapped = vec![
        "-f".to_owned(),
        profile_path.to_string_lossy().into_owned(),
        "-D".to_owned(),
        format!("HELPER_BUNDLE={helper_bundle}"),
        "-D".to_owned(),
        format!("USER_HOME={user_home}"),
        "-D".to_owned(),
        format!("CORESIM_HOME={core_sim_home}"),
        "-D".to_owned(),
        format!("CORESIM_LOGS={core_sim_logs}"),
        "-D".to_owned(),
        format!("DARWIN_TMP={darwin_tmp}"),
        "-D".to_owned(),
        format!("XCODE_APP={xcode_app}"),
        command.clone(),
    ];
    wrapped.extend(args.iter().cloned());
    HelperSandboxCommand { command: "/usr/bin/sandbox-exec".into(), args: wrapped, profile_path: Some(profile_path) }
}

/// The sandbox, appended to a failure message when it is a plausible cause. A denied rule does not
/// raise: CoreSimulator swallows it and the helper never answers, which looks exactly like a hung
/// helper, so a timeout under confinement names the profile and the way out.
pub fn describe_sandbox_suspicion(profile_path: Option<&Path>) -> String {
    let Some(profile_path) = profile_path else {
        return String::new();
    };
    format!(
        " The helper runs under the Seatbelt profile at {}, and a missing rule there stalls it instead of \
         erroring. Set {SANDBOX_OPT_OUT_ENV}=1 to run it unconfined and confirm whether the profile is the cause.",
        profile_path.display()
    )
}
