//! The slash commands a CLI offers in a worktree, for the chat's `/` suggestions. Each CLI is asked
//! nothing: its commands are read from the files it reads itself, beside the built-ins it ships.
//! The built-in lists are written down here, so a CLI release can add one before this list does.

use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Read,
    path::{Path, PathBuf},
};

/// One command as the chat offers it. `interactive`: sent without arguments it opens a panel in
/// the terminal rather than answering in the conversation.
struct Command {
    name: String,
    description: String,
    hint: String,
    source: &'static str,
    plugin: Option<String>,
    interactive: bool,
}

impl Command {
    fn json(&self) -> Value {
        json!({
            "name": self.name,
            "description": self.description,
            "hint": self.hint,
            "source": self.source,
            "plugin": self.plugin,
            "interactive": self.interactive,
        })
    }
}

/// `{"commands":[…]}`: the worktree's own first, then the person's, their plugins', and the
/// CLI's built-ins. A name offered twice keeps its first.
pub fn list(home: &Path, cli: &str, worktree: &Path) -> Value {
    let found = match cli {
        "codex" => codex(home),
        _ => claude(home, worktree),
    };
    let mut seen = HashSet::new();
    let commands: Vec<Value> = found
        .into_iter()
        .filter(|command| seen.insert(command.name.clone()))
        .map(|command| command.json())
        .collect();
    json!({ "commands": commands })
}

fn claude(home: &Path, worktree: &Path) -> Vec<Command> {
    let mut found = Vec::new();
    for (root, source) in [(worktree.join(".claude"), "project"), (home.join(".claude"), "user")] {
        found.extend(command_files(&root.join("commands"), source, None));
        found.extend(skills(&root.join("skills"), source, None));
    }
    found.extend(claude_plugins(home, worktree));
    found.extend(builtins(CLAUDE_BUILTINS));
    found
}

fn codex(home: &Path) -> Vec<Command> {
    // Codex offers its saved prompts under `prompts:`.
    let mut found: Vec<Command> = command_files(&home.join(".codex/prompts"), "user", None)
        .into_iter()
        .map(|command| Command { name: format!("prompts:{}", command.name), ..command })
        .collect();
    found.extend(builtins(CODEX_BUILTINS));
    found
}

/// Markdown commands, named by their file. Folders only group them in Claude Code's list; the
/// name is the file's own.
fn command_files(directory: &Path, source: &'static str, plugin: Option<&str>) -> Vec<Command> {
    let mut found = Vec::new();
    for path in markdown_files(directory, 3) {
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else { continue };
        let Some(text) = head(&path) else { continue };
        let (fields, body) = front_matter(&text);
        found.push(Command {
            name: plugin.map_or_else(|| stem.to_string(), |plugin| format!("{plugin}:{stem}")),
            description: fields.get("description").cloned().unwrap_or_else(|| first_line(body)),
            hint: fields.get("argument-hint").cloned().unwrap_or_default(),
            source,
            plugin: plugin.map(str::to_string),
            interactive: false,
        });
    }
    found
}

/// Skills, one folder each with its `SKILL.md`. A skill can be run by name like a command, unless
/// it says it is only the model's to use.
fn skills(directory: &Path, source: &'static str, plugin: Option<&str>) -> Vec<Command> {
    let Ok(entries) = fs::read_dir(directory) else { return Vec::new() };
    let mut folders: Vec<PathBuf> = entries.filter_map(Result::ok).map(|entry| entry.path()).collect();
    folders.sort();
    let mut found = Vec::new();
    for folder in folders.into_iter().take(LIMIT) {
        let Some(text) = head(&folder.join("SKILL.md")) else { continue };
        let (fields, body) = front_matter(&text);
        if fields.get("user-invocable").is_some_and(|value| value == "false") {
            continue;
        }
        let Some(name) = fields
            .get("name")
            .cloned()
            .or_else(|| folder.file_name().and_then(|n| n.to_str()).map(str::to_string))
        else {
            continue;
        };
        found.push(Command {
            name: plugin.map_or_else(|| name.clone(), |plugin| format!("{plugin}:{name}")),
            description: fields.get("description").cloned().unwrap_or_else(|| first_line(body)),
            hint: fields.get("argument-hint").cloned().unwrap_or_default(),
            source,
            plugin: plugin.map(str::to_string),
            interactive: false,
        });
    }
    found
}

