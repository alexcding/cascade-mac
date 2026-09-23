//! The simulator preview: Expo's `serve-sim` streaming a booted iOS Simulator to a local page
//! the workspace's Simulator panel shows. `serve-sim --detach` starts one helper per device and
//! answers with its address; asked again for a device it already streams, it answers with the
//! same helper, so a start is safe to repeat.
//!
//! The helper is a detached daemon, like the PTY daemon: it outlives the request that started
//! it, and explicit Quit stops it through `DELETE /api/sim-preview`.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, LazyLock,
    },
    time::Duration,
};

use axum::{http::HeaderMap, Json};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::{Mutex, RwLock};

use crate::{cli, error::ApiError, local::foreign_origin};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// The serve-sim `npx` fetches when none is installed: pinned, so a release that changes the
/// JSON `--detach` prints cannot break the panel unannounced.
const PACKAGE: &str = "@expo/serve-sim@0.3.1";
/// The Swift side matches this wording (`SimulatorPreviewModel.state(for:)`).
const MISSING: &str =
    "The simulator preview needs Node.js 20 or later. See Settings → Integrations.";

/// How serve-sim is run: an installed `serve-sim` when there is one — `npm -g`, however Node
/// itself was installed — else `npx`, which fetches the pinned package into the user's own
/// cache. Either way nothing needs `sudo`, which `npm -g` under the nodejs.org installer does.
/// `fetch` false never downloads: Stop has nothing to stop when the package was never fetched,
/// and Quit must not wait on the network to find that out.
fn serve_sim(args: &[&str], fetch: bool, installed: bool) -> (&'static str, Vec<String>) {
    let mut full: Vec<String> = Vec::new();
    let program = if installed {
        "serve-sim"
    } else {
        // `--offline` answers from the cache or fails at once (ENOTCACHED). Not `--no`, which
        // npm 11 leaves waiting on a prompt that has no terminal to answer it.
        full.push("-y".into());
        if !fetch {
            full.push("--offline".into());
        }
        full.push(PACKAGE.into());
        "npx"
    };
    full.extend(args.iter().map(|arg| arg.to_string()));
    (program, full)
}

async fn run_serve_sim(args: &[&str], fetch: bool, timeout: Duration) -> anyhow::Result<String> {
    let (program, args) = serve_sim(args, fetch, cli::installed("serve-sim"));
    cli::run(program, args, timeout).await
}

/// serve-sim runs on Node 20 or later; an older one fails in ways that say nothing useful.
async fn node_ready() -> bool {
    match cli::run("node", ["--version"], Duration::from_secs(5)).await {
        Ok(version) => node_supported(&version) == Some(true),
        Err(_) => false,
    }
}

/// No `npx`, or no `node` for the launcher's `#!/usr/bin/env node`.
fn is_missing(error: &anyhow::Error) -> bool {
    let text = format!("{error:#}");
    text.contains("No such file or directory") || text.contains("env: node")
}

/// Starts of one device run one at a time: two Runs racing on it would each spawn a helper
/// before either had registered, and the second would fail on the port the first took.
static DEVICES: LazyLock<std::sync::Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    LazyLock::new(Default::default);
/// Starts hold it shared and Stop exclusively, so a helper a start is still spawning cannot
/// register after Quit has stopped the others and outlive the app.
static SPAWNING: RwLock<()> = RwLock::const_new(());
/// Bumped by every Stop. Stop only waits so long for the lock, so a start that outlasts it
/// checks this afterwards and stops the helper it spawned itself, rather than leave it behind.
static STOPS: AtomicU64 = AtomicU64::new(0);

const STOPPED: &str = "The simulator preview was stopped.";

fn device_lock(udid: &str) -> Arc<Mutex<()>> {
    DEVICES
        .lock()
        .unwrap()
        .entry(udid.to_owned())
        .or_default()
        .clone()
}

#[derive(Deserialize)]
pub struct PreviewRequest {
    udid: Option<String>,
}

/// The helper `serve-sim --detach -q` reports: `{"url","streamUrl","wsUrl","port","device"}`.
/// Only a loopback page is accepted, since the panel loads it without an address bar.
fn parse_detach(raw: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(raw.lines().last()?.trim()).ok()?;
    let url = value["url"].as_str()?;
    let device = value["device"].as_str()?;
    let loopback = Regex::new(r"^http://(127\.0\.0\.1|localhost|\[::1\]):\d+/?$").unwrap();
    loopback
        .is_match(url)
        .then(|| json!({"udid": device, "url": url}))
}

fn valid_udid(value: &str) -> bool {
    Regex::new(r"^[0-9A-Fa-f-]{16,}$").unwrap().is_match(value)
}

/// A spawn that could not find the program reads as not installed rather than as a failure.
fn start_error(error: anyhow::Error) -> ApiError {
    if is_missing(&error) {
        ApiError::precondition(MISSING)
    } else {
        ApiError::internal(error)
    }
}

