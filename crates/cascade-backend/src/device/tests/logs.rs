//! Reading an app's logs and crash reports off a simulator.
//!
//! Ported from `apps/server/src/device/deviceLogs.test.ts`.

use std::{
    fs::File,
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::device::{
    backend::{DeviceLogLevel, DeviceLogQuery},
    logs::{parse_crash_report, read_crash_reports, tail_lines, unified_log_arguments},
};

const UDID: &str = "375CE30B-AC7C-4334-9059-59B6704D430E";

fn crash_report(proc_path: &str, signal: &str) -> String {
    let header = serde_json::json!({ "app_name": "Shop", "bug_type": "309" });
    let body = serde_json::json!({
        "procPath": proc_path,
        "exception": { "type": "EXC_CRASH", "signal": signal },
        "asi": { "libswiftCore.dylib": ["Fatal error: Unexpectedly found nil"] },
        "termination": { "indicator": "Abort trap: 6" },
    });
    format!("{header}\n{body}")
}

fn query(level: DeviceLogLevel) -> DeviceLogQuery {
    DeviceLogQuery {
        bundle_id: "com.example.shop".into(),
        since_seconds: 120,
        level,
        contains: None,
        limit: 50,
    }
}

fn write_aged(directory: &Path, name: &str, contents: &str, age_ms: u64) {
    let file = directory.join(name);
    std::fs::write(&file, contents).unwrap();
    File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_millis(age_ms))
        .unwrap();
}

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() * 1000.0
}

// unifiedLogArguments

#[test]
fn scopes_to_the_process_and_keeps_apple_subsystems_only_at_error_level() {
    let args = unified_log_arguments("Shop", &query(DeviceLogLevel::Default));

    assert_eq!(args[..5], ["show", "--last", "120s", "--style", "compact"]);
    assert_eq!(
        args.last().unwrap(),
        "process == \"Shop\" AND eventType == logEvent AND (NOT subsystem BEGINSWITH \"com.apple.\" OR messageType == error OR messageType == fault)"
    );
}

#[test]
fn adds_info_and_debug_flags_for_the_lower_levels() {
    assert!(unified_log_arguments("Shop", &query(DeviceLogLevel::Debug)).contains(&"--debug".to_owned()));
    assert!(unified_log_arguments("Shop", &query(DeviceLogLevel::Info)).contains(&"--info".to_owned()));
    assert!(unified_log_arguments("Shop", &query(DeviceLogLevel::Error))
        .last()
        .unwrap()
        .contains("(messageType == error OR messageType == fault)"));
}

#[test]
fn adds_no_level_flag_at_default_or_error() {
    for level in [DeviceLogLevel::Default, DeviceLogLevel::Error] {
        let args = unified_log_arguments("Shop", &query(level));
        assert!(!args.contains(&"--info".to_owned()));
        assert!(!args.contains(&"--debug".to_owned()));
    }
}

#[test]
fn escapes_quotes_in_the_executable_name() {
    assert!(unified_log_arguments("My \"App\"", &query(DeviceLogLevel::Error))
        .last()
        .unwrap()
        .contains("process == \"My \\\"App\\\"\""));
}

// tailLines

#[test]
fn keeps_the_newest_lines_and_cuts_long_ones() {
    let lines: Vec<String> = ["a", "b", "c"].iter().map(|line| line.to_string()).chain([ "x".repeat(600) ]).collect();

    let (kept, omitted) = tail_lines(&lines, 2);

    assert_eq!(omitted, 2);
    assert_eq!(kept[0], "c");
    assert_eq!(kept[1].chars().count(), 500);
}

#[test]
fn keeps_everything_when_there_are_fewer_lines_than_the_limit() {
    let lines = vec!["a".to_owned(), "b".to_owned()];
    assert_eq!(tail_lines(&lines, 10), (lines, 0));
}

// crash reports

#[test]
fn parses_the_exception_and_the_abort_message() {
    let parsed = parse_crash_report(&crash_report(&format!("/x/{UDID}/Shop.app/Shop"), "SIGABRT"));

    assert_eq!(parsed.exception.as_deref(), Some("EXC_CRASH (SIGABRT)"));
    assert_eq!(parsed.reason.as_deref(), Some("Fatal error: Unexpectedly found nil"));
}

#[test]
fn falls_back_to_the_termination_indicator_and_tolerates_unreadable_reports() {
    let body = serde_json::json!({ "termination": { "indicator": "Abort trap: 6" } });
    let parsed = parse_crash_report(&format!("{{}}\n{body}"));
    assert_eq!(parsed.reason.as_deref(), Some("Abort trap: 6"));
    assert_eq!(parsed.exception, None);

    let unreadable = parse_crash_report("not a report");
    assert_eq!(unreadable.proc_path, None);
    assert_eq!(unreadable.exception, None);
    assert_eq!(unreadable.reason, None);
}

#[test]
fn returns_only_recent_reports_for_this_simulator_newest_first() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path();
    let now = now_ms();
    let shop = format!("/d/{UDID}/Shop");
    write_aged(path, "Shop-2026-10-14-010101.ips", &crash_report(&shop, "SIGABRT"), 5_000);
    write_aged(path, "Shop-2026-10-14-010202.ips", &crash_report(&shop, "SIGSEGV"), 1_000);
    write_aged(path, "Shop-2026-10-13-000000.ips", &crash_report(&shop, "SIGABRT"), 3_600_000);
    write_aged(path, "Shop-other.ips", &crash_report("/d/OTHER-DEVICE/Shop", "SIGABRT"), 1_000);
    write_aged(path, "Mail-2026.ips", &crash_report(&format!("/d/{UDID}/Mail"), "SIGABRT"), 1_000);

    let reports = read_crash_reports(path, "Shop", UDID, now - 60_000.0);

    let names: Vec<String> = reports
        .iter()
        .map(|report| Path::new(&report.path).file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["Shop-2026-10-14-010202.ips", "Shop-2026-10-14-010101.ips"]);
    assert_eq!(reports[0].exception.as_deref(), Some("EXC_CRASH (SIGSEGV)"));
    assert!(reports[0].captured_at.ends_with('Z'));
}

#[test]
fn keeps_at_most_five_reports() {
    let directory = tempfile::tempdir().unwrap();
    let shop = format!("/d/{UDID}/Shop");
    for index in 0..7u64 {
        write_aged(directory.path(), &format!("Shop-{index}.ips"), &crash_report(&shop, "SIGABRT"), 1_000 + index * 100);
    }

    let reports = read_crash_reports(directory.path(), "Shop", UDID, 0.0);

    assert_eq!(reports.len(), 5);
}

#[test]
fn reads_nothing_from_a_directory_that_does_not_exist() {
    assert!(read_crash_reports(Path::new("/nonexistent/synara"), "Shop", UDID, 0.0).is_empty());
}
