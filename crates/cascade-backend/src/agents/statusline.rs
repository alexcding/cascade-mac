//! Installing Cascade's Claude Code status line for every session, not only the ones the app
//! launches. Claude Code reports its real context window only to its status line, so a session
//! started by hand has no percentage until this is installed. It rides beside the workflow hooks:
//! one more entry in the same status map, installed and removed through the same routes.

use crate::{
    cli::shell_quote,
    error::ApiError,
    settings_file::{read_json, write_json},
};
use serde_json::{json, Value};
use std::{fs, path::{Path, PathBuf}};

/// The name this goes by in the hook status map and the install route.
pub const KEY: &str = "claude-statusline";
const SCRIPT_NAME: &str = "cascade-statusline.sh";
/// The same script the app bundles for the sessions it launches.
const SCRIPT: &str = include_str!("../../../../macos/Resources/AgentStatusLine/cascade-statusline.sh");
/// Seconds between runs besides Claude Code's own: it does not rerun the line when the terminal is
/// resized, and the line is laid out to the width it is given. The app's launches pass the same.
const REFRESH_INTERVAL: u64 = 2;

fn home() -> Result<PathBuf, ApiError> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| ApiError::bad_request("Home directory is unavailable"))
}

fn support(home: &PathBuf) -> PathBuf {
    home.join("Library/Application Support/Cascade")
}

fn is_ours(line: &Value) -> bool {
    line["command"].as_str().is_some_and(|command| command.contains(SCRIPT_NAME))
}

pub fn status() -> String {
    let installed = home()
        .ok()
        .and_then(|home| read_json(&home.join(".claude/settings.json")))
        .is_some_and(|settings| is_ours(&settings["statusLine"]));
    if installed { "installed" } else { "absent" }.into()
}

/// The installed line, brought up to date at each start: it is written only on install, so an app
/// that changed what the line draws, or how often, would otherwise leave the old one in place. Only
/// where it is installed, and only our own `statusLine` entry and script.
///
/// Only by the app on the default data folder, the one whose folder the script lives in: a
/// development build runs on a folder of its own, and must not swap its script in under the
/// installed app's sessions at each start.
pub fn refresh(data_dir: &Path) {
    let Ok(home) = home() else { return };
    if data_dir != support(&home) { return; }
    refresh_in(&home);
}

fn refresh_in(home: &PathBuf) {
    let Some(settings) = read_json(&home.join(".claude/settings.json")) else { return };
    let line = &settings["statusLine"];
    if !is_ours(line) { return; }
    // Claude's settings only when our entry has no interval at all: one the person set is theirs.
    if line.get("refreshInterval").is_none() {
        let _ = change_in(home, true);
        return;
    }
    let script = support(home).join(SCRIPT_NAME);
    if fs::read_to_string(&script).ok().as_deref() != Some(SCRIPT) { let _ = fs::write(&script, SCRIPT); }
}

pub fn change(install: bool) -> Result<(), ApiError> {
    change_in(&home()?, install)
}

