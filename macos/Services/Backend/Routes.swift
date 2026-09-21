// The paths this app addresses the Rust backend on. Hand-maintained since the node
// generator was removed; `route_contract` in crates/craft-backend/src/lib.rs fails the
// build if a path here is not a route the backend serves.
import Foundation

public enum Routes {
    public static let BACKEND_HEALTH = "/api/backend/health"
    public static let CONFIG = "/api/config"
    public static let SETTINGS = "/api/settings"
    public static let SETTINGS_KEY = "/api/settings/:key"
    public static func settingsKey(_ value: String) -> String {
        "/api/settings/\(encodeComponent(value))"
    }
    public static let SOUNDS = "/api/sounds"
    public static let TABS = "/api/tabs"
    public static let TASKS = "/api/tasks"
    public static let TASK_PIN = "/api/tasks/:id/pin"
    public static let TASK = "/api/tasks/:id"
    public static func task(_ value: String) -> String {
        "/api/tasks/\(encodeComponent(value))"
    }
    public static func taskPin(_ value: String) -> String {
        "/api/tasks/\(encodeComponent(value))/pin"
    }
    public static let FILE = "/api/file"
    public static let FILES = "/api/files"
    public static let LAUNCH_TARGET = "/api/launch-target"
    public static let XCODE_SCHEMES = "/api/xcode/schemes"
    public static let XCODE_DESTINATIONS = "/api/xcode/destinations"
    public static let XCODE_BUILD_SETTINGS = "/api/xcode/build-settings"
    public static let PROJECTS = "/api/projects"
    public static let PROJECT = "/api/projects/:id"
    public static func project(_ value: String) -> String {
        "/api/projects/\(value)"
    }
    public static let PROJECT_PRS = "/api/projects/:id/prs"
    public static func projectPrs(_ value: String) -> String {
        "/api/projects/\(value)/prs"
    }
    public static let PROJECT_JIRA = "/api/projects/:id/jira"
    public static func projectJira(_ value: String) -> String {
        "/api/projects/\(value)/jira"
    }
    public static let PROJECT_BOARD = "/api/projects/:id/board"
    public static func projectBoard(_ value: String) -> String {
        "/api/projects/\(value)/board"
    }
    public static let PROJECT_FIXVERSION_PREVIEW = "/api/projects/:id/fixversion-preview"
    public static func projectFixversionPreview(_ value: String) -> String {
        "/api/projects/\(value)/fixversion-preview"
    }
    public static let DETECT_REPO = "/api/detect-repo"
    public static let WORKTREE = "/api/worktree"
    public static let WORKTREES = "/api/worktrees"
    public static let WORKTREE_REMOVE = "/api/worktree/remove"
    public static let WORKTREE_HOLDERS = "/api/worktree/holders"
    public static let DIFF = "/api/diff"
    public static let GIT_COMMIT = "/api/git/commit"
    public static let GIT_PUSH = "/api/git/push"
    public static let GIT_LOG = "/api/git/log"
    public static let GIT_REFS = "/api/git/refs"
    public static let GIT_SWITCH = "/api/git/switch"
    public static let GIT_COMMIT_AVATARS = "/api/git/commit-avatars"
    public static let GIT_SHOW = "/api/git/show"
    public static let GIT_DISCARD = "/api/git/discard"
    public static let PR_LOOKUP = "/api/prs/lookup"
    public static let PRS_TRAY = "/api/prs/tray"
    public static let PRS_VIEWED = "/api/prs/viewed"
    public static let DASHBOARD = "/api/dashboard"
    public static let JIRA_SITE = "/api/jira/site"
    public static let JIRA_SEARCH = "/api/jira/search"
    public static let JIRA_KEY_TRANSITION = "/api/jira/:key/transition"
    public static func jiraKeyTransition(_ value: String) -> String {
        "/api/jira/\(encodeComponent(value))/transition"
    }
    public static let JIRA_KEY_ASSIGN = "/api/jira/:key/assign"
    public static func jiraKeyAssign(_ value: String) -> String {
        "/api/jira/\(encodeComponent(value))/assign"
    }
    public static let LINKS = "/api/links"
    public static let LINK = "/api/links/:id"
    public static let WHOAMI = "/api/whoami"
    public static let USAGE = "/api/usage"
    public static let AGENT_CATALOG = "/api/agent/catalog"
    public static let AGENT_STATUS = "/api/agent/status"
    public static let AGENT_CONVERSATION = "/api/agent/conversation"
    public static let EVENTS = "/api/events"
    public static let LOGS = "/api/logs"
    public static let LOGS_CATEGORIES = "/api/logs/categories"
    public static let LOGS_CLEAR = "/api/logs/clear"
    public static let DB = "/api/db"
    public static let STREAM = "/api/stream"
    public static let FORWARDERS = "/api/forwarders"
    public static let WEBHOOK_GITHUB = "/webhook/github"
    public static let CLI_TOOLS = "/api/cli-tools"
    public static let AGENT_HOOKS = "/api/agent-hooks"
    public static let AGENT_HOOK = "/api/agent-hooks/:cli"
    public static func agentHook(_ value: String) -> String {
        "/api/agent-hooks/\(value)"
    }
    public static let HOOK_TURN_START = "/api/hooks/turn-start"
    public static let HOOK_TURN_DONE = "/api/hooks/turn-done"
    public static let HOOK_SESSION_START = "/api/hooks/session-start"
    public static let AGENT_ANALYZE = "/api/agent-analyze"

    private static func encodeComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }
}
