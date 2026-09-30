//! Patches: parsing a diff into hunks and discarding a chosen part of it.

use super::*;

#[derive(Default)]
struct PatchFile {
    old_path: String,
    new_path: String,
    status: &'static str,
    binary: bool,
    hunks: Vec<PatchHunk>,
}

struct PatchHunk {
    header: String,
    new_start: usize,
    lines: Vec<PatchLine>,
}

struct PatchLine {
    kind: char,
    text: String,
    no_newline: bool,
}

fn clean_patch_path(raw: &str, strip_prefix: bool) -> String {
    let mut value = raw.trim().trim_matches('"').to_owned();
    if value == "/dev/null" {
        return String::new();
    }
    if strip_prefix && (value.starts_with("a/") || value.starts_with("b/")) {
        value.drain(..2);
    }
    value
}

fn parse_patch(patch: &str) -> Vec<PatchFile> {
    let hunk_re = Regex::new(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@").unwrap();
    let mut files = Vec::new();
    let mut file: Option<PatchFile> = None;
    let mut hunk: Option<PatchHunk> = None;
    let flush_hunk = |file: &mut Option<PatchFile>, hunk: &mut Option<PatchHunk>| {
        if let (Some(file), Some(hunk)) = (file.as_mut(), hunk.take()) {
            file.hunks.push(hunk);
        }
    };
    let flush_file = |files: &mut Vec<PatchFile>, file: &mut Option<PatchFile>| {
        if let Some(file) = file.take() {
            files.push(file);
        }
    };
    for line in patch.lines() {
        if line.starts_with("diff --git ") {
            flush_hunk(&mut file, &mut hunk);
            flush_file(&mut files, &mut file);
            file = Some(PatchFile {
                status: "modified",
                ..Default::default()
            });
            continue;
        }
        let Some(_) = file.as_mut() else {
            continue;
        };
        if let Some(active) = hunk.as_mut() {
            let kind = line.chars().next().unwrap_or('\0');
            if matches!(kind, '+' | '-' | ' ') {
                active.lines.push(PatchLine {
                    kind,
                    text: line[1..].to_owned(),
                    no_newline: false,
                });
                continue;
            }
            if kind == '\\' {
                if let Some(previous) = active.lines.last_mut() {
                    previous.no_newline = true;
                }
                continue;
            }
            if line.is_empty() {
                continue;
            }
            flush_hunk(&mut file, &mut hunk);
        }
        let current = file.as_mut().unwrap();
        if let Some(captures) = hunk_re.captures(line) {
            hunk = Some(PatchHunk {
                header: line.to_owned(),
                new_start: captures[1].parse().unwrap_or(1),
                lines: Vec::new(),
            });
        } else if let Some(path) = line.strip_prefix("--- ") {
            let path = clean_patch_path(path, true);
            if path.is_empty() {
                current.status = "added";
            } else {
                current.old_path = path;
            }
        } else if let Some(path) = line.strip_prefix("+++ ") {
            let path = clean_patch_path(path, true);
            if path.is_empty() {
                current.status = "deleted";
            } else {
                current.new_path = path;
            }
        } else if let Some(path) = line.strip_prefix("rename from ") {
            current.old_path = clean_patch_path(path, false);
            current.status = "renamed";
        } else if let Some(path) = line.strip_prefix("rename to ") {
            current.new_path = clean_patch_path(path, false);
            current.status = "renamed";
        } else if line.starts_with("new file mode ") {
            current.status = "added";
        } else if line.starts_with("deleted file mode ") {
            current.status = "deleted";
        } else if line.starts_with("Binary files ") || line == "GIT binary patch" {
            current.binary = true;
        }
    }
    flush_hunk(&mut file, &mut hunk);
    flush_file(&mut files, &mut file);
    files
}

fn block_ids(hunk: &PatchHunk) -> Vec<Option<usize>> {
    let mut ids = vec![None; hunk.lines.len()];
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut last_changed: Option<usize> = None;
    for (index, line) in hunk.lines.iter().enumerate() {
        if line.kind == ' ' {
            continue;
        }
        if let (Some(last), Some(run)) = (last_changed, runs.last_mut()) {
            if index - last - 1 <= 3 {
                run.1 = index;
            } else {
                runs.push((index, index));
            }
        } else {
            runs.push((index, index));
        }
        last_changed = Some(index);
    }
    for (id, (start, end)) in runs.into_iter().enumerate() {
        for item in ids.iter_mut().take(end + 1).skip(start) {
            *item = Some(id);
        }
    }
    ids
}

fn patch_path(file: &PatchFile) -> &str {
    if file.status == "renamed" {
        &file.new_path
    } else if !file.old_path.is_empty() {
        &file.old_path
    } else {
        &file.new_path
    }
}

fn quote_patch_path(path: &str) -> String {
    if !path.bytes().any(|byte| {
        byte.is_ascii_whitespace() || byte == b'"' || byte == b'\\' || byte < 32 || byte >= 127
    }) {
        return path.to_owned();
    }
    let mut result = String::from("\"");
    for byte in path.bytes() {
        match byte {
            b'"' | b'\\' => {
                result.push('\\');
                result.push(byte as char);
            }
            32..=126 => result.push(byte as char),
            _ => result.push_str(&format!("\\{byte:03o}")),
        }
    }
    result.push('"');
    result
}

fn selected_patch(file: &PatchFile, hunk: &PatchHunk, target: usize) -> Result<String, ApiError> {
    let ids = block_ids(hunk);
    if !ids.contains(&Some(target)) {
        return Err(ApiError::conflict("This change block no longer exists"));
    }
    let other_blocks = ids.iter().flatten().any(|id| *id != target);
    let old_path = patch_path(file);
    let new_path = if file.new_path.is_empty() {
        &file.old_path
    } else {
        &file.new_path
    };
    let mut output = Vec::new();
    if !other_blocks {
        let old = if file.status == "added" {
            "/dev/null".to_owned()
        } else {
            format!("a/{old_path}")
        };
        let new = if file.status == "deleted" {
            "/dev/null".to_owned()
        } else {
            format!("b/{new_path}")
        };
        output.extend([
            format!("--- {}", quote_patch_path(&old)),
            format!("+++ {}", quote_patch_path(&new)),
            hunk.header.clone(),
        ]);
        for line in &hunk.lines {
            output.push(format!("{}{}", line.kind, line.text));
            if line.no_newline {
                output.push("\\ No newline at end of file".into());
            }
        }
    } else {
        output.extend([
            format!("--- {}", quote_patch_path(&format!("a/{old_path}"))),
            format!("+++ {}", quote_patch_path(&format!("b/{new_path}"))),
        ]);
        let mut body = Vec::new();
        let mut old_count = 0;
        let mut new_count = 0;
        for (index, line) in hunk.lines.iter().enumerate() {
            if ids[index] == Some(target) && line.kind != ' ' {
                body.push(format!("{}{}", line.kind, line.text));
                if line.kind == '-' {
                    old_count += 1;
                } else {
                    new_count += 1;
                }
            } else if line.kind != '-' {
                body.push(format!(" {}", line.text));
                old_count += 1;
                new_count += 1;
            } else {
                continue;
            }
            if line.no_newline {
                body.push("\\ No newline at end of file".into());
            }
        }
        output.push(format!(
            "@@ -{},{} +{},{} @@",
            hunk.new_start, old_count, hunk.new_start, new_count
        ));
        output.extend(body);
    }
    Ok(output.join("\n") + "\n")
}

fn validate_discard_path(root: &str, relative: &str) -> Result<(), ApiError> {
    let relative = Path::new(relative);
    if relative.is_absolute()
        || relative
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err(ApiError::bad_request("Invalid discard file path"));
    }
    let root = fs::canonicalize(root).map_err(ApiError::internal)?;
    let target = root.join(relative);
    let mut current = target.as_path();
    while current != root {
        if let Ok(metadata) = fs::symlink_metadata(current) {
            if metadata.file_type().is_symlink() {
                return Err(ApiError::forbidden(
                    "Use the terminal to discard symbolic-link changes",
                ));
            }
        }
        current = current
            .parent()
            .ok_or_else(|| ApiError::forbidden("Discard file is outside the worktree"))?;
    }
    Ok(())
}