pub async fn start(headers: HeaderMap, Json(request): Json<PreviewRequest>) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let udid = request
        .udid
        .as_deref()
        .map(str::trim)
        .filter(|v| valid_udid(v))
        .ok_or_else(|| ApiError::bad_request("udid (a simulator id) required"))?
        .to_owned();
    // The stream needs a booted device, and the build that follows boots it anyway. Booting
    // first lets the panel go live while the build runs. "Already booted" is an error to simctl.
    let _ = cli::run(
        "xcrun",
        ["simctl", "boot", udid.as_str()],
        Duration::from_secs(60),
    )
    .await;
    let device = device_lock(&udid);
    let _turn = device.lock().await;
    let _spawning = SPAWNING.read().await;
    let stops = STOPS.load(Ordering::SeqCst);
    if !node_ready().await {
        return Err(ApiError::precondition(MISSING));
    }
    // A first `npx` run downloads the package before it starts anything.
    let raw = run_serve_sim(
        &["--detach", "-q", udid.as_str()],
        true,
        Duration::from_secs(120),
    )
    .await
    .map_err(start_error)?;
    if STOPS.load(Ordering::SeqCst) != stops {
        // A Stop ran while this helper was spawning, and gave up waiting for it.
        let _ = run_serve_sim(
            &["--kill", "-q", udid.as_str()],
            false,
            Duration::from_secs(15),
        )
        .await;
        return Err(ApiError::conflict(STOPPED));
    }
    parse_detach(&raw)
        .map(Json)
        .ok_or_else(|| ApiError::internal(format!("serve-sim answered unexpectedly: {raw}")))
}

/// Stops every helper, the ones started from a terminal included: `serve-sim` keeps no record
/// of who started a stream.
pub async fn stop(headers: HeaderMap) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    // Bumped first, so a start that outlasts the wait below still sees it and cleans up.
    STOPS.fetch_add(1, Ordering::SeqCst);
    // Waits out a detach in flight, but not so long that Quit hangs on a wedged one.
    let _spawning = tokio::time::timeout(Duration::from_secs(10), SPAWNING.write())
        .await
        .ok();
    // A failure means there was nothing to stop: no Node, or a package that was never fetched.
    let _ = run_serve_sim(&["--kill", "-q"], false, Duration::from_secs(15)).await;
    Ok(Json(json!({"ok": true})))
}

/// `node --version` prints `v22.11.0`; serve-sim needs Node 20 or later.
pub(crate) fn node_supported(version: &str) -> Option<bool> {
    let major: u32 = version
        .trim()
        .trim_start_matches('v')
        .split('.')
        .next()?
        .parse()
        .ok()?;
    Some(major >= 20)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_detached_helper() {
        let raw = r#"{"url":"http://127.0.0.1:3100","streamUrl":"http://127.0.0.1:3100/helper/ADA0BBAC-F7E1-46C6-9C5B-2FCC9C150D92/stream.mjpeg","wsUrl":"ws://127.0.0.1:3100/helper/ADA0BBAC-F7E1-46C6-9C5B-2FCC9C150D92/ws","port":3100,"device":"ADA0BBAC-F7E1-46C6-9C5B-2FCC9C150D92"}"#;
        assert_eq!(
            parse_detach(raw),
            Some(
                json!({"udid":"ADA0BBAC-F7E1-46C6-9C5B-2FCC9C150D92","url":"http://127.0.0.1:3100"})
            )
        );
    }

    #[test]
    fn refuses_a_helper_off_loopback() {
        assert_eq!(
            parse_detach(r#"{"url":"http://10.0.0.2:3100","device":"X"}"#),
            None
        );
        assert_eq!(
            parse_detach(r#"{"url":"https://example.com","device":"X"}"#),
            None
        );
        assert_eq!(parse_detach("not json"), None);
        assert_eq!(parse_detach(r#"{"url":"http://127.0.0.1:3100"}"#), None);
    }

    #[test]
    fn an_installed_serve_sim_wins_and_npx_fetches_only_to_start() {
        assert_eq!(
            serve_sim(&["--detach", "-q", "U"], true, true),
            (
                "serve-sim",
                vec!["--detach".into(), "-q".into(), "U".into()]
            )
        );
        assert_eq!(
            serve_sim(&["--detach", "-q", "U"], true, false),
            (
                "npx",
                vec![
                    "-y".into(),
                    PACKAGE.into(),
                    "--detach".into(),
                    "-q".into(),
                    "U".into()
                ]
            )
        );
        // Stop never downloads.
        assert_eq!(
            serve_sim(&["--kill", "-q"], false, false),
            (
                "npx",
                vec![
                    "-y".into(),
                    "--offline".into(),
                    PACKAGE.into(),
                    "--kill".into(),
                    "-q".into()
                ]
            )
        );
    }

    #[test]
    fn a_udid_is_required_not_a_name() {
        assert!(valid_udid("ADA0BBAC-F7E1-46C6-9C5B-2FCC9C150D92"));
        assert!(!valid_udid("iPhone 16 Pro"));
        assert!(!valid_udid("--kill"));
    }

    #[test]
    fn node_twenty_or_later() {
        assert_eq!(node_supported("v18.19.0"), Some(false));
        assert_eq!(node_supported("v20.0.0"), Some(true));
        assert_eq!(node_supported("v26.9.0\n"), Some(true));
        assert_eq!(node_supported("garbage"), None);
    }
}
