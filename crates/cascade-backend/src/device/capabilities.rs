//! Parsing and interpretation of the device helper's `--probe` output.
//!
//! Port of Synara's `apps/server/src/device/helperCapabilities.ts`. The helper reports each
//! capability (framebuffer, hid, accessibility, encoder) separately, because the private symbols
//! behind them move independently between Xcode releases. Keeping the parse and the availability
//! mapping away from process spawning lets both be tested against synthetic probe payloads.

use serde_json::Value;

use super::{
    backend::fit_device_message,
    contracts::{DeviceAvailability, DeviceCapabilityId, DeviceCapabilityStatus, DeviceToolchain},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HelperProbeResult {
    pub ok: bool,
    pub capabilities: Vec<DeviceCapabilityStatus>,
    pub toolchain: Option<DeviceToolchain>,
    /// A whole-helper failure (frameworks would not load, CoreSimulator unreachable).
    pub error: Option<String>,
}

const UNREADABLE: &str = "The device helper preflight returned unreadable output.";

fn non_empty(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::trim).filter(|text| !text.is_empty()).map(str::to_owned)
}

fn parse_toolchain(value: Option<&Value>) -> Option<DeviceToolchain> {
    let record = value?.as_object()?;
    let toolchain = DeviceToolchain {
        xcode_version: non_empty(record.get("xcodeVersion")),
        xcode_build: non_empty(record.get("xcodeBuild")),
        mac_os: non_empty(record.get("macOS")),
    };
    (toolchain != DeviceToolchain::default()).then_some(toolchain)
}

/// One capability entry: `"ok"`, or an object naming what failed. An entry the helper did not
/// report at all is broken rather than assumed working — an older helper genuinely cannot
/// provide it.
fn parse_capability(id: DeviceCapabilityId, raw: Option<&Value>) -> DeviceCapabilityStatus {
    if raw.and_then(Value::as_str) == Some("ok") {
        return DeviceCapabilityStatus::ok(id);
    }
    let Some(record) = raw.and_then(Value::as_object) else {
        return DeviceCapabilityStatus {
            id,
            ok: false,
            missing_symbol: None,
            detail: Some("The device helper did not report this capability.".into()),
        };
    };
    DeviceCapabilityStatus {
        id,
        ok: false,
        missing_symbol: non_empty(record.get("missingSymbol")),
        detail: non_empty(record.get("error")).or_else(|| non_empty(record.get("purpose"))),
    }
}

fn unreadable() -> HelperProbeResult {
    HelperProbeResult {
        ok: false,
        capabilities: DeviceCapabilityId::ALL
            .iter()
            .map(|&id| DeviceCapabilityStatus { id, ok: false, missing_symbol: None, detail: Some(UNREADABLE.into()) })
            .collect(),
        toolchain: None,
        error: Some(UNREADABLE.into()),
    }
}

/// Parses `--probe` stdout. Never fails: a helper that emits garbage is a degraded helper, and
/// the pane must render that.
pub fn parse_helper_probe(stdout: &str) -> HelperProbeResult {
    let Ok(parsed) = serde_json::from_str::<Value>(stdout.trim()) else {
        return unreadable();
    };
    let Some(record) = parsed.as_object() else {
        return unreadable();
    };
    let error = non_empty(record.get("error"));
    // A helper too old to report capabilities still answers `ok`; trust that rather than
    // reporting four phantom breakages.
    let Some(capabilities) = record.get("capabilities").and_then(Value::as_object) else {
        let ok = record.get("ok") == Some(&Value::Bool(true));
        return HelperProbeResult {
            ok,
            capabilities: Vec::new(),
            toolchain: parse_toolchain(record.get("toolchain")),
            error: if ok { None } else { Some(error.unwrap_or_else(|| "The device helper preflight failed.".into())) },
        };
    };
    let capabilities: Vec<DeviceCapabilityStatus> =
        DeviceCapabilityId::ALL.iter().map(|&id| parse_capability(id, capabilities.get(id.key()))).collect();
    HelperProbeResult {
        ok: record.get("ok") == Some(&Value::Bool(true)) && capabilities.iter().all(|capability| capability.ok),
        capabilities,
        toolchain: parse_toolchain(record.get("toolchain")),
        error,
    }
}