/// The user's own status line is set aside on install, drawn by the script while ours is in
/// place, and put back on removal. Only the `statusLine` key is ever touched.
fn change_in(home: &PathBuf, install: bool) -> Result<(), ApiError> {
    let file = home.join(".claude/settings.json");
    let mut settings: Value = match fs::read_to_string(&file) {
        Ok(raw) => serde_json::from_str(&raw).map_err(|_| {
            ApiError::bad_request(format!(
                "Cannot update the status line: {} contains invalid JSON. The file was not changed.",
                file.display()
            ))
        })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => json!({}),
        Err(error) => return Err(ApiError::internal(error)),
    };
    if !settings.is_object() {
        return Err(ApiError::bad_request(format!(
            "Cannot update the status line: {} has an unsupported configuration shape. The file was not changed.",
            file.display()
        )));
    }
    let support = support(home);
    let kept = support.join("statusline/original.json");
    if install {
        fs::create_dir_all(support.join("statusline")).map_err(ApiError::internal)?;
        let script = support.join(SCRIPT_NAME);
        fs::write(&script, SCRIPT).map_err(ApiError::internal)?;
        if !is_ours(&settings["statusLine"]) {
            if settings["statusLine"].is_object() {
                write_json(&kept, &settings["statusLine"])?;
            } else {
                let _ = fs::remove_file(&kept);
            }
        }
        // An interval the person set on our entry is kept.
        let interval = settings["statusLine"].get("refreshInterval").filter(|_| is_ours(&settings["statusLine"]))
            .cloned().unwrap_or(json!(REFRESH_INTERVAL));
        settings["statusLine"] = json!({"type":"command",
            "command":format!("/bin/sh {}", shell_quote(&script.to_string_lossy())),
            "refreshInterval":interval});
    } else if is_ours(&settings["statusLine"]) {
        match read_json(&kept) {
            Some(original) => settings["statusLine"] = original,
            None => {
                settings.as_object_mut().map(|map| map.remove("statusLine"));
            }
        }
        let _ = fs::remove_file(&kept);
    } else {
        return Ok(());
    }
    write_json(&file, &settings)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The app's launches pass the interval the backend installs.
    #[test]
    fn the_app_launches_with_the_same_refresh_interval() {
        let driver = include_str!("../../../../macos/Services/Agents/AgentDriver.swift");
        assert!(driver.contains(&format!("static let refreshInterval = {REFRESH_INTERVAL}\n")));
    }

    /// An install from before the interval gains it at the next start; one the person changed is
    /// kept, and so is the script once current.
    #[test]
    fn refresh_adds_the_interval_and_keeps_one_the_person_set() {
        let home = std::env::temp_dir().join(format!("cascade-statusline-refresh-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let file = home.join(".claude/settings.json");
        let script = support(&home).join(SCRIPT_NAME);
        let command = format!("/bin/sh {}", shell_quote(&script.to_string_lossy()));
        fs::write(&file, json!({"statusLine":{"type":"command","command":command}}).to_string()).unwrap();
        refresh_in(&home);
        assert_eq!(read_json(&file).unwrap()["statusLine"]["refreshInterval"], REFRESH_INTERVAL);
        assert_eq!(fs::read_to_string(&script).unwrap(), SCRIPT);

        fs::write(&file, json!({"statusLine":{"type":"command","command":command,"refreshInterval":10}}).to_string()).unwrap();
        fs::write(&script, "old").unwrap();
        refresh_in(&home);
        assert_eq!(read_json(&file).unwrap()["statusLine"]["refreshInterval"], 10);
        assert_eq!(fs::read_to_string(&script).unwrap(), SCRIPT);
        change_in(&home, true).unwrap();
        assert_eq!(read_json(&file).unwrap()["statusLine"]["refreshInterval"], 10, "a reinstall keeps it too");
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn install_keeps_the_users_status_line_and_removal_restores_it() {
        let home = std::env::temp_dir().join(format!("cascade-statusline-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let file = home.join(".claude/settings.json");
        let own = json!({"type":"command","command":"bun x ccusage statusline","padding":0});
        fs::write(&file, json!({"model":"fable","statusLine":own}).to_string()).unwrap();

        change_in(&home, true).unwrap();
        change_in(&home, true).unwrap();
        let installed = read_json(&file).unwrap();
        assert!(is_ours(&installed["statusLine"]));
        assert_eq!(installed["statusLine"]["refreshInterval"], REFRESH_INTERVAL);
        assert_eq!(installed["model"], "fable");
        assert_eq!(read_json(&support(&home).join("statusline/original.json")).unwrap(), own);
        assert!(support(&home).join(SCRIPT_NAME).is_file());

        change_in(&home, false).unwrap();
        let removed = read_json(&file).unwrap();
        assert_eq!(removed["statusLine"], own);
        assert!(!support(&home).join("statusline/original.json").exists());

        fs::write(&file, json!({"model":"fable"}).to_string()).unwrap();
        change_in(&home, true).unwrap();
        change_in(&home, false).unwrap();
        assert_eq!(read_json(&file).unwrap(), json!({"model":"fable"}));
        fs::remove_dir_all(&home).unwrap();
    }

    /// With no status line of the user's, the script draws one line across the terminal: the model
    /// its context and the cost on the left; on the right the plan's limits left and when they
    /// reset, as many as fit.
    #[test]
    fn with_none_of_the_users_the_script_names_the_model_and_the_context() {
        use std::{io::Write, process::{Command, Stdio}};
        let home = std::env::temp_dir().join(format!("cascade-statusline-line-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&home).unwrap();
        let script = home.join(SCRIPT_NAME);
        fs::write(&script, SCRIPT).unwrap();
        // Drawn for a task at a given width and locale, its colours taken out.
        let draw_in = |task: &str, input: &Value, columns: usize, locale: &str| {
            let mut child = Command::new("/bin/sh").arg(&script).arg(task).env("HOME", &home)
                .env("COLUMNS", columns.to_string()).env("LC_ALL", locale)
                .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
            child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
            let raw = String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap();
            let mut plain = String::new();
            let mut chars = raw.chars();
            while let Some(c) = chars.next() {
                if c == '\u{1b}' { chars.by_ref().find(|c| *c == 'm'); } else { plain.push(c); }
            }
            plain
        };
        let draw = |input: &Value, columns: usize| draw_in("task-1", input, columns, "en_US.UTF-8");
        let full = json!({"model":{"id":"claude-opus-4-7","display_name":"Opus 4.7"},"effort":{"level":"high"},
            "context_window":{"context_window_size":200_000,
                "current_usage":{"input_tokens":2,"cache_creation_input_tokens":1_000,"cache_read_input_tokens":83_000}}});
        assert_eq!(draw(&full, 80), "Opus 4.7 · high · 84k / 200k (42%)\n");
        assert!(support(&home).join("statusline/task-1.json").is_file(), "the app's copy is still kept");

        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        let mut spent = full.clone();
        spent["cost"] = json!({"total_cost_usd":8.504692,"total_duration_ms":3_906_789});
        spent["rate_limits"] = json!({"five_hour":{"used_percentage":2,"resets_at":now + 7_830},
            "seven_day":{"used_percentage":48}});
        // Right-aligned to the edge, 4 columns kept for Claude Code's indent.
        let wide = draw(&spent, 140);
        assert!(wide.starts_with("Opus 4.7 · high · 84k / 200k (42%) · $8.50  "), "{wide}");
        assert!(wide.ends_with("  session 98% left (2h11m) · week 52% left\n"), "{wide}");
        assert_eq!(wide.trim_end().chars().count(), 136, "{wide}");
        // Run again on the timer with nothing new but the run's duration: the line kept is drawn.
        let kept = support(&home).join("statusline/.task-1.line");
        let stamp = fs::read_to_string(&kept).unwrap().lines().next().unwrap().to_string();
        fs::write(&kept, format!("{stamp}\nkept\n")).unwrap();
        let mut later = spent.clone();
        later["cost"]["total_duration_ms"] = json!(3_908_789);
        assert_eq!(draw(&later, 140), "kept\n");
        // A new width is drawn afresh.
        assert_ne!(draw(&later, 141), "kept\n");
        // A locale whose decimal mark is a comma still reads the cost.
        assert!(draw_in("task-2", &spent, 140, "de_DE.UTF-8").contains(" · $8.50  "));
        // Limits are rounded, and never below nothing left.
        let mut over = full.clone();
        over["rate_limits"] = json!({"five_hour":{"used_percentage":48.5},"seven_day":{"used_percentage":105}});
        assert!(draw(&over, 140).ends_with("  session 51% left · week 0% left\n"));
        // Narrow: what fits, in order, still at the edge; nothing when none does.
        let narrow = draw(&spent, 72);
        assert!(narrow.ends_with("  session 98% left (2h11m)\n"), "{narrow}");
        assert_eq!(narrow.trim_end().chars().count(), 68, "{narrow}");
        assert_eq!(draw(&spent, 50), "Opus 4.7 · high · 84k / 200k (42%) · $8.50\n");

        let fresh = json!({"model":{"id":"claude-fable-5-1"},"context_window":{"context_window_size":1_000_000,"current_usage":null}});
        assert_eq!(draw(&fresh, 80), "claude-fable-5-1\n");
        fs::remove_dir_all(&home).unwrap();
    }
}
