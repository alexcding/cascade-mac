//! Reading an app's logs and crash reports off a simulator.
//!
//! Port of Synara's `apps/server/src/device/deviceLogs.ts`. Two sources:
//!
//! - The unified log (`log show` inside the simulator): os_log, Logger, NSLog, and the frameworks'
//!   own errors about the app. Direct stdout capture is deliberately unavailable: files or pipes
//!   whose readers disappear could affect the app, and `print` is not unified logging.
//! - Crash reports, which the host writes to `~/Library/Logs/DiagnosticReports` as
//!   `<executable>-<timestamp>.ips` roughly a minute after the crash.
//!
//! Everything returned is the app's own output: data for the agent to weigh, never instructions.

use std::{path::Path, time::UNIX_EPOCH};

use serde_json::Value;

use super::backend::{DeviceCrashReport, DeviceLogLevel, DeviceLogQuery};

/// One log line is a message, not a document; longer ones are cut.
const MAX_LINE_LENGTH: usize = 500;
const MAX_CRASH_REPORTS: usize = 5;
const MAX_CRASH_REPORT_BYTES: u64 = 4 * 1024 * 1024;

/// The arguments after `simctl spawn <udid> log`. Apple's own subsystems are left out below error
/// level: a SwiftUI app logs hundreds of RunningBoard and UIKit lifecycle lines a minute, which
/// bury the app's own messages; their errors and faults stay, since those are usually about the
/// app. Activity and signpost events are left out for the same reason.
pub fn unified_log_arguments(executable: &str, query: &DeviceLogQuery) -> Vec<String> {
    let process = format!("process == \"{}\"", escape_predicate_string(executable));
    let level_flags: &[&str] = match query.level {
        DeviceLogLevel::Debug => &["--info", "--debug"],
        DeviceLogLevel::Info => &["--info"],
        DeviceLogLevel::Error | DeviceLogLevel::Default => &[],
    };
    let scope = match query.level {
        DeviceLogLevel::Error => "(messageType == error OR messageType == fault)",
        _ => "(NOT subsystem BEGINSWITH \"com.apple.\" OR messageType == error OR messageType == fault)",
    };
    let mut args = vec![
        "show".to_owned(),
        "--last".to_owned(),
        format!("{}s", query.since_seconds.max(1)),
        "--style".to_owned(),
        "compact".to_owned(),
    ];
    args.extend(level_flags.iter().map(|flag| flag.to_string()));
    args.push("--predicate".to_owned());
    args.push(format!("{process} AND eventType == logEvent AND {scope}"));
    args
}

fn escape_predicate_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

/// The newest `limit` lines, each cut to a readable length, and how many were dropped.
pub fn tail_lines(lines: &[String], limit: usize) -> (Vec<String>, usize) {
    let kept = &lines[lines.len().saturating_sub(limit)..];
    let kept: Vec<String> = kept
        .iter()
        .map(|line| {
            if line.chars().count() > MAX_LINE_LENGTH {
                let mut cut: String = line.chars().take(MAX_LINE_LENGTH - 1).collect();
                cut.push('…');
                cut
            } else {
                line.clone()
            }
        })
        .collect();
    let omitted = lines.len() - kept.len();
    (kept, omitted)
}

/// Crash reports for `executable` written since `since_ms`, newest first. A macOS process with the
/// same executable name writes to the same folder, so a report whose process path names another
/// simulator (or none) is skipped.
pub fn read_crash_reports(directory: &Path, executable: &str, udid: &str, since_ms: f64) -> Vec<DeviceCrashReport> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let prefix = format!("{executable}-");
    let mut reports: Vec<(f64, DeviceCrashReport)> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with(&prefix) || !name.ends_with(".ips") {
            continue;
        }
        let file = directory.join(&name);
        let Ok(info) = std::fs::metadata(&file) else { continue };
        let Some(modified_ms) = info
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|elapsed| elapsed.as_secs_f64() * 1000.0)
        else {
            continue;
        };
        if modified_ms < since_ms || info.len() > MAX_CRASH_REPORT_BYTES {
            continue;
        }
        let text = std::fs::read(&file).map(|bytes| String::from_utf8_lossy(&bytes).into_owned()).unwrap_or_default();
        let parsed = parse_crash_report(&text);
        if parsed.proc_path.as_deref().is_some_and(|proc_path| !proc_path.contains(udid)) {
            continue;
        }
        reports.push((
            modified_ms,
            DeviceCrashReport {
                path: file.to_string_lossy().into_owned(),
                captured_at: super::iso_from_millis(modified_ms as i64),
                exception: parsed.exception,
                reason: parsed.reason,
            },
        ));
    }
    reports.sort_by(|a, b| b.0.total_cmp(&a.0));
    reports.into_iter().take(MAX_CRASH_REPORTS).map(|(_, report)| report).collect()
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ParsedCrashReport {
    pub proc_path: Option<String>,
    pub exception: Option<String>,
    pub reason: Option<String>,
}

/// An `.ips` report is a one-line JSON header followed by a JSON body. Only the fields that
/// answer "why did it crash" are read; anything unparseable leaves them empty.
pub fn parse_crash_report(text: &str) -> ParsedCrashReport {
    let body = text
        .find('\n')
        .and_then(|newline| serde_json::from_str::<Value>(&text[newline + 1..]).ok())
        .filter(Value::is_object)
        .unwrap_or(Value::Null);
    let exception = body.get("exception").filter(|value| value.is_object());
    let kind = exception.and_then(|value| value.get("type")).and_then(Value::as_str);
    let signal = exception.and_then(|value| value.get("signal")).and_then(Value::as_str);
    let asi_message = body
        .get("asi")
        .and_then(Value::as_object)
        .and_then(|asi| asi.values().filter_map(Value::as_array).flatten().find_map(Value::as_str));
    let indicator = body
        .get("termination")
        .filter(|value| value.is_object())
        .and_then(|termination| termination.get("indicator"))
        .and_then(Value::as_str);
    ParsedCrashReport {
        proc_path: body.get("procPath").and_then(Value::as_str).map(str::to_owned),
        exception: match (kind, signal) {
            (None, signal) => signal.map(str::to_owned),
            (Some(kind), None) => Some(kind.to_owned()),
            (Some(kind), Some(signal)) => Some(format!("{kind} ({signal})")),
        },
        reason: asi_message.or(indicator).map(str::to_owned),
    }
}