/// Installed plugins' commands and skills, under the plugin's name. A plugin the person or the
/// project turned off in `enabledPlugins` is left out.
fn claude_plugins(home: &Path, worktree: &Path) -> Vec<Command> {
    let Some(installed) = read_json(&home.join(".claude/plugins/installed_plugins.json")) else {
        return Vec::new();
    };
    let mut enabled: HashMap<String, bool> = HashMap::new();
    for settings in [
        home.join(".claude/settings.json"),
        worktree.join(".claude/settings.json"),
        worktree.join(".claude/settings.local.json"),
    ] {
        if let Some(map) = read_json(&settings).and_then(|v| v["enabledPlugins"].as_object().cloned()) {
            for (key, on) in map {
                if let Some(on) = on.as_bool() {
                    enabled.insert(key, on);
                }
            }
        }
    }
    let Some(plugins) = installed["plugins"].as_object() else { return Vec::new() };
    let project = main_checkout(worktree);
    let mut keys: Vec<&String> = plugins.keys().collect();
    keys.sort();
    let mut found = Vec::new();
    for key in keys {
        if enabled.get(key) == Some(&false) {
            continue;
        }
        // One install per plugin in the first format, a list of them (one per scope) in the next.
        // An install for one project is offered only in that project's worktrees.
        let entry = &plugins[key];
        let installs = entry.as_array().map_or_else(|| vec![entry], |installs| installs.iter().collect());
        let Some(install) = installs.into_iter().find(|install| installed_for(install, &project)) else { continue };
        let Some(path) = install["installPath"].as_str() else { continue };
        let name = key.split('@').next().unwrap_or(key);
        let root = PathBuf::from(path);
        found.extend(command_files(&root.join("commands"), "plugin", Some(name)));
        found.extend(skills(&root.join("skills"), "plugin", Some(name)));
    }
    found
}

/// An install with no project of its own is everyone's; one made for a project, only its.
fn installed_for(install: &Value, project: &Path) -> bool {
    match install["projectPath"].as_str() {
        Some(path) if install["scope"] != "user" => Path::new(path) == project,
        _ => true,
    }
}

/// The checkout a worktree was added from, which is the project a plugin was installed for. A
/// linked worktree's `.git` is a file naming `<checkout>/.git/worktrees/<name>`.
fn main_checkout(worktree: &Path) -> PathBuf {
    fs::read_to_string(worktree.join(".git"))
        .ok()
        .and_then(|text| {
            let gitdir = text.lines().find_map(|line| line.strip_prefix("gitdir:"))?.trim().to_string();
            let (checkout, _) = gitdir.rsplit_once("/.git/worktrees/")?;
            Some(PathBuf::from(checkout))
        })
        .unwrap_or_else(|| worktree.to_path_buf())
}

/// `(name, description, hint, interactive)`.
type Builtin = (&'static str, &'static str, &'static str, bool);

const CLAUDE_BUILTINS: &[Builtin] = &[
    ("add-dir", "Add a new working directory", "<path>", false),
    ("agents", "Manage agent configurations", "", true),
    ("clear", "Clear conversation history and free up context", "", false),
    ("compact", "Clear conversation history but keep a summary in context", "[instructions]", false),
    ("config", "Open the settings panel", "", true),
    ("context", "Show current context usage", "", false),
    ("cost", "Show the total cost and duration of the current session", "", false),
    ("doctor", "Check the health of your Claude Code installation", "", true),
    ("export", "Export the current conversation", "[filename]", true),
    ("help", "Show help and available commands", "", true),
    ("hooks", "Manage hook configurations for tool events", "", true),
    ("init", "Initialize a new CLAUDE.md file with codebase documentation", "", false),
    ("mcp", "Manage MCP servers", "", true),
    ("memory", "Edit Claude memory files", "", true),
    ("model", "Set the AI model for Claude Code", "[model]", true),
    ("permissions", "Manage allow and deny tool permission rules", "", true),
    ("plugin", "Manage Claude Code plugins", "", true),
    ("pr-comments", "Get comments from a GitHub pull request", "", false),
    ("release-notes", "View release notes", "", true),
    ("resume", "Resume a conversation", "", true),
    ("review", "Review a pull request", "", false),
    ("rewind", "Restore the code and/or conversation to a previous point", "", true),
    ("security-review", "Complete a security review of the pending changes on the current branch", "", false),
    ("status", "Show Claude Code status", "", true),
    ("todos", "List current todo items", "", false),
    ("usage", "Show plan usage limits", "", true),
    ("vim", "Toggle between Vim and Normal editing modes", "", false),
];

const CODEX_BUILTINS: &[Builtin] = &[
    ("model", "Choose what model and reasoning effort to use", "", true),
    ("approvals", "Choose what Codex can do without approval", "", true),
    ("review", "Review my current changes and find issues", "", true),
    ("new", "Start a new chat during a conversation", "", false),
    ("init", "Create an AGENTS.md file with instructions for Codex", "", false),
    ("compact", "Summarize the conversation to prevent hitting the context limit", "", false),
    ("diff", "Show git diff, including untracked files", "", true),
    ("status", "Show current session configuration and token usage", "", true),
    ("mcp", "List configured MCP tools", "", true),
];

fn builtins(list: &[Builtin]) -> impl Iterator<Item = Command> + '_ {
    list.iter().map(|&(name, description, hint, interactive)| Command {
        name: name.to_string(),
        description: description.to_string(),
        hint: hint.to_string(),
        source: "builtin",
        plugin: None,
        interactive,
    })
}

