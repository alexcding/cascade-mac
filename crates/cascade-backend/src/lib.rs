mod agents;
mod automation;
pub mod chat;
pub mod cli;
mod db;
mod domain;
mod error;
pub mod event;
mod fork;
pub mod ffi;
mod github;
mod http_client;
mod integrations;
mod issues;
mod jira;
mod kept;
mod local;
mod poller;
pub mod recovery;
mod routes;
mod sessions;
mod settings_file;
mod sim_preview;
mod tickets;
mod usage;
mod warmup;
mod worktrees;
mod xcode;

use std::sync::Arc;

use axum::{
    extract::DefaultBodyLimit,
    http::{header, HeaderValue},
    routing::{delete, get, patch, post},
    Router,
};
pub use db::Database;
pub use domain::{Fault, PrSnapshot, Project, Session};
pub use event::Event;
use serde_json::Value;
use tokio::sync::broadcast;
use tower_http::{set_header::SetResponseHeaderLayer, trace::TraceLayer};

#[derive(Clone)]
pub struct AppState {
    pub db: Arc<Database>,
    pub events: broadcast::Sender<Value>,
    pub instance_id: Option<String>,
    pub poller: poller::Poller,
    pub forwarders: integrations::ForwarderManager,
    pub permissions: agents::permission::Permissions,
    pub limits: Arc<automation::Limits>,
    pub usage: Arc<usage::Usage>,
    pub warmup: Arc<warmup::Warmup>,
    pub fetches: Arc<worktrees::Fetches>,
    pub kept: Arc<kept::Kept>,
    /// The chat engine, once `chat::start` has started it.
    pub chat: Arc<chat::Chat>,
}

/// How many events the broadcast keeps for a subscriber that has not read them yet. A chat thread
/// streams its turn as `chat-thread` events, a delta at a time, so a long answer or a few chats at
/// once publish hundreds in a burst; a subscriber that falls this far behind is sent `reload`
/// (`ffi.rs`, the SSE route) and reads everything again, which a deep buffer keeps rare.
const EVENTS_CAPACITY: usize = 4096;

impl AppState {
    pub fn new(db: Database, instance_id: Option<String>) -> Self {
        let (events, _) = broadcast::channel(EVENTS_CAPACITY);
        Self {
            db: Arc::new(db),
            events,
            instance_id,
            poller: poller::Poller::new(),
            forwarders: integrations::ForwarderManager::new(),
            permissions: agents::permission::Permissions::new(),
            limits: Arc::new(automation::Limits::default()),
            usage: Arc::new(usage::Usage::default()),
            warmup: Arc::new(warmup::Warmup::default()),
            fetches: Arc::new(worktrees::Fetches::default()),
            kept: Arc::new(kept::Kept::default()),
            chat: Arc::new(chat::Chat::default()),
        }
    }

    /// Tells every subscriber what changed.
    pub fn publish(&self, event: Event) {
        let _ = self.events.send(event.into());
    }

    /// An agent hook relayed as it arrived, under its own `type`. Everything the backend says
    /// itself goes through `publish`.
    pub fn broadcast(&self, value: Value) {
        let _ = self.events.send(value);
    }
}

/// Starts the background services once the loopback listener is bound: the sync engine, and
/// the webhook forwarders for the repos of the projects that forward. The wiring lives here so
/// `integrations` need not know which module decides what is forwarded. The old per-project
/// merge settings become pipelines first, before the first sync can act on them.
pub async fn start_background(state: &AppState, port: u16) {
    automation::start(state).await;
    state.poller.start(state.clone());
    let wanted: integrations::Wanted =
        Arc::new(|app: AppState| Box::pin(async move { automation::forward_repos(&app).await }));
    state.forwarders.start(state.clone(), port, wanted);
}

