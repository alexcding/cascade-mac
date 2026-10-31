//! Screen geometry and product family, known before boot.
//!
//! Port of Synara's `apps/server/src/device/deviceTypeCatalogue.ts`. The helper reports a
//! device's real geometry only once it has attached to a booted simulator, far too late for the
//! pane to draw the right chassis. Every simulator device type ships a `profile.plist` with
//! `mainScreenWidth`/`mainScreenHeight`/`mainScreenScale`, and `simctl list devicetypes` maps each
//! type to its bundle and product family; both are readable with the device shut down. The
//! helper's attachment still wins when it disagrees: it measures the running framebuffer.

use std::{collections::HashMap, path::Path, time::Duration};

use serde_json::Value;

use super::{
    contracts::{DeviceFamily, DeviceGeometry},
    process,
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeviceTypeProfile {
    pub family: DeviceFamily,
    pub geometry: DeviceGeometry,
}

/// Identifier -> profile, as read from the installed simulator device types.
pub type DeviceTypeCatalogue = HashMap<String, DeviceTypeProfile>;

/// Apple's product families, mapped onto the two chassis the pane draws. A watch or a TV yields
/// none and is drawn from the device name, since guessing "phone" for an Apple TV is worse.
fn family_for(product_family: Option<&Value>) -> Option<DeviceFamily> {
    match product_family.and_then(Value::as_str)? {
        "iPhone" | "iPod touch" => Some(DeviceFamily::Phone),
        "iPad" => Some(DeviceFamily::Tablet),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedDeviceType {
    pub identifier: String,
    pub family: DeviceFamily,
    pub profile_path: String,
}

/// `simctl list devicetypes --json`, as the entries worth reading a profile for. Entries missing
/// an identifier, a bundle, or a family the pane can draw are dropped rather than half-filled.
pub fn parse_simctl_device_types(json: &str) -> Vec<ParsedDeviceType> {
    let Ok(parsed) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let Some(list) = parsed.get("devicetypes").and_then(Value::as_array) else {
        return Vec::new();
    };
    list.iter()
        .filter_map(|raw| {
            let identifier = raw.get("identifier").and_then(Value::as_str).filter(|value| !value.is_empty())?;
            let bundle_path = raw.get("bundlePath").and_then(Value::as_str).filter(|value| !value.is_empty())?;
            let family = family_for(raw.get("productFamily"))?;
            Some(ParsedDeviceType {
                identifier: identifier.to_owned(),
                family,
                profile_path: Path::new(bundle_path)
                    .join("Contents/Resources/profile.plist")
                    .to_string_lossy()
                    .into_owned(),
            })
        })
        .collect()
}

/// Geometry out of a device type profile, in points. A profile missing any of the three values
/// (or reporting nonsense) yields none, so a device keeps what the helper later measures rather
/// than a bad guess.
pub fn parse_device_type_profile(json: &str) -> Option<DeviceGeometry> {
    let profile = serde_json::from_str::<Value>(json).ok()?;
    let read = |key: &str| profile.get(key).and_then(Value::as_f64).filter(|value| value.is_finite() && *value > 0.0);
    let pixel_width = read("mainScreenWidth")?;
    let pixel_height = read("mainScreenHeight")?;
    let scale = read("mainScreenScale")?;
    Some(DeviceGeometry {
        point_width: super::ui_snapshot::js_round(pixel_width / scale) as f64,
        point_height: super::ui_snapshot::js_round(pixel_height / scale) as f64,
        scale,
    })
}

/// Every installed device type's family and geometry: one `simctl list devicetypes` plus a
/// `plutil` per type, so the caller caches it. One unreadable profile is skipped rather than
/// costing the geometry of the other hundred.
pub async fn read_device_type_catalogue(env: &[(String, String)]) -> DeviceTypeCatalogue {
    let listing = process::run(
        "xcrun",
        &["simctl", "list", "devicetypes", "--json"].map(String::from),
        Duration::from_secs(30),
        env,
    )
    .await;
    let Some(listing) = listing.ok().filter(process::RunResult::succeeded) else {
        return DeviceTypeCatalogue::new();
    };
    let entries = parse_simctl_device_types(&listing.stdout);
    let profiles = futures_util::future::join_all(entries.into_iter().map(|entry| async move {
        let args = ["-convert", "json", "-o", "-", &entry.profile_path].map(String::from);
        let result = process::run("plutil", &args, Duration::from_secs(10), &[]).await.ok().filter(process::RunResult::succeeded)?;
        let geometry = parse_device_type_profile(&result.stdout)?;
        Some((entry.identifier, DeviceTypeProfile { family: entry.family, geometry }))
    }))
    .await;
    profiles.into_iter().flatten().collect()
}
