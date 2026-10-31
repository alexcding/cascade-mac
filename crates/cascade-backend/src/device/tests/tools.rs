//! The `device_*` tools against the fake backend, called as the gateway calls them. Ported from
//! Synara's `agentGateway/deviceTools.test.ts`, without its approval-gate cases (Cascade keeps no
//! gate of its own; the CLI's permission prompt asks).

use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::broadcast;

use super::fake::{FakeCall, FakeDeviceBackend, DEVICE_A, DEVICE_B, DEVICE_C, DEVICE_D};
use crate::{
    device::{
        backend::{DeviceAppearance, DeviceBackend, DeviceBackendError, DeviceConfiguration, DevicePrivacyAction, DeviceTouchEdge},
        manager::{AgentTurn, DeviceEvent, DeviceManager, DeviceManagerOptions, DeviceUse, OpenPaneReason},
        tools::{self, kind_named, Context},
    },
    gateway::ToolResult,
};

const OWNER: &str = "/work/session";

struct Fixture {
    backend: Arc<FakeDeviceBackend>,
    manager: DeviceManager,
    context: Context,
    _proofs: tempfile::TempDir,
}

async fn setup() -> Fixture {
    let backend = FakeDeviceBackend::new();
    let manager = DeviceManager::new(DeviceManagerOptions::new(backend.clone()));
    manager.boot(DEVICE_A).await.unwrap();
    let proofs = tempfile::tempdir().unwrap();
    let context = Context { manager: manager.clone(), owner: OWNER.into(), proofs: proofs.path().to_path_buf(), turn: None, lapses: false };
    Fixture { backend, manager, context, _proofs: proofs }
}

impl Fixture {
    async fn call(&self, name: &str, args: Value) -> ToolResult {
        let kind = kind_named(name).unwrap_or_else(|| panic!("no such tool: {name}"));
        let Value::Object(args) = args else { panic!("arguments are an object") };
        tools::run(kind, &self.context, &args).await
    }

    /// The first text part, parsed.
    async fn structured(&self, name: &str, args: Value) -> Value {
        let result = self.call(name, args).await;
        serde_json::from_str(result.content[0]["text"].as_str().expect("a text part")).unwrap_or(Value::Null)
    }

    async fn attached(&self) -> Option<String> {
        self.manager.owner_state(OWNER).await.attached_device_udid
    }
}

fn texts(result: &ToolResult) -> Vec<String> {
    result.content.iter().filter_map(|part| part["text"].as_str().map(str::to_owned)).collect()
}

/// The last text part: the screen snapshot, or an error message.
fn screen_text(result: &ToolResult) -> String {
    texts(result).pop().unwrap_or_default()
}

fn open_panes(events: &mut broadcast::Receiver<DeviceEvent>) -> Vec<(String, String, OpenPaneReason)> {
    let mut opened = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let DeviceEvent::OpenPane { owner, udid, reason } = event {
            opened.push((owner, udid, reason));
        }
    }
    opened
}

/// Every tool that drives or reads the device the user is watching.
fn interaction_calls() -> Vec<(&'static str, Value)> {
    vec![
        ("device_tap", json!({ "udid": DEVICE_A, "x": 10, "y": 10 })),
        ("device_swipe", json!({ "udid": DEVICE_A, "fromX": 0, "fromY": 0, "toX": 10, "toY": 10 })),
        ("device_type", json!({ "udid": DEVICE_A, "text": "hello" })),
        ("device_press_button", json!({ "udid": DEVICE_A, "button": "home" })),
        ("device_scroll_to_element", json!({ "udid": DEVICE_A, "label": "Deep Row" })),
        ("device_describe_ui", json!({ "udid": DEVICE_A })),
        ("device_screenshot", json!({ "udid": DEVICE_A })),
    ]
}

#[test]
fn exposes_the_full_device_tool_set_in_synaras_order() {
    let names: Vec<&str> = tools::all().iter().map(|tool| tool.definition().name).collect();
    assert_eq!(
        names,
        [
            "device_list",
            "device_boot",
            "device_install",
            "device_launch",
            "device_open_url",
            "device_tap",
            "device_swipe",
            "device_type",
            "device_press_button",
            "device_screenshot",
            "device_describe_ui",
            "device_wait",
            "device_scroll_to_element",
            "device_logs",
            "device_configure",
        ]
    );
    assert!(tools::all().iter().all(|tool| tool.instructions() == Some(tools::INSTRUCTIONS)));
}