pub fn build_app(state: AppState) -> Router {
    let no_store = SetResponseHeaderLayer::overriding(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store"),
    );

    Router::new()
        .route("/api/backend/health", get(routes::health))
        .route(
            "/api/config",
            get(routes::get_config).post(routes::set_config),
        )
        .route("/api/sounds", get(routes::sounds))
        // Read only: the app keeps preferences itself now and imports these once.
        .route("/api/settings", get(routes::get_settings))
        .route("/api/sessions", post(sessions::create_session))
        .route(
            "/api/tasks",
            get(routes::get_tasks)
                .post(routes::upsert_task)
                .delete(routes::delete_task),
        )
        .route("/api/tasks/{id}/pin", patch(routes::pin_task))
        .route("/api/tasks/{id}/fork", post(fork::fork_task))
        .route("/api/tasks/{id}", patch(routes::patch_task))
        .route(
            "/api/projects",
            get(routes::get_projects).post(routes::create_project),
        )
        .route(
            "/api/projects/{id}",
            get(routes::get_project)
                .put(routes::update_project)
                .delete(routes::delete_project),
        )
        .route("/api/projects/{id}/board", get(routes::project_board))
        .route("/api/detect-repo", get(routes::detect_repo))
        .route("/api/file", get(local::get_file).put(local::put_file))
        .route("/api/files", get(local::list_files))
        .route("/api/launch-target", get(local::launch_target))
        .route(
            "/api/worktree",
            get(local::resolve_worktree).post(local::create_worktree),
        )
        .route("/api/worktrees", get(local::list_worktrees_route))
        .route("/api/worktree/remove", post(local::remove_worktree))
        .route("/api/worktree/holders", get(local::worktree_holders))
        .route("/api/diff", get(local::diff))
        .route("/api/git/commit", post(local::git_commit))
        .route("/api/git/push", post(local::git_push))
        .route("/api/git/log", get(local::git_log))
        .route("/api/git/refs", get(local::git_refs))
        .route("/api/git/tracked", get(local::git_tracked))
        .route("/api/git/commit-avatars", get(local::commit_avatars))
        .route("/api/git/show", get(local::git_show))
        .route("/api/git/discard", post(local::git_discard))
        .route("/api/git/switch", post(local::git_switch))
        .route("/api/xcode/schemes", get(xcode::schemes))
        .route("/api/xcode/destinations", get(xcode::destinations))
        .route(
            "/api/xcode/build-settings",
            get(xcode::build_settings),
        )
        .route(
            "/api/sim-preview",
            post(sim_preview::start).delete(sim_preview::stop),
        )
        .route(
            "/api/ide/warmup",
            get(warmup::get_warmup).post(warmup::post_warmup),
        )
        .route("/api/prs/lookup", get(routes::lookup_pr))
        .route("/api/prs/tray", get(routes::prs_tray))
        .route("/api/prs/viewed", post(routes::pr_viewed))
        .route("/api/dashboard", get(routes::dashboard))
        .route("/api/links", get(routes::get_links).post(routes::add_link))
        .route("/api/links/{id}", delete(routes::delete_link))
        .route("/api/events", get(routes::get_events))
        .route("/api/logs", get(routes::get_logs))
        .route("/api/logs/categories", get(routes::log_categories))
        .route("/api/logs/clear", post(routes::clear_logs))
        .route("/api/db", get(routes::inspect_db))
        .route("/api/whoami", get(routes::whoami))
        .route("/api/poll", post(routes::poll))
        .route("/api/upstreams", get(routes::upstreams))
        .route("/api/jira/search", post(routes::jira_search))
        .route("/api/jira/site", get(integrations::jira_site))
        .route("/api/jira/{key}/transition", post(routes::jira_transition))
        .route("/api/jira/{key}/assign", post(routes::jira_assign))
        .route("/api/issues/search", post(routes::issues_search))
        .route("/api/issues/lookup", get(routes::issue_lookup))
        .route("/api/stream", get(routes::stream))
        .route("/api/usage", get(usage::get))
        .route("/api/agent/catalog", get(agents::catalog))
        .route("/api/agent/status", get(agents::status))
        .route("/api/agent/conversation", get(agents::conversation))
        .route("/api/agent/transcript", get(routes::agent_transcript))
        // Its own limit, past the router's: an attachment comes as base64 (`chat::RPC_BODY_LIMIT`).
        .route("/api/chat/rpc", post(chat::rpc).layer(DefaultBodyLimit::max(chat::RPC_BODY_LIMIT)))
        .route("/api/agent/commands", get(agents::commands))
        .route("/api/agent/last-hook", get(integrations::last_hook))
        .route("/api/agent/permission", post(agents::permission::answer))
        .route("/api/hooks/permission", post(agents::permission::request))
        .route("/api/forwarders", get(automation::routes::forwarders))
        .route("/api/forwarders/fix", post(automation::routes::fix_forwarder))
        .route(
            "/api/automations",
            get(automation::routes::list).post(automation::routes::create),
        )
        .route("/api/automations/catalog", get(automation::routes::get_catalog))
        .route("/api/automations/samples", get(automation::routes::samples))
        .route("/api/automations/dry-run", post(automation::routes::dry_run))
        .route("/api/automations/runs", get(automation::routes::runs))
        .route(
            "/api/automations/settings",
            get(automation::routes::get_settings).put(automation::routes::put_settings),
        )
        .route(
            "/api/automations/{id}",
            get(automation::routes::get)
                .put(automation::routes::update)
                .delete(automation::routes::remove),
        )
        .route("/api/automations/{id}/run", post(automation::routes::run_now))
        .route("/api/automations/{id}/launch", post(automation::routes::launch_report))
        .route("/api/cli-tools", get(integrations::cli_tools))
        .route("/api/agent-hooks", get(integrations::agent_hooks).post(integrations::update_hooks))
        .route(
            "/api/agent-hooks/{cli}",
            post(integrations::install_hook).delete(integrations::uninstall_hook),
        )
        .route("/api/hooks/turn-start", post(integrations::turn_start))
        .route("/api/hooks/turn-done", post(integrations::turn_done))
        .route("/api/hooks/session-start", post(integrations::session_start))
        .route("/api/hooks/tool", post(integrations::tool_event))
        .route("/api/hooks/open-url", post(integrations::open_url))
        .route("/api/hooks/relaunch", post(integrations::relaunch))
        .route("/webhook/github", post(integrations::github_webhook))
        .layer(no_store)
        .layer(DefaultBodyLimit::max(15 * 1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

pub async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {}, _ = parent_exit() => {} }
}

async fn parent_exit() {
    let Some(pid) = std::env::var("CASCADE_NATIVE_PARENT_PID")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|pid| *pid > 1)
    else {
        std::future::pending::<()>().await;
        return;
    };
    #[cfg(unix)]
    loop {
        let alive = unsafe { libc::kill(pid, 0) } == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
        if !alive {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    #[cfg(not(unix))]
    std::future::pending::<()>().await;
}

#[cfg(test)]
mod route_contract {
    /// The native app addresses this backend through `macos/Services/Backend/Routes.swift`, which
    /// used to be generated by node from a shared contract, and checked by a node test. The app
    /// is native Swift over this crate now, so the contract is asserted here instead: every path
    /// the Swift constants name must be a route this router actually serves.
    ///
    /// Swift writes `:key`, axum writes `{key}`; both are normalised to `{}` so the comparison is
    /// about the SHAPE of the path, not the parameter's name.
    fn normalise(path: &str) -> String {
        path.split('/')
            .map(|segment| {
                if segment.starts_with(':') || (segment.starts_with('{') && segment.ends_with('}'))
                {
                    "{}"
                } else {
                    segment
                }
            })
            .collect::<Vec<_>>()
            .join("/")
    }

    fn literals(source: &str, pattern: &str) -> Vec<String> {
        let mut found = Vec::new();
        for part in source.split(pattern).skip(1) {
            let Some(rest) = part.trim_start().strip_prefix('"') else {
                continue;
            };
            if let Some(end) = rest.find('"') {
                let path = &rest[..end];
                if path.starts_with("/api/") {
                    found.push(normalise(path));
                }
            }
        }
        found
    }

    #[test]
    fn every_route_the_native_app_names_is_served() {
        let router = literals(include_str!("lib.rs"), ".route(");
        let swift = literals(
            include_str!("../../../macos/Services/Backend/Routes.swift"),
            "=",
        );
        assert!(swift.len() > 40, "parsed too few Swift routes: {swift:?}");
        let missing: Vec<_> = swift
            .iter()
            .filter(|path| !router.contains(path))
            .collect();
        assert!(
            missing.is_empty(),
            "the native app names routes this backend does not serve: {missing:?}"
        );
    }
}
