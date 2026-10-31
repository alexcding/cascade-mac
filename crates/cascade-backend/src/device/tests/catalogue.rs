//! Screen geometry and product family, known before boot.
//!
//! Ported from `apps/server/src/device/deviceTypeCatalogue.test.ts`. Commands run through
//! `cli::scoped` with a scripted runner. The "unreadable profile" case there throws from a
//! `run` that cannot start; `cli` has no way to script a failure to start, so it is scripted as
//! `plutil` exiting non-zero, which the catalogue treats the same way.

use std::{ffi::OsString, sync::Arc, time::Duration};

use crate::{
    cli::{self, Failed, ScriptedRunner},
    device::{
        catalogue::{
            parse_device_type_profile, parse_simctl_device_types, read_device_type_catalogue, DeviceTypeProfile,
            ParsedDeviceType,
        },
        contracts::{DeviceFamily, DeviceGeometry},
    },
};

const IPHONE: &str = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro";
const IPAD: &str = "com.apple.CoreSimulator.SimDeviceType.iPad-A16";

fn device_types() -> String {
    serde_json::json!({
        "devicetypes": [
            {
                "identifier": IPHONE,
                "productFamily": "iPhone",
                "bundlePath": "/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype",
            },
            {
                "identifier": IPAD,
                "productFamily": "iPad",
                "bundlePath": "/Profiles/DeviceTypes/iPad (A16).simdevicetype",
            },
            // A watch: no chassis to draw it in, so it is skipped rather than made a phone.
            {
                "identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch",
                "productFamily": "Apple Watch",
                "bundlePath": "/Profiles/DeviceTypes/Apple Watch.simdevicetype",
            },
            { "identifier": "no-bundle", "productFamily": "iPhone" },
        ],
    })
    .to_string()
}

fn profile(width: u32, height: u32, scale: u32) -> String {
    serde_json::json!({ "mainScreenWidth": width, "mainScreenHeight": height, "mainScreenScale": scale }).to_string()
}

fn geometry(point_width: f64, point_height: f64, scale: f64) -> DeviceGeometry {
    DeviceGeometry { point_width, point_height, scale }
}

fn last_argument(args: &[OsString]) -> String {
    args.last().map(|argument| argument.to_string_lossy().into_owned()).unwrap_or_default()
}

// parseSimctlDeviceTypes

#[test]
fn keeps_the_device_types_the_pane_can_draw_and_resolves_their_profiles() {
    assert_eq!(
        parse_simctl_device_types(&device_types()),
        vec![
            ParsedDeviceType {
                identifier: IPHONE.into(),
                family: DeviceFamily::Phone,
                profile_path: "/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype/Contents/Resources/profile.plist"
                    .into(),
            },
            ParsedDeviceType {
                identifier: IPAD.into(),
                family: DeviceFamily::Tablet,
                profile_path: "/Profiles/DeviceTypes/iPad (A16).simdevicetype/Contents/Resources/profile.plist"
                    .into(),
            },
        ]
    );
}

#[test]
fn survives_output_that_is_not_the_json_it_expected() {
    assert_eq!(parse_simctl_device_types("xcrun: error"), Vec::new());
    assert_eq!(parse_simctl_device_types(&serde_json::json!({ "devicetypes": null }).to_string()), Vec::new());
}

// parseDeviceTypeProfile

#[test]
fn converts_the_profiles_pixel_screen_into_the_points_input_is_injected_in() {
    // The exact iPhone 17 Pro geometry the helper reports once it attaches, so the pre-boot value
    // never has to be corrected downward.
    assert_eq!(parse_device_type_profile(&profile(1206, 2622, 3)), Some(geometry(402.0, 874.0, 3.0)));
}

#[test]
fn yields_nothing_rather_than_a_half_filled_guess() {
    assert_eq!(
        parse_device_type_profile(&serde_json::json!({ "mainScreenWidth": 1206, "mainScreenScale": 3 }).to_string()),
        None
    );
    assert_eq!(parse_device_type_profile(&profile(0, 2622, 3)), None);
    assert_eq!(parse_device_type_profile("not json"), None);
}

// readDeviceTypeCatalogue

#[tokio::test]
async fn pairs_each_device_type_with_its_geometry() {
    let runner = ScriptedRunner::new()
        .on("xcrun", |_| Some(Ok(device_types().into_bytes())))
        .on("plutil", |args| {
            let path = last_argument(args);
            Some(Ok(if path.contains("iPad") { profile(1640, 2360, 2) } else { profile(1206, 2622, 3) }.into_bytes()))
        });
    let runner = Arc::new(runner);

    let catalogue = cli::scoped(runner.clone(), read_device_type_catalogue(&[])).await;

    assert_eq!(
        catalogue.get(IPHONE),
        Some(&DeviceTypeProfile { family: DeviceFamily::Phone, geometry: geometry(402.0, 874.0, 3.0) })
    );
    assert_eq!(
        catalogue.get(IPAD),
        Some(&DeviceTypeProfile { family: DeviceFamily::Tablet, geometry: geometry(820.0, 1180.0, 2.0) })
    );
    assert_eq!(catalogue.len(), 2);

    // One listing, then a plutil per drawable device type, reading the profile as JSON.
    let asked = runner.asked.lock().unwrap();
    let programs: Vec<&str> = asked.iter().map(|invocation| invocation.program.as_str()).collect();
    assert_eq!(programs.iter().filter(|program| **program == "xcrun").count(), 1);
    assert_eq!(programs.iter().filter(|program| **program == "plutil").count(), 2);
    let listing = asked.iter().find(|invocation| invocation.program == "xcrun").unwrap();
    assert_eq!(listing.args, ["simctl", "list", "devicetypes", "--json"].map(OsString::from));
    assert_eq!(listing.duration, Duration::from_secs(30));
}

#[tokio::test]
async fn drops_one_unreadable_profile_rather_than_losing_the_whole_catalogue() {
    let runner = ScriptedRunner::new()
        .on("xcrun", |_| Some(Ok(device_types().into_bytes())))
        .on("plutil", |args| {
            let path = last_argument(args);
            if path.contains("iPad") {
                return Some(Err(Failed::from("profile.plist is missing")));
            }
            Some(Ok(profile(1206, 2622, 3).into_bytes()))
        });

    let catalogue = cli::scoped(Arc::new(runner), read_device_type_catalogue(&[])).await;

    assert!(catalogue.contains_key(IPHONE));
    assert!(!catalogue.contains_key(IPAD));
}

#[tokio::test]
async fn drops_a_profile_that_times_out_or_is_not_a_screen() {
    let runner = ScriptedRunner::new()
        .on("xcrun", |_| Some(Ok(device_types().into_bytes())))
        .on("plutil", |args| {
            let path = last_argument(args);
            if path.contains("iPad") {
                return Some(Err(Failed::timed_out("plutil", Duration::from_secs(10))));
            }
            Some(Ok(b"{}".to_vec()))
        });

    let catalogue = cli::scoped(Arc::new(runner), read_device_type_catalogue(&[])).await;

    assert!(catalogue.is_empty());
}

#[tokio::test]
async fn is_empty_when_the_device_type_listing_itself_fails() {
    let runner = ScriptedRunner::new().on("xcrun", |_| Some(Err(Failed::from("xcrun: error"))));
    let runner = Arc::new(runner);

    let catalogue = cli::scoped(runner.clone(), read_device_type_catalogue(&[])).await;

    assert!(catalogue.is_empty());
    // Nothing was listed, so no profile is read.
    assert!(runner.asked.lock().unwrap().iter().all(|invocation| invocation.program == "xcrun"));
}