#[test]
fn publishes_the_operational_rules_on_the_tools_that_need_them() {
    let all = tools::all();
    let description = |name: &str| {
        all.iter().find(|tool| tool.definition().name == name).map(|tool| tool.definition().description.clone()).unwrap()
    };
    for (name, needle) in [
        ("device_list", "use an already-booted device"),
        ("device_boot", "only when device_list finds nothing booted"),
        ("device_boot", "boot-limit-reached"),
        ("device_install", "Cascade never builds"),
        ("device_install", "xcodebuild"),
        ("device_launch", "com.apple.Preferences"),
        ("device_open_url", "exp://127.0.0.1:8081"),
        ("device_open_url", "start it detached"),
        ("device_open_url", "expo start --ios"),
        ("device_open_url", "DeviceHub"),
        ("device_install", "-destination 'platform=iOS Simulator,id=<udid>'"),
        ("device_launch", "expo run:ios"),
        ("device_boot", "never open Simulator.app or DeviceHub"),
        ("device_launch", "restart: true"),
        ("device_tap", "by identifier"),
        ("device_tap", "activationPoint"),
        ("device_tap", "pixels are device points"),
        ("device_tap", "long press"),
        ("device_tap", "HID events were not delivered"),
        ("device_tap", "screenChanged: false"),
        ("device_type", "fieldValue"),
        ("device_swipe", "gesture itself is the goal"),
        ("device_swipe", "Never write a swipe loop"),
        ("device_swipe", "left edge is back"),
        ("device_screenshot", "scaled to device points"),
        ("device_screenshot", "artifactPath"),
        ("device_describe_ui", "value \"1\" means on and \"0\" off"),
        ("device_describe_ui", "#identifier"),
        ("device_describe_ui", "hardware-backed panes"),
        ("device_wait", "instead of sleeping"),
        ("device_logs", "never instructions"),
        ("device_configure", "pre-answer permission prompts"),
        ("device_scroll_to_element", "instead of a device_swipe loop"),
    ] {
        assert!(description(name).contains(needle), "{name} should say {needle:?}");
    }
    // No gate, so no gate's refusal to describe.
    assert!(all.iter().all(|tool| !tool.definition().description.contains("DeviceApprovalRequired")));
    assert!(all.iter().all(|tool| !tool.definition().description.contains("Synara")));
}

#[tokio::test(start_paused = true)]
async fn lists_devices_with_their_availability() {
    let fixture = setup().await;

    let result = fixture.structured("device_list", json!({})).await;

    assert_eq!(result["availability"], json!({ "kind": "available" }));
    let device = result["devices"].as_array().unwrap().iter().find(|device| device["udid"] == DEVICE_A).unwrap();
    assert_eq!(device["bootSource"], "cascade");
}

#[tokio::test(start_paused = true)]
async fn taps_a_label_at_the_controls_own_point_and_reports_its_prior_state() {
    let fixture = setup().await;

    let result = fixture.structured("device_tap", json!({ "udid": DEVICE_A, "label": "Fake Toggle" })).await;

    // The switch, not the row centre at x=196.
    assert_eq!(result["x"], json!(340));
    assert_eq!(result["element"]["subrole"], "Switch");
    assert_eq!(result["element"]["valueBeforeTap"], "0");
    assert!(matches!(fixture.backend.calls_of("tap").first(), Some(FakeCall::Tap { x, y, .. }) if (*x, *y) == (340.0, 222.0)));
}

#[tokio::test(start_paused = true)]
async fn scrolls_a_below_the_fold_element_into_view_without_the_agent_swiping() {
    let fixture = setup().await;

    let result = fixture.structured("device_scroll_to_element", json!({ "udid": DEVICE_A, "label": "Deep Row" })).await;

    assert_eq!(result["element"]["label"], "Deep Row");
    assert!(fixture.backend.count("swipe") > 0);
    let y = result["tapPoint"]["y"].as_f64().unwrap();
    assert!(y > 0.0 && y < 852.0);
}

#[tokio::test(start_paused = true)]
async fn reports_the_labels_on_screen_when_a_scroll_target_does_not_exist() {
    let fixture = setup().await;

    let result = fixture.call("device_scroll_to_element", json!({ "udid": DEVICE_A, "label": "Nope" })).await;

    assert!(result.is_error);
    let message = screen_text(&result);
    assert!(message.contains("No element labelled"), "{message}");
    assert!(message.contains("Fake Toggle"), "{message}");
}

