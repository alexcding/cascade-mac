//! Seatbelt confinement for the helper.
//!
//! Ported from `apps/server/src/device/helperSandbox.test.ts`. Synara passes the opt-out as an
//! environment object; here it is the value of `CASCADE_DEVICE_HELPER_NO_SANDBOX`, handed in.

use std::path::{Path, PathBuf};

use crate::device::sandbox::{
    describe_sandbox_suspicion, sandbox_disabled, sandboxed_helper_command, xcode_app_root, HelperSandboxContext,
    SANDBOX_OPT_OUT_ENV, SANDBOX_PROFILE_NAME,
};

const BINARY: &str = "/tmp/helper-cache/synara-device-helper";

/// The real profile, so these tests break if it is renamed or removed.
fn helper_source_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor/synara-device-helper")
}

fn context<'a>(source_dir: &'a Path, opt_out: Option<&'a str>) -> HelperSandboxContext<'a> {
    HelperSandboxContext {
        binary_path: Path::new(BINARY),
        helper_source_dir: source_dir,
        developer_dir: Some("/Applications/Xcode.app/Contents/Developer"),
        opt_out,
    }
}

fn argv(arguments: &[&str]) -> Vec<String> {
    arguments.iter().map(|argument| argument.to_string()).collect()
}

// xcodeAppRoot

#[test]
fn climbs_from_a_developer_dir_to_the_enclosing_app_bundle() {
    // The profile has to cover the whole bundle: the helper mmaps frameworks from all over it,
    // not just Contents/Developer.
    assert_eq!(xcode_app_root("/Applications/Xcode.app/Contents/Developer"), "/Applications/Xcode.app");
}

#[test]
fn handles_a_beta_or_a_relocated_xcode_not_just_applications() {
    assert_eq!(xcode_app_root("/Users/me/Xcode-beta.app/Contents/Developer"), "/Users/me/Xcode-beta.app");
}

#[test]
fn leaves_command_line_tools_alone_since_it_has_no_bundle() {
    // Covered by /Library/Developer in the profile instead.
    assert_eq!(xcode_app_root("/Library/Developer/CommandLineTools"), "/Library/Developer/CommandLineTools");
}

// the opt-out

#[test]
fn the_opt_out_is_off_unless_explicitly_set_to_something_truthy() {
    assert!(!sandbox_disabled(None));
    assert!(!sandbox_disabled(Some("")));
    assert!(!sandbox_disabled(Some("0")));
    assert!(!sandbox_disabled(Some("false")));
}

#[test]
fn the_opt_out_is_on_for_the_values_a_user_would_actually_type() {
    assert!(sandbox_disabled(Some("1")));
    assert!(sandbox_disabled(Some("true")));
}

#[test]
fn the_opt_out_is_named_for_cascade() {
    assert_eq!(SANDBOX_OPT_OUT_ENV, "CASCADE_DEVICE_HELPER_NO_SANDBOX");
}

// sandboxedHelperCommand

#[cfg(target_os = "macos")]
#[test]
fn wraps_the_helper_in_sandbox_exec_with_every_parameter_bound() {
    let source = helper_source_dir();
    let launch = sandboxed_helper_command(&argv(&[BINARY, "--probe"]), &context(&source, None));

    assert_eq!(launch.command, "/usr/bin/sandbox-exec");
    assert_eq!(launch.profile_path, Some(source.join(SANDBOX_PROFILE_NAME)));
    // An unbound parameter is not an error at load time; it silently matches nothing, so every
    // one the profile references must be passed.
    for name in ["HELPER_BUNDLE", "USER_HOME", "CORESIM_HOME", "CORESIM_LOGS", "DARWIN_TMP", "XCODE_APP"] {
        assert!(launch.args.iter().any(|arg| arg.starts_with(&format!("{name}="))), "{name} is not bound");
    }
    // The helper's own argv survives, last, so --probe still reaches it.
    assert_eq!(launch.args[launch.args.len() - 2], BINARY);
    assert_eq!(launch.args[launch.args.len() - 1], "--probe");
}

