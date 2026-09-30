//! Which IDE a checkout is for, and opening it there.

use super::*;

/// Folders that hold dependencies or build output, never the project itself. Both the Xcode
/// project probe and the Xcode project fingerprint walk past them.
pub(crate) const PROJECT_WALK_SKIP: &[&str] = &[
    ".git",
    "node_modules",
    "Pods",
    "Carthage",
    "DerivedData",
    "build",
    ".build",
    "vendor",
    "fastlane",
    ".gradle",
    "dist",
];

fn xcode_target(root: &Path) -> Option<PathBuf> {
    let mut level = vec![root.to_path_buf()];
    for _ in 0..=2 {
        let mut next = Vec::new();
        let mut workspaces = Vec::new();
        let mut projects = Vec::new();
        let mut packages = Vec::new();
        for directory in level {
            let Ok(entries) = fs::read_dir(&directory) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.ends_with(".xcworkspace") {
                    workspaces.push(path);
                } else if name.ends_with(".xcodeproj") {
                    projects.push(path);
                } else if name == "Package.swift" && path.is_file() {
                    packages.push(path);
                } else if path.is_dir()
                    && !name.starts_with('.')
                    && !PROJECT_WALK_SKIP.contains(&name.as_str())
                {
                    next.push(path);
                }
            }
        }
        workspaces.sort();
        projects.sort();
        packages.sort();
        if let Some(hit) = workspaces
            .into_iter()
            .next()
            .or_else(|| projects.into_iter().next())
            .or_else(|| packages.into_iter().next())
        {
            return Some(hit);
        }
        next.sort();
        level = next;
    }
    None
}

/// A best guess at a new project's IDE, covering the common cases only: an Apple project opens
/// in Xcode, an Android one in Android Studio, a web one in VS Code. "" for anything else, and
/// the user picks.
pub(crate) fn detect_ide(root: &Path) -> &'static str {
    let has = |rel: &str| root.join(rel).exists();
    let android = has("app/src/main/AndroidManifest.xml")
        || ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
            .iter()
            .any(|file| fs::read_to_string(root.join(file)).is_ok_and(|text| text.contains("com.android")));
    if xcode_target(root).is_some() {
        "xcode"
    } else if android {
        "android"
    } else if has("package.json") || has(".vscode") {
        "vscode"
    } else {
        ""
    }
}

pub(crate) fn resolve_launch(root: &Path, rel: &str, kind: &str) -> Result<(PathBuf, &'static str), ApiError> {
    let metadata = fs::metadata(root).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ApiError::not_found("not found")
        } else {
            ApiError::internal(error)
        }
    })?;
    if !metadata.is_dir() {
        return Ok((root.to_path_buf(), "path"));
    }
    let rel = rel.trim().trim_start_matches('/');
    if !rel.is_empty()
        && !Path::new(rel)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        let configured = root.join(rel);
        if configured.exists() {
            return Ok((configured, "configured"));
        }
    }
    if kind == "xcode" {
        if let Some(found) = xcode_target(root) {
            return Ok((found, "probe"));
        }
    }
    Ok((root.to_path_buf(), "folder"))
}

/// How long opening Xcode waits for a warm-up still resolving the worktree. Past it Xcode opens
/// anyway: it was asked for, and it resolves on its own. Inside the app's 130-second timeout
/// for the launch target.
const IDE_SETTLE: Duration = Duration::from_secs(120);

pub async fn launch_target(
    headers: HeaderMap,
    State(app): State<AppState>,
    Query(query): Query<LocalQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = query
        .path
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(&raw);
    let kind = query.kind.as_deref().unwrap_or("");
    if kind == "xcode" {
        // Xcode resolves the package graph as soon as it opens the project. If a warm-up is
        // still cloning into the same checkouts, the two collide and the worktree breaks.
        let deadline = tokio::time::Instant::now() + IDE_SETTLE;
        app.warmup.settle(&root.to_string_lossy(), deadline).await;
    }
    let (path, source) = resolve_launch(&root, query.rel.as_deref().unwrap_or(""), kind)?;
    Ok(Json(json!({"path":path,"source":source})))
}

#[cfg(test)]
mod detect_ide_tests {
    use super::detect_ide;
    use std::fs;

    /// A checkout holding `entries`: a trailing `/` makes a folder, anything else a file.
    fn guess(entries: &[(&str, &str)]) -> &'static str {
        let dir = tempfile::tempdir().unwrap();
        for (entry, contents) in entries {
            let path = dir.path().join(entry.trim_end_matches('/'));
            if entry.ends_with('/') {
                fs::create_dir_all(path).unwrap();
            } else {
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, contents).unwrap();
            }
        }
        detect_ide(dir.path())
    }

    #[test]
    fn guesses_from_what_the_checkout_holds() {
        assert_eq!(guess(&[("ios/App.xcodeproj/", ""), ("package.json", "{}")]), "xcode");
        assert_eq!(guess(&[("Package.swift", "")]), "xcode");
        assert_eq!(guess(&[("build.gradle.kts", "id(\"com.android.application\")")]), "android");
        assert_eq!(guess(&[("app/src/main/AndroidManifest.xml", "")]), "android");
        assert_eq!(guess(&[("package.json", "{}")]), "vscode");
        assert_eq!(guess(&[(".vscode/", "")]), "vscode");
        assert_eq!(guess(&[("build.gradle", "plugins { id 'java' }")]), "");
        assert_eq!(guess(&[("README.md", ""), ("node_modules/x/X.xcodeproj/", "")]), "");
    }
}