#[tokio::test(start_paused = true)]
async fn returns_the_screenshot_bytes_as_image_content_beside_the_metadata() {
    let fixture = setup().await;

    let result = fixture.call("device_screenshot", json!({ "udid": DEVICE_A })).await;

    let kinds: Vec<&str> = result.content.iter().map(|part| part["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["text", "image"]);
    assert_eq!(result.content[1]["mimeType"], "image/png");
    let metadata: Value = serde_json::from_str(result.content[0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(metadata["coordinates"], "device points");
    assert!(metadata.get("bytesBase64").is_none());
}

#[tokio::test(start_paused = true)]
async fn saves_a_proof_screenshot_and_returns_its_path() {
    let fixture = setup().await;

    let metadata = fixture.structured("device_screenshot", json!({ "udid": DEVICE_A, "proof": true })).await;

    let path = metadata["artifactPath"].as_str().expect("a proof path");
    assert!(std::path::Path::new(path).exists());
}

#[tokio::test(start_paused = true)]
async fn opens_the_pane_when_the_agent_installs_an_app() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    fixture.structured("device_install", json!({ "udid": DEVICE_A, "appPath": "/tmp/Demo.app" })).await;

    assert_eq!(open_panes(&mut events), [(OWNER.into(), DEVICE_A.into(), OpenPaneReason::AgentInstall)]);
}

#[tokio::test(start_paused = true)]
async fn opens_the_pane_when_the_agent_launches_an_app() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    let launched = fixture.structured("device_launch", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;

    assert_eq!(launched["bundleId"], "com.example.Demo");
    assert_eq!(launched["pid"], 4242);
    assert_eq!(open_panes(&mut events), [(OWNER.into(), DEVICE_A.into(), OpenPaneReason::AgentLaunch)]);
}

#[tokio::test(start_paused = true)]
async fn reports_the_boot_limit_refusal_to_the_agent_rather_than_failing() {
    let fixture = setup().await;
    fixture.structured("device_boot", json!({ "udid": DEVICE_B })).await;
    fixture.structured("device_boot", json!({ "udid": DEVICE_C })).await;

    let result = fixture.structured("device_boot", json!({ "udid": DEVICE_D })).await;

    assert_eq!(result["kind"], "boot-limit-reached");
    assert_eq!(result["cascadeBooted"].as_array().unwrap().len(), 3);
}

#[tokio::test(start_paused = true)]
async fn reports_every_backend_failure_to_the_agent_and_only_actionable_errors_to_the_pane() {
    let fixture = setup().await;
    let result = fixture.call("device_tap", json!({ "udid": DEVICE_B, "x": 1, "y": 1 })).await;
    assert!(result.is_error);
    assert!(fixture.manager.owner_state(OWNER).await.last_error.unwrap().contains("not booted"));

    for (message, viewer_facing) in [
        (
            "Scrolling stopped moving \"Settings\" after 2 swipes; the list appears to be at its end and the element is still out of reach.",
            false,
        ),
        ("No element matching label \"Dark mode\" is on screen.", false),
        ("Label \"Save\" matched more than one element.", false),
        ("Element \"Developer\" is not visible on screen.", false),
        ("Device helper could not be built: xcodebuild exited with code 65", true),
        ("simulator B9802326 is not booted (state 1)", true),
        ("display has no framebuffer surface yet", true),
        ("Xcode is not installed", true),
    ] {
        let fixture = setup().await;
        fixture.backend.fail_next("tap", DeviceBackendError::new(message));
        let failure = fixture.call("device_tap", json!({ "udid": DEVICE_A, "x": 1, "y": 1 })).await;
        assert!(failure.is_error, "{message}");
        assert!(failure.content.contains(&json!({ "type": "text", "text": message })), "{message}");
        let recorded = fixture.manager.owner_state(OWNER).await.last_error;
        assert_eq!(recorded.as_deref(), viewer_facing.then_some(message), "{message}");
    }
}

#[tokio::test(start_paused = true)]
async fn rejects_malformed_arguments_without_touching_the_device() {
    let fixture = setup().await;

    let missing_udid = fixture.call("device_tap", json!({ "x": 1, "y": 1 })).await;
    let bad_coordinate = fixture.call("device_tap", json!({ "udid": DEVICE_A, "x": -5, "y": 1 })).await;

    assert!(missing_udid.is_error);
    assert!(bad_coordinate.is_error);
    assert_eq!(fixture.backend.count("tap"), 0);
}

#[tokio::test(start_paused = true)]
async fn enforces_contract_bounds_for_swipe_duration_and_scroll_budget() {
    let fixture = setup().await;
    let swipe = |duration: Value| json!({ "udid": DEVICE_A, "fromX": 0, "fromY": 0, "toX": 10, "toY": 10, "durationMs": duration });

    let fractional = fixture.call("device_swipe", swipe(json!(10.5))).await;
    let excessive = fixture.call("device_swipe", swipe(json!(10_001))).await;
    let scrolls = fixture.call("device_scroll_to_element", json!({ "udid": DEVICE_A, "label": "Deep Row", "maxSwipes": 33 })).await;

    assert!(fractional.is_error && excessive.is_error && scrolls.is_error);
    assert_eq!(fixture.backend.count("swipe"), 0);
}

// ── Auto-attach ────────────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn attaches_the_caller_to_the_device_it_launches_on() {
    let fixture = setup().await;
    fixture.structured("device_launch", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;
    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn attaches_on_install_too() {
    let fixture = setup().await;
    fixture.structured("device_install", json!({ "udid": DEVICE_A, "appPath": "/tmp/Demo.app" })).await;
    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_A));
}

#[tokio::test(start_paused = true)]
async fn attaches_on_boot_without_opening_the_pane() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    fixture.structured("device_boot", json!({ "udid": DEVICE_B })).await;

    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_B));
    assert!(open_panes(&mut events).is_empty());
}

