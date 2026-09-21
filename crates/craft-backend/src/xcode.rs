//! Everything that knows how Xcode works: finding what `xcodebuild` should open, the
//! schemes it offers, the destinations a scheme runs on and the settings of a build.
//! Another IDE gets a module of its own beside this one; `local.rs` only decides which
//! file an IDE opens.

use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use axum::{extract::Query, http::HeaderMap, Json};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    cli,
    error::ApiError,
    local::{foreign_origin, resolve_launch, resolve_path},
};

type ApiResult<T> = Result<Json<T>, ApiError>;

#[derive(Default, Deserialize)]
pub struct XcodeQuery {
    path: Option<String>,
    rel: Option<String>,
    scheme: Option<String>,
    /// The destination's id. The name predates Macs and devices.
    sim: Option<String>,
    configuration: Option<String>,
}

fn target_args(target: &Path) -> Vec<String> {
    let value = target.to_string_lossy();
    if value.ends_with(".xcworkspace") {
        vec!["-workspace".into(), value.into_owned()]
    } else if value.ends_with(".xcodeproj") {
        vec!["-project".into(), value.into_owned()]
    } else {
        vec![]
    }
}
fn xcode_cwd(root: &Path, target: &Path) -> PathBuf {
    if target_args(target).is_empty() {
        if target.file_name().and_then(|v| v.to_str()) == Some("Package.swift") {
            target.parent().unwrap_or(root).to_path_buf()
        } else {
            target.to_path_buf()
        }
    } else {
        root.to_path_buf()
    }
}
fn xcode_request(query: &XcodeQuery) -> Result<(PathBuf, PathBuf), ApiError> {
    let raw = query
        .path
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(raw);
    let (target, _) = resolve_launch(&root, query.rel.as_deref().unwrap_or(""), "xcode")?;
    Ok((root, target))
}

/// What Xcode resolves before a fresh checkout can build: the Swift package graph. Every
/// worktree is a path Xcode has never seen, so this is paid once per worktree, and paying it
/// during the build is what reads as a hang.
///
/// No `Package.resolved` means no packages to fetch, and no plan — an Xcode project without
/// dependencies never spawns anything.
pub(crate) fn warmup_plan(root: &Path, rel: &str) -> Option<crate::warmup::Plan> {
    const LABEL: &str = "Resolving Swift packages";
    let (target, _) = resolve_launch(root, rel, "xcode").ok()?;
    if target.file_name().and_then(|v| v.to_str()) == Some("Package.swift") {
        let cwd = target.parent()?.to_path_buf();
        let stamp = cwd.join("Package.resolved");
        return stamp.exists().then(|| crate::warmup::Plan {
            label: LABEL,
            program: "swift",
            args: vec!["package".into(), "resolve".into()],
            cwd,
            stamp,
        });
    }
    let document = target_args(&target);
    if document.is_empty() {
        return None;
    }
    let stamp = resolved_versions(&target)?;
    let mut args = vec!["-resolvePackageDependencies".to_string()];
    args.extend(document);
    Some(crate::warmup::Plan {
        label: LABEL,
        program: "xcodebuild",
        args,
        cwd: root.to_path_buf(),
        stamp,
    })
}

/// Where Xcode keeps the versions it resolved: inside the workspace, or inside the implicit
/// workspace every project carries.
fn resolved_versions(target: &Path) -> Option<PathBuf> {
    let name = target.file_name()?.to_str()?;
    let base = if name.ends_with(".xcworkspace") {
        target.to_path_buf()
    } else {
        target.join("project.xcworkspace")
    };
    let path = base.join("xcshareddata/swiftpm/Package.resolved");
    path.exists().then_some(path)
}