/// Maps a probe onto the availability the pane renders, once setup is otherwise complete. A
/// capability failure is deliberately not `setup-required`: there is nothing to install.
pub fn availability_from_probe(probe: &HelperProbeResult) -> DeviceAvailability {
    let broken: Vec<&DeviceCapabilityStatus> = probe.capabilities.iter().filter(|capability| !capability.ok).collect();
    if broken.is_empty() {
        // Frameworks that would not load at all leave no per-capability detail; that is a helper
        // failure, not a degraded one.
        if let (false, Some(error)) = (probe.ok, &probe.error) {
            return DeviceAvailability::HelperUnavailable { message: fit_device_message(error) };
        }
        return if probe.capabilities.is_empty() {
            DeviceAvailability::available()
        } else {
            DeviceAvailability::Available {
                capabilities: Some(probe.capabilities.clone()),
                toolchain: probe.toolchain.clone(),
            }
        };
    }
    // Everything broken means the helper is unusable, not partially usable.
    if broken.len() == probe.capabilities.len() {
        let message = probe
            .error
            .clone()
            .unwrap_or_else(|| describe_broken_capabilities(&broken, probe.toolchain.as_ref()));
        return DeviceAvailability::HelperUnavailable { message: fit_device_message(&message) };
    }
    DeviceAvailability::Degraded { capabilities: probe.capabilities.clone(), toolchain: probe.toolchain.clone() }
}

/// Names the toolchain a failure was measured on, when the helper reported it.
pub fn describe_toolchain(toolchain: Option<&DeviceToolchain>) -> String {
    let Some(toolchain) = toolchain else {
        return String::new();
    };
    match (&toolchain.xcode_version, &toolchain.xcode_build) {
        (Some(version), Some(build)) => format!("Xcode {version} ({build})"),
        (Some(version), None) => format!("Xcode {version}"),
        (None, Some(build)) => format!("Xcode build {build}"),
        (None, None) => String::new(),
    }
}

/// A one-line summary of what is broken, for logs and error messages.
pub fn describe_broken_capabilities(broken: &[&DeviceCapabilityStatus], toolchain: Option<&DeviceToolchain>) -> String {
    let names: Vec<String> = broken.iter().map(|capability| capability.id.label().to_lowercase()).collect();
    let list = match names.as_slice() {
        [] => String::new(),
        [one] => one.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    };
    let place = describe_toolchain(toolchain);
    if place.is_empty() {
        format!("{list} unavailable")
    } else {
        format!("{list} unavailable with {place}")
    }
}

/// The error an operation raises when the capability behind it is broken: it names the
/// capability and the Xcode it broke on, because the actionable fact is "this Xcode moved a
/// symbol", not "the call failed".
pub fn capability_unavailable_message(capability: &DeviceCapabilityStatus, toolchain: Option<&DeviceToolchain>) -> String {
    let label = capability.id.label();
    let place = describe_toolchain(toolchain);
    let because = match (&capability.missing_symbol, &capability.detail) {
        (Some(symbol), _) => format!(" The device helper could not resolve '{symbol}'."),
        (None, Some(detail)) => format!(" {detail}"),
        (None, None) => String::new(),
    };
    let place = if place.is_empty() { String::new() } else { format!(" with {place}") };
    format!("{label} is unavailable{place}.{because}")
}

/// A probe payload as JSON, for tests that play the helper.
#[cfg(test)]
pub(crate) fn probe_payload(ok: bool, capabilities: &[(DeviceCapabilityId, Value)], toolchain: Value) -> Value {
    let mut map = serde_json::Map::new();
    for (id, value) in capabilities {
        map.insert(id.key().to_owned(), value.clone());
    }
    serde_json::json!({ "ok": ok, "protocolVersion": 1, "toolchain": toolchain, "capabilities": map })
}