#[tokio::test(start_paused = true)]
async fn leaves_a_caller_already_watching_another_device_alone() {
    let fixture = setup().await;
    fixture.backend.boot(DEVICE_B).await.unwrap();
    fixture.manager.attach(OWNER, DEVICE_B).await;

    fixture.structured("device_launch", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;

    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_B));
}

#[tokio::test(start_paused = true)]
async fn still_returns_the_launch_result_when_attaching_cannot_stream() {
    let fixture = setup().await;
    fixture.backend.fail_next("attachStream", DeviceBackendError::new("helper is not built"));

    let result = fixture.structured("device_launch", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;

    assert_eq!(result["bundleId"], "com.example.Demo");
}

// ── Surfacing the pane on any interaction ──────────────────────────────

#[tokio::test(start_paused = true)]
async fn attaches_and_opens_the_pane_on_every_interaction_tool() {
    for (name, args) in interaction_calls() {
        let fixture = setup().await;
        let mut events = fixture.manager.subscribe();

        let result = fixture.call(name, args).await;

        assert!(!result.is_error, "{name} should succeed: {:?}", result.content);
        assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_A), "{name}");
        assert_eq!(open_panes(&mut events), [(OWNER.into(), DEVICE_A.into(), OpenPaneReason::AgentTool)], "{name}");
    }
}

#[tokio::test(start_paused = true)]
async fn asks_the_pane_to_open_only_once_across_repeated_taps() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();
    let (name, args) = interaction_calls().remove(0);

    for _ in 0..3 {
        fixture.call(name, args.clone()).await;
    }

    assert_eq!(open_panes(&mut events).len(), 1);
}

#[tokio::test(start_paused = true)]
async fn never_steals_a_caller_already_watching_another_device_on_tap() {
    let fixture = setup().await;
    fixture.backend.boot(DEVICE_B).await.unwrap();
    fixture.manager.attach(OWNER, DEVICE_B).await;
    let mut events = fixture.manager.subscribe();
    let (name, args) = interaction_calls().remove(0);

    fixture.call(name, args).await;

    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_B));
    let udids: Vec<String> = open_panes(&mut events).into_iter().map(|(_, udid, _)| udid).collect();
    assert_eq!(udids, [DEVICE_A]);
}

#[tokio::test(start_paused = true)]
async fn does_not_surface_the_pane_for_device_list() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    fixture.structured("device_list", json!({ "includeShutdown": true })).await;

    assert!(open_panes(&mut events).is_empty());
    assert_eq!(fixture.attached().await, None);
}