pub async fn schemes(
    headers: HeaderMap,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let (root, target) = xcode_request(&query)?;
    let mut args = vec!["-list".into(), "-json".into()];
    args.extend(target_args(&target));
    let raw = cli::run_in(
        "xcodebuild",
        args,
        Duration::from_secs(90),
        Some(&xcode_cwd(&root, &target)),
    )
    .await
    .map_err(ApiError::internal)?;
    let parsed: Value = serde_json::from_str(&raw).map_err(ApiError::internal)?;
    let info = parsed
        .get("workspace")
        .or_else(|| parsed.get("project"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    Ok(Json(
        json!({"target":target,"name":info["name"],"schemes":info["schemes"],"targets":info["targets"],"configurations":info["configurations"]}),
    ))
}

/// The run destinations a scheme accepts, read from `xcodebuild -showdestinations`.
/// Placeholders ("Any Mac") and variants that share My Mac's id are left out, as is
/// the second architecture of the same machine.
fn parse_destinations(raw: &str) -> Vec<Value> {
    let field = Regex::new(r"(?:^|, )(platform|arch|variant|id|OS|name|error):").unwrap();
    let mut list = Vec::<Value>::new();
    let mut compatible = false;
    for line in raw.lines().map(str::trim) {
        if !line.starts_with('{') {
            let heading = line.to_lowercase();
            if heading.contains("destinations") {
                compatible = !heading.contains("incompatible")
                    && !heading.contains("ineligible")
                    && (heading.contains("compatible") || heading.contains("available"));
            }
            continue;
        }
        if !compatible {
            continue;
        }
        let body = line.trim_start_matches('{').trim_end_matches('}').trim();
        let marks: Vec<_> = field.captures_iter(body).collect();
        let mut entry = std::collections::HashMap::new();
        for (index, mark) in marks.iter().enumerate() {
            let from = mark.get(0).unwrap().end();
            let to = marks
                .get(index + 1)
                .map_or(body.len(), |next| next.get(0).unwrap().start());
            entry.insert(mark.get(1).unwrap().as_str(), body[from..to].trim());
        }
        let (Some(id), Some(name), Some(platform)) =
            (entry.get("id"), entry.get("name"), entry.get("platform"))
        else {
            continue;
        };
        if id.starts_with("dvtdevice-")
            || entry.contains_key("variant")
            || entry.contains_key("error")
            || list.iter().any(|seen| seen["udid"] == *id)
        {
            continue;
        }
        let kind = if platform.ends_with("Simulator") {
            "simulator"
        } else if *platform == "macOS" {
            "mac"
        } else {
            "device"
        };
        let system = platform.trim_end_matches(" Simulator");
        let runtime = entry
            .get("OS")
            .map_or_else(|| system.to_owned(), |os| format!("{system} {os}"));
        list.push(json!({"udid":id,"name":name,"platform":platform,"runtime":runtime,"kind":kind}));
    }
    list
}

pub async fn destinations(
    headers: HeaderMap,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let scheme = query
        .scheme
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("scheme required"))?;
    let (root, target) = xcode_request(&query)?;
    let mut args = vec!["-showdestinations".into()];
    args.extend(target_args(&target));
    args.extend(["-scheme".into(), scheme.into()]);
    let raw = cli::run_in(
        "xcodebuild",
        args,
        Duration::from_secs(90),
        Some(&xcode_cwd(&root, &target)),
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(Value::Array(parse_destinations(&raw))))
}

pub async fn build_settings(
    headers: HeaderMap,
    Query(query): Query<XcodeQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let scheme = query
        .scheme
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("scheme required"))?;
    let sim = query
        .sim
        .as_deref()
        .map(str::trim)
        .filter(|v| Regex::new(r"^[0-9A-Fa-f-]{16,}$").unwrap().is_match(v))
        .ok_or_else(|| ApiError::bad_request("sim (a destination id) required"))?;
    let (root, target) = xcode_request(&query)?;
    let configuration = query
        .configuration
        .as_deref()
        .filter(|v| !v.is_empty())
        .unwrap_or("Debug");
    let mut args = vec!["-showBuildSettings".into(), "-json".into()];
    args.extend(target_args(&target));
    args.extend([
        "-scheme".into(),
        scheme.into(),
        "-configuration".into(),
        configuration.into(),
        "-destination".into(),
        format!("id={sim}"),
    ]);
    let raw = cli::run_in(
        "xcodebuild",
        args,
        Duration::from_secs(90),
        Some(&xcode_cwd(&root, &target)),
    )
    .await
    .map_err(ApiError::internal)?;
    let list: Value = serde_json::from_str(&raw).map_err(ApiError::internal)?;
    let entries = list
        .as_array()
        .ok_or_else(|| ApiError::internal("Invalid xcodebuild response"))?;
    let entry = entries
        .iter()
        .find(|e| {
            e["buildSettings"]["FULL_PRODUCT_NAME"]
                .as_str()
                .is_some_and(|v| v.ends_with(".app"))
        })
        .or_else(|| entries.first())
        .ok_or_else(|| ApiError::internal(format!("Scheme {scheme} builds no app")))?;
    let settings = &entry["buildSettings"];
    let product = settings["FULL_PRODUCT_NAME"].as_str().unwrap_or("");
    let directory = settings["BUILT_PRODUCTS_DIR"].as_str().unwrap_or("");
    if product.is_empty() || directory.is_empty() {
        return Err(ApiError::internal(format!("Scheme {scheme} builds no app")));
    }
    Ok(Json(
        json!({"appPath":Path::new(directory).join(product),"executablePath":Path::new(directory).join(settings["EXECUTABLE_PATH"].as_str().unwrap_or("")),"platform":settings["PLATFORM_NAME"],"bundleId":settings["PRODUCT_BUNDLE_IDENTIFIER"],"productName":product,"target":target,"configuration":configuration}),
    ))
}

#[cfg(test)]
mod tests {
    use super::parse_destinations;

    #[test]
    fn keeps_only_what_the_scheme_can_run_on() {
        let raw = "\tDestinations compatible with the \"App\" scheme:\n\
            \t\t{ platform:macOS, arch:arm64, id:00006041-000811C00204801C, name:My Mac }\n\
            \t\t{ platform:macOS, arch:x86_64, id:00006041-000811C00204801C, name:My Mac }\n\
            \t\t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006041-000811C00204801D, name:My Mac }\n\
            \t\t{ platform:macOS, name:Any Mac }\n\
            \t\t{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }\n\
            \t\t{ platform:iOS, arch:arm64, id:00008140-001A2B3C4D5E6F70, name:Chen's iPhone }\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:3E138F84-2AE2-448B-A707-711F689819E4, OS:27.0, name:iPad Pro 11-inch (M5), 2nd }\n\
            \n\tDestinations incompatible with the \"App\" scheme:\n\
            \t\t{ platform:iOS Simulator, arch:arm64, id:1FA32F68-3F28-4AD5-A311-D6DDD0374FE1, OS:27.0, name:iPad (A16), error:iPad (A16)'s platform doesn't match. }\n";
        let list = parse_destinations(raw);
        let kinds: Vec<_> = list.iter().map(|d| d["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["mac", "device", "simulator"]);
        assert_eq!(list[2]["name"], "iPad Pro 11-inch (M5), 2nd");
        assert_eq!(list[2]["runtime"], "iOS 27.0");
        assert_eq!(list[0]["runtime"], "macOS");
    }

    #[test]
    fn reads_the_older_available_heading() {
        let raw = "Available destinations for the \"App\" scheme:\n\
            { platform:macOS, arch:arm64, id:0000-1, name:My Mac }\n\
            Ineligible destinations for the \"App\" scheme:\n\
            { platform:iOS, id:0000-2, name:Phone, error:locked }\n";
        assert_eq!(parse_destinations(raw).len(), 1);
    }
}

