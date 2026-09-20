//! Installing Craft's Claude Code status line for every session, not only the ones the app
//! launches. Claude Code reports its real context window only to its status line, so a session
//! started by hand has no percentage until this is installed. It rides beside the workflow hooks:
//! one more entry in the same status map, installed and removed through the same routes.

use crate::{
    error::ApiError,
    integrations::{read_json, shell_quote, write_json},
};
use serde_json::{json, Value};
use std::{fs, path::PathBuf};

/// The name this goes by in the hook status map and the install route.
pub const KEY: &str = "claude-statusline";
const SCRIPT_NAME: &str = "craft-statusline.sh";
/// The same script the app bundles for the sessions it launches.
const SCRIPT: &str = include_str!("../../../../macos/Resources/AgentStatusLine/craft-statusline.sh");

fn home() -> Result<PathBuf, ApiError> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| ApiError::bad_request("Home directory is unavailable"))
}

fn support(home: &PathBuf) -> PathBuf {
    home.join("Library/Application Support/Craft")
}

/// The script's name when the app was called TaskHub. A status line installed back then is still
/// ours: replacing it must not file it away as the user's original.
const LEGACY_SCRIPT_NAME: &str = "taskhub-statusline.sh";

fn is_ours(line: &Value) -> bool {
    line["command"]
        .as_str()
        .is_some_and(|command| command.contains(SCRIPT_NAME) || command.contains(LEGACY_SCRIPT_NAME))
}

pub fn status() -> String {
    let installed = home()
        .ok()
        .and_then(|home| read_json(&home.join(".claude/settings.json")))
        .is_some_and(|settings| is_ours(&settings["statusLine"]));
    if installed { "installed" } else { "absent" }.into()
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
        settings["statusLine"] = json!({"type":"command",
            "command":format!("/bin/sh {}", shell_quote(&script.to_string_lossy()))});
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

    #[test]
    fn a_status_line_installed_under_the_old_name_is_replaced_not_kept_as_the_original() {
        let home = std::env::temp_dir().join(format!("craft-statusline-legacy-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let file = home.join(".claude/settings.json");
        let legacy = json!({"type":"command",
            "command":"/bin/sh '/Users/x/Library/Application Support/TaskHub/taskhub-statusline.sh'"});
        fs::write(&file, json!({"statusLine":legacy}).to_string()).unwrap();

        change_in(&home, true).unwrap();
        let installed = read_json(&file).unwrap();
        assert!(installed["statusLine"]["command"].as_str().unwrap().contains(SCRIPT_NAME));
        assert!(!support(&home).join("statusline/original.json").exists());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn install_keeps_the_users_status_line_and_removal_restores_it() {
        let home = std::env::temp_dir().join(format!("craft-statusline-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(home.join(".claude")).unwrap();
        let file = home.join(".claude/settings.json");
        let own = json!({"type":"command","command":"bun x ccusage statusline","padding":0});
        fs::write(&file, json!({"model":"fable","statusLine":own}).to_string()).unwrap();

        change_in(&home, true).unwrap();
        change_in(&home, true).unwrap();
        let installed = read_json(&file).unwrap();
        assert!(is_ours(&installed["statusLine"]));
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
}