#[tokio::test(start_paused = true)]
async fn does_not_surface_the_pane_when_the_interaction_fails() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    let result = fixture.call("device_tap", json!({ "udid": DEVICE_B, "x": 1, "y": 1 })).await;

    assert!(result.is_error);
    assert!(open_panes(&mut events).is_empty());
}

#[tokio::test(start_paused = true)]
async fn keeps_the_pane_request_idempotent_across_different_interaction_tools() {
    let fixture = setup().await;
    let mut events = fixture.manager.subscribe();

    for (name, args) in interaction_calls() {
        fixture.call(name, args).await;
    }

    assert_eq!(open_panes(&mut events).len(), 1);
    assert_eq!(fixture.attached().await.as_deref(), Some(DEVICE_A));
}

// ── End-to-end testing ─────────────────────────────────────────────────

#[tokio::test(start_paused = true)]
async fn returns_the_settled_screen_and_whether_it_changed_after_an_input() {
    let fixture = setup().await;

    let result = fixture.call("device_tap", json!({ "udid": DEVICE_A, "identifier": "continue-button" })).await;

    assert!(!result.is_error);
    let metadata: Value = serde_json::from_str(&texts(&result)[0]).unwrap();
    assert_eq!(metadata["element"]["label"], "Continue");
    assert_eq!(metadata["element"]["identifier"], "continue-button");
    assert_eq!(metadata["settled"], true);
    assert_eq!(metadata["screenChanged"], false);
    let screen = screen_text(&result);
    assert!(screen.contains("app \"Fake App\""), "{screen}");
    assert!(screen.contains("- Button \"Continue\" #\"continue-button\" @196,725"), "{screen}");
}

#[tokio::test(start_paused = true)]
async fn skips_the_observation_when_asked_to() {
    let fixture = setup().await;

    let result = fixture.call("device_tap", json!({ "udid": DEVICE_A, "x": 10, "y": 10, "observe": false })).await;

    assert_eq!(result.content.len(), 1);
    assert_eq!(fixture.backend.count("describeUi"), 0);
}

