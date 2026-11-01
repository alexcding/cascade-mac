//! The Simulator pane's routes: its state, the device picker, and the user's own input.
//!
//! Synara's pane talks to its server over the WebSocket RPC (`wsDeviceHandlers.ts`); Cascade's
//! native pane posts to these routes, with the same semantics. Input here is the user's, so it is
//! sent as is: no settle observation, no agent badge, no pane surfacing. Changes reach the pane as
//! `device` and `device-open-pane` events.

use axum::{extract::State, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use super::{
    backend::{DeviceKeyDirection, DeviceKeyEvent, DeviceSwipeGesture, DeviceTouchPhase},
    contracts::{
        DeviceAvailability, DeviceHardwareButton, DeviceKeyModifier, DEVICE_COORDINATE_MAX, DEVICE_SWIPE_DURATION_MAX_MS,
    },
    manager::{DeviceManager, OwnerDeviceState},
    service::normalize_owner,
    ui_targeting::{read_tap_request, DeviceTapInput, DeviceTapRequest},
};
use crate::{error::ApiError, AppState};

const UNSUPPORTED_MESSAGE: &str = "The device pane requires macOS with Xcode and an iOS simulator runtime.";
const UDID_MAX_LENGTH: usize = 128;
const TEXT_MAX_LENGTH: usize = 4_096;

type ApiResult = Result<Json<Value>, ApiError>;

fn manager(state: &AppState) -> Result<DeviceManager, ApiError> {
    state.device.supported().cloned().ok_or_else(|| ApiError::bad_request(UNSUPPORTED_MESSAGE))
}

/// Synara `DeviceUdid`: trimmed, non-empty, at most 128 of `[A-Za-z0-9._:-]`.
fn udid(raw: &str) -> Result<String, ApiError> {
    let udid = raw.trim();
    let valid = !udid.is_empty()
        && udid.len() <= UDID_MAX_LENGTH
        && udid.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'));
    valid.then(|| udid.to_owned()).ok_or_else(|| ApiError::bad_request("udid must be a simulator udid"))
}

fn owner(raw: &str) -> Result<String, ApiError> {
    let owner = normalize_owner(raw);
    if owner.is_empty() {
        return Err(ApiError::bad_request("owner required"));
    }
    Ok(owner)
}

/// Synara `DeviceCoordinate`: a finite device point between 0 and 20000.
fn coordinate(name: &str, value: f64) -> Result<f64, ApiError> {
    if value.is_finite() && (0.0..=DEVICE_COORDINATE_MAX).contains(&value) {
        Ok(value)
    } else {
        Err(ApiError::bad_request(format!("{name} must be a device point between 0 and 20000")))
    }
}

fn failed(error: impl std::fmt::Display) -> ApiError {
    ApiError::bad_request(error.to_string())
}

fn to_json(value: &impl serde::Serialize) -> ApiResult {
    serde_json::to_value(value).map(Json).map_err(ApiError::internal)
}

#[derive(Deserialize)]
pub struct OwnerBody {
    owner: String,
}

/// `POST /api/device/state {owner}`: what the owner's pane shows, discovered fresh. Off a Mac it
/// answers a state naming the unsupported platform rather than an error, so the pane can say so.
pub async fn owner_state(State(state): State<AppState>, Json(body): Json<OwnerBody>) -> ApiResult {
    let owner = owner(&body.owner)?;
    match state.device.supported() {
        Some(manager) => to_json(&manager.owner_state(&owner).await),
        None => to_json(&OwnerDeviceState {
            owner,
            version: 0,
            attached_device_udid: None,
            attach_phase: None,
            devices: Vec::new(),
            agent_active: false,
            availability: DeviceAvailability::UnsupportedPlatform { platform: std::env::consts::OS.to_owned() },
            last_error: None,
        }),
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ListBody {
    #[serde(default)]
    include_shutdown: bool,
}

/// `POST /api/device/list {includeShutdown?}`.
pub async fn list(State(state): State<AppState>, body: axum::body::Bytes) -> ApiResult {
    // An empty body is `{}`.
    let include_shutdown = if body.iter().all(u8::is_ascii_whitespace) {
        false
    } else {
        serde_json::from_slice::<ListBody>(&body).map_err(failed)?.include_shutdown
    };
    to_json(&manager(&state)?.list(include_shutdown).await)
}

#[derive(Deserialize)]
pub struct UdidBody {
    udid: String,
}

/// `POST /api/device/boot {udid}`: `booted`, or `boot-limit-reached` with the candidates.
pub async fn boot(State(state): State<AppState>, Json(body): Json<UdidBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    to_json(&manager(&state)?.boot(&udid).await.map_err(failed)?)
}

/// `POST /api/device/shutdown {udid}`.
pub async fn shutdown(State(state): State<AppState>, Json(body): Json<UdidBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    manager(&state)?.shutdown(&udid).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct AttachBody {
    owner: String,
    udid: String,
}

/// `POST /api/device/attach {owner, udid}`: answers once the attachment is recorded; the stream
/// comes up behind it, reported as `device` events.
pub async fn attach(State(state): State<AppState>, Json(body): Json<AttachBody>) -> ApiResult {
    let (owner, udid) = (owner(&body.owner)?, udid(&body.udid)?);
    to_json(&manager(&state)?.attach(&owner, &udid).await)
}

/// `POST /api/device/detach {owner}`.
pub async fn detach(State(state): State<AppState>, Json(body): Json<OwnerBody>) -> ApiResult {
    let owner = owner(&body.owner)?;
    to_json(&manager(&state)?.detach(&owner).await)
}

#[derive(Deserialize)]
pub struct TapBody {
    udid: String,
    x: Option<f64>,
    y: Option<f64>,
    label: Option<String>,
    identifier: Option<String>,
    role: Option<String>,
}

/// `POST /api/device/tap {udid, x, y}` (or an element by `label`/`identifier`/`role`).
pub async fn tap(State(state): State<AppState>, Json(body): Json<TapBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    let manager = manager(&state)?;
    let blank = |value: Option<String>| value.map(|value| value.trim().to_owned()).filter(|value| !value.is_empty());
    let request = read_tap_request(&DeviceTapInput {
        x: body.x,
        y: body.y,
        label: blank(body.label),
        identifier: blank(body.identifier),
        role: blank(body.role),
    })
    .map_err(failed)?;
    match request {
        DeviceTapRequest::Point { x, y } => {
            manager.tap(&udid, coordinate("x", x)?, coordinate("y", y)?, None).await.map_err(failed)?;
        }
        DeviceTapRequest::Element(target) => {
            manager.tap_element(&udid, &target, None, None).await.map_err(failed)?;
        }
    }
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwipeBody {
    udid: String,
    from_x: f64,
    from_y: f64,
    to_x: f64,
    to_y: f64,
    duration_ms: u32,
}

/// `POST /api/device/swipe {udid, fromX, fromY, toX, toY, durationMs}`.
pub async fn swipe(State(state): State<AppState>, Json(body): Json<SwipeBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    if body.duration_ms > DEVICE_SWIPE_DURATION_MAX_MS {
        return Err(ApiError::bad_request("durationMs must be between 0 and 10000"));
    }
    let gesture = DeviceSwipeGesture {
        from_x: coordinate("fromX", body.from_x)?,
        from_y: coordinate("fromY", body.from_y)?,
        to_x: coordinate("toX", body.to_x)?,
        to_y: coordinate("toY", body.to_y)?,
        duration_ms: body.duration_ms,
        edge: None,
    };
    manager(&state)?.swipe(&udid, gesture).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct TouchBody {
    udid: String,
    phase: String,
    x: f64,
    y: f64,
}

/// `POST /api/device/touch {udid, phase, x, y}`: one step of a drag the user is making, `phase`
/// `down`, `move` or `up`, so the screen follows the pointer rather than replaying the drag after
/// it ends. Cascade's own; the pane sends a drag's steps in order, one at a time.
pub async fn touch(State(state): State<AppState>, Json(body): Json<TouchBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    let phase = match body.phase.as_str() {
        "down" => DeviceTouchPhase::Down,
        "move" => DeviceTouchPhase::Move,
        "up" => DeviceTouchPhase::Up,
        _ => return Err(ApiError::bad_request("phase must be one of down, move, up")),
    };
    let (x, y) = (coordinate("x", body.x)?, coordinate("y", body.y)?);
    manager(&state)?.touch(&udid, phase, x, y).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct TypeBody {
    udid: String,
    text: String,
}

/// `POST /api/device/type {udid, text}`: keystrokes for printable ASCII.
pub async fn type_text(State(state): State<AppState>, Json(body): Json<TypeBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    if body.text.chars().count() > TEXT_MAX_LENGTH {
        return Err(ApiError::bad_request("text is longer than 4096 characters"));
    }
    manager(&state)?.type_text(&udid, &body.text).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyBody {
    udid: String,
    key_code: u16,
    #[serde(default)]
    modifiers: Vec<DeviceKeyModifier>,
    direction: DeviceKeyDirection,
}

/// `POST /api/device/key {udid, keyCode, modifiers, direction}`: one HID key, down or up, so held
/// keys and repeats survive the hop.
pub async fn key(State(state): State<AppState>, Json(body): Json<KeyBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    if body.modifiers.len() > 5 {
        return Err(ApiError::bad_request("at most five modifiers"));
    }
    let event = DeviceKeyEvent { key_code: body.key_code, modifiers: body.modifiers, direction: body.direction };
    manager(&state)?.key_event(&udid, &event).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct ButtonBody {
    udid: String,
    button: DeviceHardwareButton,
}

/// `POST /api/device/button {udid, button}`: home, lock, volume-up, volume-down (`rotate` is
/// refused by the backend).
pub async fn button(State(state): State<AppState>, Json(body): Json<ButtonBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    manager(&state)?.press_button(&udid, body.button).await.map_err(failed)?;
    Ok(Json(json!({})))
}

#[derive(Deserialize)]
pub struct FramesBody {
    #[allow(dead_code)]
    #[serde(default)]
    owner: Option<String>,
    udid: String,
}

/// `POST /api/device/frames {owner, udid}` → `{socketPath}`: the Unix socket that streams the
/// device to every viewer connected to it (see `frames.rs`).
pub async fn frames(State(state): State<AppState>, Json(body): Json<FramesBody>) -> ApiResult {
    let udid = udid(&body.udid)?;
    let manager = manager(&state)?;
    let path = state.device.sockets().socket_for(&manager, &udid).map_err(ApiError::internal)?;
    Ok(Json(json!({ "socketPath": path.to_string_lossy() })))
}
