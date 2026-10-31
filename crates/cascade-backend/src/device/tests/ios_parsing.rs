//! The iOS Simulator backend's pure functions: simctl output, the helper's accessibility tree,
//! PNG headers, Xcode bundle ordering and the helper's stale-descriptor failures. Ported from
//! `IosSimulatorBackend.test.ts` ("simctl device parsing", "accessibility tree normalization",
//! "png dimension reading"), `IosSimulatorBackend.betaToolchain.test.ts`
//! ("orderXcodeAppCandidates") and `IosSimulatorBackend.reboot.test.ts` ("stale descriptor
//! detection").

use base64::Engine as _;
use serde_json::{json, Value};

use crate::device::{
    catalogue::{DeviceTypeCatalogue, DeviceTypeProfile},
    contracts::{DeviceFamily, DeviceGeometry, DeviceRuntimeState, DeviceUiFrame, DeviceUiNode, DeviceUiPoint},
    ios_simulator::{
        format_runtime_identifier, is_stale_descriptor_error, normalize_ui_node, order_xcode_app_candidates,
        parse_simctl_devices, read_png_dimensions,
    },
};

fn simctl_json() -> String {
    json!({
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                { "udid": "AAAA-1111", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true },
                { "udid": "BBBB-2222", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true },
                {
                    "udid": "CCCC-3333",
                    "name": "iPhone 12",
                    "state": "Shutdown",
                    // Runtime was deleted; booting this would only fail.
                    "isAvailable": false
                }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-2": [
                { "udid": "DDDD-4444", "name": "Apple Watch", "state": "Shutting Down", "isAvailable": true }
            ]
        }
    })
    .to_string()
}

fn no_catalogue() -> DeviceTypeCatalogue {
    DeviceTypeCatalogue::new()
}

// ── simctl device parsing ────────────────────────────────────────────

#[test]
fn maps_simctl_states_onto_the_contracts_runtime_states() {
    let devices = parse_simctl_devices(&simctl_json(), &no_catalogue()).unwrap();

    let states: Vec<(&str, DeviceRuntimeState)> =
        devices.iter().map(|device| (device.udid.as_str(), device.state)).collect();
    assert_eq!(
        states,
        [
            ("AAAA-1111", DeviceRuntimeState::Booted),
            ("BBBB-2222", DeviceRuntimeState::Shutdown),
            ("DDDD-4444", DeviceRuntimeState::ShuttingDown),
        ]
    );
}

#[test]
fn drops_devices_whose_runtime_is_unavailable() {
    let devices = parse_simctl_devices(&simctl_json(), &no_catalogue()).unwrap();
    assert!(!devices.iter().any(|device| device.udid == "CCCC-3333"));
}

#[test]
fn carries_chassis_and_geometry_from_the_device_type_catalogue() {
    let payload = json!({
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [{
                "udid": "AAAA-1111",
                "name": "iPad (A16)",
                "state": "Shutdown",
                "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-A16"
            }]
        }
    })
    .to_string();
    let geometry = DeviceGeometry { point_width: 820.0, point_height: 1180.0, scale: 2.0 };
    let mut catalogue = DeviceTypeCatalogue::new();
    catalogue.insert(
        "com.apple.CoreSimulator.SimDeviceType.iPad-A16".into(),
        DeviceTypeProfile { family: DeviceFamily::Tablet, geometry },
    );

    let devices = parse_simctl_devices(&payload, &catalogue).unwrap();

    // Known with the device shut down, which is what lets the pane draw an iPad the moment it is
    // picked rather than an iPhone that resizes on first frame.
    assert_eq!(devices[0].family, Some(DeviceFamily::Tablet));
    assert_eq!(devices[0].geometry, Some(geometry));
}

#[test]
fn returns_nothing_rather_than_throwing_on_an_empty_or_shapeless_payload() {
    assert!(parse_simctl_devices(&json!({}).to_string(), &no_catalogue()).unwrap().is_empty());
    assert!(parse_simctl_devices(&json!({ "devices": null }).to_string(), &no_catalogue()).unwrap().is_empty());
}

#[test]
fn errors_on_output_that_is_not_json_at_all() {
    let error = parse_simctl_devices("xcrun: error: unable to find utility", &no_catalogue()).unwrap_err();
    assert_eq!(error.message, "Could not parse simctl device list");
}

#[test]
fn reads_the_runtime_label_from_the_runtime_identifier() {
    let devices = parse_simctl_devices(&simctl_json(), &no_catalogue()).unwrap();
    let runtimes: Vec<&str> = devices.iter().map(|device| device.runtime.as_str()).collect();
    assert_eq!(runtimes, ["iOS 26.0", "iOS 26.0", "watchOS 11.2"]);

    assert_eq!(format_runtime_identifier("com.apple.CoreSimulator.SimRuntime.iOS-26-0"), "iOS 26.0");
    assert_eq!(format_runtime_identifier("com.apple.CoreSimulator.SimRuntime.iOS-18-2"), "iOS 18.2");
    // No dash-separated version: the tail stands as it is.
    assert_eq!(format_runtime_identifier("com.apple.CoreSimulator.SimRuntime.custom"), "custom");
}

// ── accessibility tree normalization ─────────────────────────────────

fn frame(x: f64, y: f64, width: f64, height: f64) -> DeviceUiFrame {
    DeviceUiFrame { x, y, width, height }
}