#[cfg(target_os = "macos")]
#[test]
fn binds_the_profile_file_and_the_xcode_bundle() {
    let source = helper_source_dir();
    let launch = sandboxed_helper_command(&argv(&[BINARY]), &context(&source, None));

    assert_eq!(launch.args[0], "-f");
    assert_eq!(launch.args[1], source.join(SANDBOX_PROFILE_NAME).to_string_lossy());
    let xcode = launch.args.iter().find_map(|arg| arg.strip_prefix("XCODE_APP=")).unwrap();
    assert!(xcode.ends_with("Xcode.app"), "{xcode}");
}

#[cfg(target_os = "macos")]
#[test]
fn resolves_darwin_tmp_through_symlinks() {
    // $TMPDIR is /var/folders/... which really lives at /private/var/folders/... Seatbelt matches
    // the real path, so an unresolved parameter would deny the frame socket and hang the video
    // path.
    let source = helper_source_dir();
    let launch = sandboxed_helper_command(&argv(&[BINARY]), &context(&source, None));

    let darwin_tmp = launch.args.iter().find_map(|arg| arg.strip_prefix("DARWIN_TMP=")).expect("DARWIN_TMP is bound");
    assert!(Path::new(darwin_tmp).is_absolute());
    if std::env::temp_dir().starts_with("/var/") {
        assert!(darwin_tmp.starts_with("/private/var/"), "{darwin_tmp}");
    }
}

#[test]
fn hands_back_the_plain_command_when_the_opt_out_is_set() {
    let source = helper_source_dir();
    let launch = sandboxed_helper_command(&argv(&[BINARY, "--probe"]), &context(&source, Some("1")));

    assert_eq!(launch.command, BINARY);
    assert_eq!(launch.args, argv(&["--probe"]));
    // No profile is what tells a later timeout not to blame the sandbox.
    assert_eq!(launch.profile_path, None);
}

#[test]
fn runs_unconfined_rather_than_failing_when_the_profile_is_missing() {
    // A packaging mistake should cost the confinement, not the whole feature.
    let empty = tempfile::tempdir().unwrap();
    let launch = sandboxed_helper_command(&argv(&[BINARY]), &context(empty.path(), None));
    assert_eq!(launch.command, BINARY);
    assert_eq!(launch.profile_path, None);

    let launch = sandboxed_helper_command(&argv(&[BINARY]), &context(Path::new("/nonexistent/device-helper"), None));
    assert_eq!(launch.command, BINARY);
    assert_eq!(launch.profile_path, None);
}

#[cfg(target_os = "macos")]
#[test]
fn confines_the_helper_when_the_profile_is_in_the_given_folder() {
    let folder = tempfile::tempdir().unwrap();
    std::fs::write(folder.path().join(SANDBOX_PROFILE_NAME), "(version 1)").unwrap();

    let launch = sandboxed_helper_command(&argv(&[BINARY, "--probe"]), &context(folder.path(), Some("0")));

    assert_eq!(launch.command, "/usr/bin/sandbox-exec");
    assert_eq!(launch.profile_path, Some(folder.path().join(SANDBOX_PROFILE_NAME)));
}

// describeSandboxSuspicion

#[test]
fn names_the_profile_and_the_way_out_because_a_denial_reads_as_a_hang() {
    let message = describe_sandbox_suspicion(Some(Path::new("/x/device-helper.sb")));
    assert!(message.contains("/x/device-helper.sb"));
    assert!(message.contains(SANDBOX_OPT_OUT_ENV));
}

#[test]
fn says_nothing_when_the_helper_was_not_confined() {
    // Blaming a sandbox that was never applied would send the reader the wrong way.
    assert_eq!(describe_sandbox_suspicion(None), "");
}