#[tokio::test(start_paused = true)]
async fn turns_a_swipe_that_starts_on_the_left_edge_into_the_back_gesture() {
    let fixture = setup().await;
    fixture.manager.describe_ui(DEVICE_A).await.unwrap();

    fixture.call("device_swipe", json!({ "udid": DEVICE_A, "fromX": 2, "fromY": 400, "toX": 300, "toY": 400 })).await;
    fixture.call("device_swipe", json!({ "udid": DEVICE_A, "fromX": 200, "fromY": 600, "toX": 200, "toY": 200 })).await;

    let edges: Vec<Option<DeviceTouchEdge>> = fixture
        .backend
        .calls_of("swipe")
        .into_iter()
        .map(|call| match call {
            FakeCall::Swipe { gesture, .. } => gesture.edge,
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(edges, [Some(DeviceTouchEdge::Left), None]);
}

#[tokio::test(start_paused = true)]
async fn reads_the_field_back_after_typing() {
    let fixture = setup().await;

    let metadata = fixture.structured("device_type", json!({ "udid": DEVICE_A, "text": "ada" })).await;

    assert_eq!(metadata["method"], "keys");
    assert_eq!(metadata["fieldValue"], "ada");
    assert_eq!(metadata["submitted"], false);
}

#[tokio::test(start_paused = true)]
async fn waits_for_an_element_by_identifier() {
    let fixture = setup().await;

    let ready = fixture.structured("device_wait", json!({ "udid": DEVICE_A, "identifier": "continue-button", "timeoutMs": 1000 })).await;
    let timeout = fixture.structured("device_wait", json!({ "udid": DEVICE_A, "label": "Never there", "timeoutMs": 300 })).await;

    assert_eq!(ready["status"], "ready");
    assert_eq!(timeout["status"], "timeout");
    assert_eq!(timeout["settled"], false);
}

#[tokio::test(start_paused = true)]
async fn applies_environment_settings_and_validates_privacy_requests() {
    let fixture = setup().await;

    let applied = fixture
        .structured(
            "device_configure",
            json!({
                "udid": DEVICE_A,
                "appearance": "dark",
                "location": { "latitude": 45.46, "longitude": 9.19 },
                "privacy": { "action": "grant", "service": "photos", "bundleId": "com.example.shop" },
            }),
        )
        .await;

    assert_eq!(applied, json!({ "udid": DEVICE_A, "applied": ["appearance", "location", "privacy"] }));
    let configured: Vec<DeviceConfiguration> = fixture
        .backend
        .calls_of("configure")
        .into_iter()
        .map(|call| match call {
            FakeCall::Configure { configuration, .. } => configuration,
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(
        configured,
        [
            DeviceConfiguration::Appearance(DeviceAppearance::Dark),
            DeviceConfiguration::Location { latitude: 45.46, longitude: 9.19 },
            DeviceConfiguration::Privacy {
                action: DevicePrivacyAction::Grant,
                service: "photos".into(),
                bundle_id: Some("com.example.shop".into()),
            },
        ]
    );

    let missing_bundle =
        fixture.call("device_configure", json!({ "udid": DEVICE_A, "privacy": { "action": "grant", "service": "photos" } })).await;
    assert!(missing_bundle.is_error);
    assert!(screen_text(&missing_bundle).contains("needs the app's bundleId"));
}

#[tokio::test(start_paused = true)]
async fn reads_logs_with_synaras_defaults() {
    let fixture = setup().await;

    let logs = fixture.structured("device_logs", json!({ "udid": DEVICE_A, "bundleId": "com.example.Demo" })).await;

    assert_eq!(logs["bundleId"], "com.example.Demo");
    assert_eq!(logs["process"], "FakeApp");
    let bad = fixture.call("device_logs", json!({ "udid": DEVICE_A, "bundleId": "x", "limit": 401 })).await;
    assert!(bad.is_error);
}

// ── Turn ownership ─────────────────────────────────────────────────────
// Synara `deviceTools.test.ts` "device tool turn ownership" and "device tool cancellation during
// idle cleanup" (d419d5d40).

fn agent_turn(id: &str) -> AgentTurn {
    AgentTurn { holder: "chat:thread".into(), id: id.into() }
}

fn turn_context(manager: &DeviceManager, proofs: &tempfile::TempDir, id: &str) -> Context {
    Context { manager: manager.clone(), owner: OWNER.into(), proofs: proofs.path().to_path_buf(), turn: Some(agent_turn(id)), lapses: false }
}

async fn call_in(context: &Context, name: &str, args: Value) -> ToolResult {
    let kind = kind_named(name).unwrap_or_else(|| panic!("no such tool: {name}"));
    let Value::Object(args) = args else { panic!("arguments are an object") };
    tools::run(kind, context, &args).await
}

#[tokio::test(start_paused = true)]
async fn keeps_a_whitespace_padded_device_boot_leased_until_its_turn_ends() {
    let backend = FakeDeviceBackend::new();
    let mut options = DeviceManagerOptions::new(backend.clone());
    options.idle_shutdown = std::time::Duration::from_millis(20);
    options.attach_deadline = std::time::Duration::ZERO;
    let manager = DeviceManager::new(options);
    let proofs = tempfile::tempdir().unwrap();
    let context = turn_context(&manager, &proofs, "turn-a");

    let result = call_in(&context, "device_boot", json!({ "udid": format!(" {DEVICE_A} ") })).await;
    assert!(!result.is_error, "{:?}", texts(&result));
    tokio::time::sleep(std::time::Duration::from_millis(40)).await;
    assert_eq!(backend.count("shutdown"), 0);

    manager.end_agent_turn(agent_turn("turn-a")).await;
    for _ in 0..200 {
        if backend.udids_of("shutdown") == [DEVICE_A] {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert_eq!(backend.udids_of("shutdown"), [DEVICE_A]);
    manager.dispose().await;
}

/// A Stop drops the tool call's future: one still waiting out an idle poweroff never reaches the
/// device, and its badge clears.
#[tokio::test(start_paused = true)]
async fn does_not_dispatch_a_cancelled_call_that_waits_for_a_pending_poweroff() {
    let cases = [
        ("device_tap", json!({ "udid": DEVICE_A, "x": 1, "y": 1, "observe": false }), "tap"),
        ("device_install", json!({ "udid": DEVICE_A, "appPath": "/tmp/Test.app" }), "install"),
        ("device_screenshot", json!({ "udid": DEVICE_A }), "screenshot"),
    ];
    for (name, args, kind) in cases {
        let backend = FakeDeviceBackend::new();
        let mut options = DeviceManagerOptions::new(backend.clone());
        options.attach_deadline = std::time::Duration::ZERO;
        let manager = DeviceManager::new(options);
        let proofs = tempfile::tempdir().unwrap();
        manager.boot(DEVICE_A).await.unwrap();
        let old =
            DeviceUse { udid: DEVICE_A.into(), turn: Some(AgentTurn { holder: "old-thread".into(), id: "old-turn".into() }), lapses: false };
        manager.with_agent_activity("old-owner", Some(old), manager.ensure_attached("old-owner", DEVICE_A)).await.unwrap();
        let (started, finish) = backend.hold_shutdown(DEVICE_A);
        manager.end_agent_turn(AgentTurn { holder: "old-thread".into(), id: "old-turn".into() }).await;
        tokio::time::sleep(crate::device::manager::DEVICE_IDLE_SHUTDOWN + std::time::Duration::from_millis(1)).await;
        started.notified().await;

        let call = {
            let context = turn_context(&manager, &proofs, "turn-a");
            tokio::spawn(async move { call_in(&context, name, args).await })
        };
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        assert_eq!(backend.count(kind), 0, "{name}");
        call.abort();
        let _ = call.await;
        finish.notify_one();
        for _ in 0..200 {
            if !manager.owner_state(OWNER).await.agent_active {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert!(!manager.owner_state(OWNER).await.agent_active, "{name}");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert_eq!(backend.count(kind), 0, "{name}");
        manager.dispose().await;
    }
}

/// A terminal agent's tool call that a Stop drops, whose turn settled before the call was counted,
/// still releases that turn (review fix 3).
#[tokio::test(start_paused = true)]
async fn a_dropped_call_releases_a_turn_that_settled_meanwhile() {
    let backend = FakeDeviceBackend::new();
    let dir = tempfile::tempdir().unwrap();
    let state = crate::AppState::new(crate::Database::open(dir.path()).unwrap(), None);
    let mut options = DeviceManagerOptions::new(backend.clone());
    options.attach_deadline = std::time::Duration::ZERO;
    let manager = DeviceManager::new(options);
    state.device.install(&state, manager.clone());
    manager.boot(DEVICE_A).await.unwrap();
    crate::device::service::terminal_turn_started(&state, "pty1-1");
    let caller = crate::gateway::Caller::Terminal { run_id: "pty1-1".into(), cwd: Some("/work/term".into()) };
    let tool = tools::all().into_iter().find(|tool| tool.definition().name == "device_wait").unwrap();
    let call = {
        let (state, caller) = (state.clone(), caller.clone());
        tokio::spawn(async move {
            tool.call(state, caller, json!({ "udid": DEVICE_A, "label": "Never There", "timeoutMs": 30000 })).await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    state.device.forget_terminal_turn("pty1-1");
    call.abort();
    let _ = call.await;

    // Released at the drop: the device idles off one grace later, not after a lapse and a grace.
    let idle = crate::device::manager::DEVICE_IDLE_SHUTDOWN;
    tokio::time::sleep(idle + idle / 2).await;
    for _ in 0..200 {
        if backend.count("shutdown") == 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
    assert_eq!(backend.count("shutdown"), 1);
}

/// A terminal agent started in a folder inside its session's worktree acts for that worktree,
/// which its session's pane watches; a folder in no checkout is its own owner.
#[tokio::test]
async fn a_terminal_agent_in_a_subfolder_acts_for_its_sessions_worktree() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let worktree = root.join("app");
    std::fs::create_dir_all(worktree.join("Sources/App")).unwrap();
    // A worktree's `.git` is a file naming its repository.
    std::fs::write(worktree.join(".git"), "gitdir: /repo/.git/worktrees/app\n").unwrap();
    let state = crate::AppState::new(crate::Database::open(&root.join("data")).unwrap(), None);
    let caller = |cwd: &std::path::Path| crate::gateway::Caller::Terminal { run_id: "pty1-1".into(), cwd: Some(cwd.to_str().unwrap().into()) };

    let owner = worktree.to_str().unwrap().to_owned();
    assert_eq!(tools::owner_of(&state, &caller(&worktree.join("Sources/App"))).await, owner);
    assert_eq!(tools::owner_of(&state, &caller(&worktree)).await, owner);
    std::fs::create_dir_all(root.join("loose")).unwrap();
    assert_eq!(tools::owner_of(&state, &caller(&root.join("loose"))).await, root.join("loose").to_str().unwrap());
}