#[test]
fn fills_in_the_attributes_the_helper_omits_rather_than_sending_as_null() {
    // The helper leaves absent accessibility attributes out of the object entirely; the contract
    // wants a complete frame and an explicit enabled flag.
    assert_eq!(
        normalize_ui_node(&json!({ "role": "Button" })),
        DeviceUiNode {
            role: "Button".into(),
            subrole: None,
            label: None,
            value: None,
            frame: frame(0.0, 0.0, 0.0, 0.0),
            activation_point: None,
            identifier: None,
            enabled: Some(true),
            focused: None,
            selected: None,
            placeholder: None,
            // No frame at all is the shape the helper sends for a NaN frame.
            unframed: Some(true),
            children: Vec::new(),
        }
    );
}

#[test]
fn keeps_the_identifier_and_state_a_test_targets_and_asserts_on() {
    let node = normalize_ui_node(&json!({
        "role": "TextField",
        "label": "Email",
        "value": "you@example.com",
        "placeholder": "you@example.com",
        "identifier": "email-field",
        "enabled": false,
        "focused": true,
        "frame": { "x": 24, "y": 300, "width": 345, "height": 44 },
    }));
    assert_eq!(node.identifier.as_deref(), Some("email-field"));
    assert_eq!(node.enabled, Some(false));
    assert_eq!(node.focused, Some(true));
    assert_eq!(node.placeholder.as_deref(), Some("you@example.com"));
    assert_eq!(node.unframed, None);
}

#[test]
fn clamps_text_past_the_contracts_cap_instead_of_failing_the_whole_read() {
    let node = normalize_ui_node(&json!({
        "role": "TextView",
        "value": "x".repeat(5_000),
        "frame": { "x": 0, "y": 0, "width": 10, "height": 10 },
    }));
    let value = node.value.expect("a value");
    assert_eq!(value.chars().count(), 1_024);
    assert!(value.ends_with('…'));
}

#[test]
fn keeps_a_switchs_own_activation_point_which_is_not_its_row_centre() {
    // The exact shape of a UIKit settings row: one merged element whose frame spans the row, so
    // tapping the frame centre (x=201) does nothing and only the activation point (x=336.5)
    // flips the switch.
    let node = normalize_ui_node(&json!({
        "role": "CheckBox",
        "subrole": "Switch",
        "label": "Dark Appearance",
        "value": "0",
        "frame": { "x": 36, "y": 184, "width": 330, "height": 28 },
        "activationPoint": { "x": 336.5, "y": 198 },
    }));

    assert_eq!(node.role, "CheckBox");
    assert_eq!(node.subrole.as_deref(), Some("Switch"));
    assert_eq!(node.value.as_deref(), Some("0"));
    assert_eq!(node.activation_point, Some(DeviceUiPoint { x: 336.5, y: 198.0 }));
}

#[test]
fn drops_an_activation_point_that_is_not_a_complete_pair_of_coordinates() {
    // Half a point would aim taps at (0, y): worse than having none at all.
    assert_eq!(normalize_ui_node(&json!({ "activationPoint": { "x": 12 } })).activation_point, None);
    // JSON has no NaN; a non-finite coordinate reaches the helper's reader as null.
    assert_eq!(normalize_ui_node(&json!({ "activationPoint": { "x": null, "y": 4 } })).activation_point, None);
    assert_eq!(normalize_ui_node(&json!({ "activationPoint": "336,198" })).activation_point, None);
}

#[test]
fn normalizes_the_whole_subtree() {
    let node = normalize_ui_node(&json!({
        "role": "Window",
        "children": [{ "role": "Button", "children": [{ "label": "Deep" }] }],
    }));

    let deep = &node.children[0].children[0];
    assert_eq!(deep.role, "Unknown");
    assert_eq!(deep.label.as_deref(), Some("Deep"));
}

#[test]
fn clamps_negative_sizes_and_survives_a_shapeless_node() {
    assert_eq!(normalize_ui_node(&json!({ "frame": { "width": -5, "height": 10 } })).frame, frame(0.0, 0.0, 0.0, 10.0));
    assert_eq!(normalize_ui_node(&Value::Null).role, "Unknown");
}

// ── png dimension reading ────────────────────────────────────────────

#[test]
fn reads_width_and_height_from_the_ihdr_chunk() {
    let png = base64::engine::general_purpose::STANDARD
        .decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
        .unwrap();

    assert_eq!(read_png_dimensions(&png), Some((1, 1)));
}

#[test]
fn returns_none_for_bytes_that_are_not_a_png() {
    assert_eq!(read_png_dimensions(&[0u8; 64]), None);
    assert_eq!(read_png_dimensions(b"nope"), None);
}

// ── orderXcodeAppCandidates ──────────────────────────────────────────

#[test]
fn puts_stable_first_and_ignores_non_xcode_bundles() {
    let entries: Vec<String> =
        ["Xcode-27.0.app", "Numbers.app", "Xcode.app", "Xcode-beta.app"].iter().map(|name| name.to_string()).collect();
    assert_eq!(order_xcode_app_candidates(&entries), ["Xcode.app", "Xcode-27.0.app", "Xcode-beta.app"]);
}

// ── stale descriptor detection ───────────────────────────────────────

#[test]
fn recognizes_the_helpers_dead_framebuffer_failures() {
    assert!(is_stale_descriptor_error("display has no framebuffer surface yet"));
    assert!(is_stale_descriptor_error("not attached to a simulator"));
}