/// Enough for any one person's commands; a stray huge folder is not walked to its end.
const LIMIT: usize = 400;

fn markdown_files(directory: &Path, depth: usize) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![(directory.to_path_buf(), 0)];
    'walk: while let Some((folder, level)) = pending.pop() {
        let Ok(entries) = fs::read_dir(&folder) else { continue };
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            // Through links: a dotfiles manager keeps commands as links to its own tree. The
            // depth limit keeps a link back up the tree from walking forever.
            let Ok(kind) = fs::metadata(&path) else { continue };
            if kind.is_dir() && level + 1 < depth {
                pending.push((path, level + 1));
            } else if kind.is_file() && path.extension().is_some_and(|e| e == "md") {
                found.push(path);
                if found.len() >= LIMIT {
                    break 'walk;
                }
            }
        }
    }
    found.sort();
    found
}

/// The start of a file: front matter and a first line are all a list needs.
fn head(path: &Path) -> Option<String> {
    let mut bytes = Vec::new();
    fs::File::open(path).ok()?.take(8 * 1024).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

/// The `key: value` lines of a leading `---` block, and the text after it. A folded value (`>` or
/// `|`) takes the indented lines under it, joined.
fn front_matter(text: &str) -> (HashMap<String, String>, &str) {
    let mut fields = HashMap::new();
    let Some(rest) = text.strip_prefix("---").filter(|rest| rest.starts_with(['\n', '\r'])) else {
        return (fields, text);
    };
    let Some(end) = rest.find("\n---") else { return (fields, text) };
    let block = &rest[..end];
    let body = rest[end + 4..].split_once('\n').map_or("", |(_, body)| body);
    let mut lines = block.lines().peekable();
    while let Some(line) = lines.next() {
        let Some((key, value)) = line.split_once(':') else { continue };
        if key.starts_with([' ', '\t']) || key.trim().is_empty() {
            continue;
        }
        let mut value = value.trim().to_string();
        if value.is_empty() || value == ">" || value == "|" || value == ">-" || value == "|-" {
            let mut folded = Vec::new();
            while let Some(next) = lines.peek() {
                if !next.starts_with([' ', '\t']) {
                    break;
                }
                folded.push(next.trim());
                lines.next();
            }
            value = folded.join(" ");
        }
        let unquoted = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .map(str::to_string)
            .unwrap_or(value);
        fields.insert(key.trim().to_string(), unquoted);
    }
    (fields, body)
}

/// A command with no description is described by its first line of text, as Claude Code does.
fn first_line(body: &str) -> String {
    let line = body
        .lines()
        .map(|line| line.trim().trim_start_matches('#').trim())
        .find(|line| !line.is_empty())
        .unwrap_or("");
    line.chars().take(160).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("cascade-commands-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write(path: PathBuf, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn names(value: &Value) -> Vec<String> {
        value["commands"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn claude_lists_the_projects_the_persons_plugins_and_builtins_in_that_order() {
        let root = scratch("claude");
        let (home, worktree) = (root.join("home"), root.join("worktree"));
        write(
            worktree.join(".claude/commands/frontend/ship.md"),
            "---\ndescription: \"Ship it\"\nargument-hint: <branch>\n---\nBody\n",
        );
        write(home.join(".claude/commands/standup.md"), "# Write my standup\n\nMore.\n");
        write(
            home.join(".claude/skills/pdf/SKILL.md"),
            "---\nname: pdf\ndescription: >\n  Work with\n  PDF files\n---\n",
        );
        write(home.join(".claude/skills/quiet/SKILL.md"), "---\nname: quiet\nuser-invocable: false\n---\n");
        let plugin = root.join("plugin");
        write(plugin.join("commands/deploy.md"), "---\ndescription: Deploy\n---\n");
        let off = root.join("off");
        write(off.join("commands/hidden.md"), "Hidden\n");
        write(
            home.join(".claude/plugins/installed_plugins.json"),
            &json!({"version": 2, "plugins": {
                "tools@market": [{"scope": "user", "installPath": plugin}],
                "off@market": [{"scope": "user", "installPath": off}],
            }})
            .to_string(),
        );
        write(home.join(".claude/settings.json"), r#"{"enabledPlugins": {"off@market": false}}"#);

        let listed = list(&home, "claude", &worktree);
        let found = names(&listed);
        assert_eq!(&found[..4], ["ship", "standup", "pdf", "tools:deploy"]);
        assert!(found.contains(&"compact".to_string()) && !found.contains(&"quiet".to_string()));
        assert!(!found.iter().any(|name| name.contains("hidden")), "a turned-off plugin is left out");
        let commands = listed["commands"].as_array().unwrap();
        assert_eq!(commands[0]["description"], "Ship it");
        assert_eq!(commands[0]["hint"], "<branch>");
        assert_eq!(commands[0]["source"], "project");
        assert_eq!(commands[1]["description"], "Write my standup");
        assert_eq!(commands[2]["description"], "Work with PDF files");
        assert_eq!(commands[3]["plugin"], "tools");
        let model = commands.iter().find(|c| c["name"] == "model").unwrap();
        assert_eq!(model["interactive"], true);
    }

    #[test]
    fn linked_commands_are_listed() {
        let root = scratch("links");
        write(root.join("dotfiles/standup.md"), "Write my standup\n");
        write(root.join("dotfiles/team/triage.md"), "Triage\n");
        let commands = root.join("home/.claude/commands");
        fs::create_dir_all(&commands).unwrap();
        std::os::unix::fs::symlink(root.join("dotfiles/standup.md"), commands.join("standup.md")).unwrap();
        std::os::unix::fs::symlink(root.join("dotfiles/team"), commands.join("team")).unwrap();
        let found = names(&list(&root.join("home"), "claude", &root.join("worktree")));
        assert!(found.contains(&"standup".to_string()) && found.contains(&"triage".to_string()));
    }

    #[test]
    fn a_plugin_installed_for_one_project_is_offered_only_in_its_worktrees() {
        let root = scratch("scoped");
        let (home, project, other) = (root.join("home"), root.join("project"), root.join("other"));
        let worktree = root.join("worktrees/feature");
        write(worktree.join(".git"), &format!("gitdir: {}/.git/worktrees/feature\n", project.display()));
        fs::create_dir_all(&other).unwrap();
        let plugin = root.join("plugin");
        write(plugin.join("commands/deploy.md"), "Deploy\n");
        write(
            home.join(".claude/plugins/installed_plugins.json"),
            &json!({"version": 2, "plugins": {
                "tools@market": [{"scope": "project", "projectPath": project, "installPath": plugin}],
            }})
            .to_string(),
        );
        assert!(names(&list(&home, "claude", &worktree)).contains(&"tools:deploy".to_string()));
        assert!(names(&list(&home, "claude", &project)).contains(&"tools:deploy".to_string()));
        assert!(!names(&list(&home, "claude", &other)).contains(&"tools:deploy".to_string()));
    }

    #[test]
    fn a_project_command_keeps_its_name_over_a_builtin() {
        let root = scratch("override");
        write(root.join("worktree/.claude/commands/review.md"), "Our review\n");
        let listed = list(&root.join("home"), "claude", &root.join("worktree"));
        let reviews: Vec<&Value> =
            listed["commands"].as_array().unwrap().iter().filter(|c| c["name"] == "review").collect();
        assert_eq!(reviews.len(), 1);
        assert_eq!(reviews[0]["source"], "project");
    }

    #[test]
    fn codex_offers_saved_prompts_under_prompts() {
        let root = scratch("codex");
        write(root.join(".codex/prompts/triage.md"), "---\ndescription: Triage an issue\n---\n");
        let listed = list(&root, "codex", &root.join("worktree"));
        let found = names(&listed);
        assert_eq!(found[0], "prompts:triage");
        assert!(found.contains(&"approvals".to_string()));
        assert!(!found.contains(&"add-dir".to_string()), "Claude's built-ins are not Codex's");
    }
}
