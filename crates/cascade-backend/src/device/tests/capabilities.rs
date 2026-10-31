//! The helper's `--probe` output and what it says about availability.
//!
//! Ported from `apps/server/src/device/helperCapabilities.test.ts`.

use serde_json::{json, Value};

use crate::device::{
    capabilities::{availability_from_probe, describe_broken_capabilities, parse_helper_probe},
    contracts::{DeviceAvailability, DeviceCapabilityId, DeviceCapabilityStatus, DeviceToolchain},
};

/// A probe payload with every capability healthy, with `overrides` laid over it.
fn healthy_probe(overrides: Value) -> String {
    let mut probe = json!({
        "ok": true,
        "protocolVersion": 1,
        "capabilities": { "framebuffer": "ok", "hid": "ok", "accessibility": "ok", "encoder": "ok" },
        "toolchain": { "xcodeVersion": "26.2", "xcodeBuild": "17C52", "macOS": "Version 26.3" },
    });
    for (key, value) in overrides.as_object().into_iter().flatten() {
        probe[key] = value.clone();
    }
    probe.to_string()
}

fn broken(id: DeviceCapabilityId) -> DeviceCapabilityStatus {
    DeviceCapabilityStatus { id, ok: false, missing_symbol: None, detail: None }
}

// parseHelperProbe

#[test]
fn reads_every_capability_and_the_toolchain_from_a_healthy_probe() {
    let probe = parse_helper_probe(&healthy_probe(json!({})));

    assert!(probe.ok);
    let ids: Vec<DeviceCapabilityId> = probe.capabilities.iter().map(|capability| capability.id).collect();
    assert_eq!(
        ids,
        vec![
            DeviceCapabilityId::Framebuffer,
            DeviceCapabilityId::Hid,
            DeviceCapabilityId::Accessibility,
            DeviceCapabilityId::Encoder
        ]
    );
    assert!(probe.capabilities.iter().all(|capability| capability.ok));
    assert_eq!(
        probe.toolchain,
        Some(DeviceToolchain {
            xcode_version: Some("26.2".into()),
            xcode_build: Some("17C52".into()),
            mac_os: Some("Version 26.3".into()),
        })
    );
}

#[test]
fn captures_the_missing_symbol_for_a_broken_capability() {
    let probe = parse_helper_probe(&healthy_probe(json!({
        "ok": false,
        "capabilities": {
            "framebuffer": "ok",
            "hid": "ok",
            "accessibility": { "missingSymbol": "AXPTranslator", "purpose": "translates the tree" },
            "encoder": "ok",
        },
    })));

    assert!(!probe.ok);
    let accessibility =
        probe.capabilities.iter().find(|entry| entry.id == DeviceCapabilityId::Accessibility).unwrap();
    assert!(!accessibility.ok);
    assert_eq!(accessibility.missing_symbol.as_deref(), Some("AXPTranslator"));
    // The others are untouched: that separation is the whole point.
    assert_eq!(probe.capabilities.iter().filter(|entry| entry.ok).count(), 3);
}

#[test]
fn treats_an_unreported_capability_as_broken_rather_than_assuming_it_works() {
    let probe = parse_helper_probe(&json!({ "ok": true, "capabilities": { "framebuffer": "ok", "hid": "ok" } }).to_string());

    // An older helper genuinely cannot provide what it never measured; claiming otherwise would
    // surface as a mystery failure at the point of use.
    let accessibility =
        probe.capabilities.iter().find(|entry| entry.id == DeviceCapabilityId::Accessibility).unwrap();
    assert!(!accessibility.ok);
    assert!(!probe.ok);
}

#[test]
fn degrades_rather_than_panicking_on_unreadable_output() {
    let probe = parse_helper_probe("not json at all");

    assert!(!probe.ok);
    assert_eq!(probe.capabilities.len(), 4);
    assert!(probe.capabilities.iter().all(|capability| !capability.ok));
    assert_eq!(
        probe.error.as_deref(),
        Some("The device helper preflight returned unreadable output.")
    );

    // JSON that is not an object is as unreadable as text that is not JSON.
    let array = parse_helper_probe("[1, 2]");
    assert!(!array.ok);
    assert_eq!(array.capabilities.len(), 4);
}

// availabilityFromProbe

#[test]
fn maps_a_total_failure_to_helper_unavailable() {
    let availability = availability_from_probe(&parse_helper_probe(&healthy_probe(json!({
        "ok": false,
        "capabilities": {
            "framebuffer": { "missingSymbol": "SimServiceContext" },
            "hid": { "missingSymbol": "IndigoHIDMessageForButton" },
            "accessibility": { "missingSymbol": "AXPTranslator" },
            "encoder": { "error": "no session" },
        },
    }))));

    // Nothing works, so this is not "partly usable" - it is a broken helper.
    assert!(matches!(availability, DeviceAvailability::HelperUnavailable { .. }), "{availability:?}");
}

#[test]
fn reports_a_framework_load_failure_as_helper_unavailable_not_degraded() {
    let availability = availability_from_probe(&parse_helper_probe(
        &json!({ "ok": false, "error": "CoreSimulator would not load" }).to_string(),
    ));

    assert_eq!(
        availability,
        DeviceAvailability::HelperUnavailable { message: "CoreSimulator would not load".into() }
    );
}

#[test]
fn stays_available_when_the_helper_predates_capability_reporting() {
    let availability = availability_from_probe(&parse_helper_probe(&json!({ "ok": true }).to_string()));

    assert_eq!(availability, DeviceAvailability::available());
}

#[test]
fn reports_a_partly_broken_helper_as_degraded() {
    let availability = availability_from_probe(&parse_helper_probe(&healthy_probe(json!({
        "ok": false,
        "capabilities": {
            "framebuffer": "ok",
            "hid": "ok",
            "accessibility": { "missingSymbol": "AXPTranslator" },
            "encoder": "ok",
        },
    }))));

    match availability {
        DeviceAvailability::Degraded { capabilities, toolchain } => {
            assert_eq!(capabilities.iter().filter(|capability| !capability.ok).count(), 1);
            assert_eq!(toolchain.and_then(|toolchain| toolchain.xcode_version).as_deref(), Some("26.2"));
        }
        other => panic!("expected degraded, got {other:?}"),
    }
}

// capability failure messages

#[test]
fn joins_several_broken_capabilities_into_one_phrase() {
    let accessibility = broken(DeviceCapabilityId::Accessibility);
    let hid = broken(DeviceCapabilityId::Hid);
    let toolchain = DeviceToolchain { xcode_version: Some("26.3".into()), ..Default::default() };

    let summary = describe_broken_capabilities(&[&accessibility, &hid], Some(&toolchain));

    assert_eq!(summary, "accessibility inspection and touch and keyboard input unavailable with Xcode 26.3");
}