pub async fn git_discard(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let selection = body["selection"]
        .as_array()
        .filter(|items| items.len() == 3)
        .and_then(|items| {
            Some([
                items[0].as_u64()? as usize,
                items[1].as_u64()? as usize,
                items[2].as_u64()? as usize,
            ])
        })
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let revision = body["revision"]
        .as_str()
        .filter(|value| Regex::new(r"^[a-f0-9]{64}$").unwrap().is_match(value))
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let mode = body["mode"]
        .as_str()
        .filter(|value| matches!(*value, "preview" | "apply"))
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let snapshot = match git(
        dir,
        vec![
            "diff".into(),
            "HEAD".into(),
            "--no-color".into(),
            "--no-ext-diff".into(),
        ],
        30,
    )
    .await
    {
        Ok(patch) => patch,
        Err(_) => git(
            dir,
            vec!["diff".into(), "--no-color".into(), "--no-ext-diff".into()],
            30,
        )
        .await
        .map_err(ApiError::internal)?,
    };
    if snapshot.len() > MAX_DIFF_BYTES {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "Diff too large to discard from this view",
        ));
    }
    if format!("{:x}", Sha256::digest(snapshot.as_bytes())) != revision {
        return Err(ApiError::conflict(
            "Changes changed on disk. Refresh and review this block again.",
        ));
    }
    let files = parse_patch(&snapshot);
    let file = files
        .get(selection[0])
        .ok_or_else(|| ApiError::conflict("This change block no longer exists"))?;
    if file.binary {
        return Err(ApiError::conflict("This change block no longer exists"));
    }
    let hunk = file
        .hunks
        .get(selection[1])
        .ok_or_else(|| ApiError::conflict("This change block no longer exists"))?;
    let relative = patch_path(file);
    validate_discard_path(dir, relative)?;
    let patch = selected_patch(file, hunk, selection[2])?;
    if patch.len() > 1024 * 1024 {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "Change block too large to discard from this view",
        ));
    }
    if mode == "preview" {
        return Ok(Json(
            json!({"ok":true,"path":relative,"patch":patch,"revision":revision,"selection":selection}),
        ));
    }
    let result = cli::run_with_input(
        "git",
        ["-C", dir, "apply", "-R", "-"],
        patch.as_bytes(),
        Duration::from_secs(30),
        None,
    )
    .await;
    result.map_err(|e| unprocessable(e.to_string()))?;
    Ok(Json(json!({"ok":true})))
}
