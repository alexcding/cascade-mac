//! Git state and history: the diff, commits, pushes, refs, log and show.

use std::collections::HashSet;

use super::*;

async fn git_meta(dir: &str) -> (String, Option<i64>, Option<i64>) {
    // Both read-only, so both at once.
    let (branch, divergence) = tokio::join!(
        git(
            dir,
            vec!["rev-parse".into(), "--abbrev-ref".into(), "HEAD".into()],
            15,
        ),
        git(
            dir,
            vec![
                "rev-list".into(),
                "--left-right".into(),
                "--count".into(),
                "@{upstream}...HEAD".into(),
            ],
            15,
        )
    );
    let branch = branch.unwrap_or_default();
    let counts = divergence
        .ok()
        .as_deref()
        .map(|v| {
            v.split_whitespace()
                .filter_map(|x| x.parse().ok())
                .collect::<Vec<i64>>()
        })
        .unwrap_or_default();
    (branch, counts.get(1).copied(), counts.first().copied())
}

pub async fn diff(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    // The patch, the untracked names and the branch state are all read-only questions, so they
    // are asked at once rather than one after another: the panel asks on every refresh.
    let patch = async {
        match git(
            &dir,
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
            Ok(v) => Ok(v),
            Err(_) => {
                git(
                    &dir,
                    vec!["diff".into(), "--no-color".into(), "--no-ext-diff".into()],
                    30,
                )
                .await
            }
        }
    };
    let untracked = git(
        &dir,
        vec![
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
        ],
        15,
    );
    let (patch, untracked, (branch, ahead, behind)) =
        tokio::join!(patch, untracked, git_meta(&dir));
    let patch = patch.map_err(ApiError::internal)?;
    if patch.len() > MAX_DIFF_BYTES {
        return Err(ApiError::status(
            StatusCode::PAYLOAD_TOO_LARGE,
            "Diff too large to display",
        ));
    }
    let untracked = untracked
        .unwrap_or_default()
        .lines()
        .map(String::from)
        .collect::<Vec<_>>();
    let revision = format!("{:x}", Sha256::digest(patch.as_bytes()));
    Ok(Json(
        json!({"diff":patch,"untracked":untracked,"branch":branch,"ahead":ahead,"behind":behind,"revision":revision}),
    ))
}

pub async fn git_commit(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let message = body["message"]
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("message required"))?;
    let flag = if body["includeUntracked"].as_bool().unwrap_or(true) {
        "-A"
    } else {
        "-u"
    };
    git(dir, vec!["add".into(), flag.into()], 30)
        .await
        .map_err(|e| unprocessable(e.to_string()))?;
    git(dir, vec!["commit".into(), "-m".into(), message.into()], 120)
        .await
        .map_err(|e| unprocessable(e.to_string()))?;
    let hash = git(
        dir,
        vec!["rev-parse".into(), "--short".into(), "HEAD".into()],
        15,
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(json!({"ok":true,"hash":hash})))
}

pub async fn git_push(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let result = match git(dir, vec!["push".into()], 60).await {
        Err(error)
            if error
                .to_string()
                .to_ascii_lowercase()
                .contains("no upstream") =>
        {
            git(
                dir,
                vec!["push".into(), "-u".into(), "origin".into(), "HEAD".into()],
                60,
            )
            .await
        }
        other => other,
    };
    result.map_err(|e| unprocessable(e.to_string()))?;
    Ok(Json(json!({"ok":true})))
}

fn default_branch_from_refs(branches: &[Value]) -> String {
    for name in ["main", "master", "develop"] {
        if branches.iter().any(|b| b["name"] == name) {
            return name.into();
        }
    }
    String::new()
}

/// `for-each-ref` lines over `refs/heads` and `refs/remotes/origin`, folded into one list of
/// branches in the order git gave them: a local branch as itself, and an origin branch with no
/// local one under its name, `remote`. The rows carry full ref names: `%(refname:short)` would
/// print `origin/HEAD`, origin's pointer and not a branch, as a local branch called `origin`.
fn fold_refs(raw: &str) -> Vec<Value> {
    let rows = raw
        .lines()
        .map(|line| line.split('\x1f').collect::<Vec<_>>())
        .collect::<Vec<_>>();
    let local = rows
        .iter()
        .filter_map(|p| p.get(1).copied())
        .filter_map(|name| name.strip_prefix("refs/heads/"))
        .collect::<HashSet<_>>();
    rows.iter()
        .filter_map(|p| {
            let name = p.get(1).copied().unwrap_or("");
            let short = p.get(3).copied().unwrap_or("");
            if let Some(local) = name.strip_prefix("refs/heads/") {
                return Some(json!({
                    "name":local,
                    "current":p.first().copied()==Some("*"),
                    "upstream":p.get(2).copied().filter(|v|!v.is_empty()),
                    "short":short,
                }));
            }
            match name.strip_prefix("refs/remotes/origin/") {
                Some("HEAD") | None => None,
                Some(remote) if local.contains(remote) => None,
                Some(remote) => Some(json!({"name":remote,"current":false,"upstream":null,"short":short,"remote":true})),
            }
        })
        .collect()
}

/// What git records for one file: whether it is tracked, and whether its recorded mode is
/// executable. A new worktree is checked out from exactly this, so it, not the file's state in
/// the project folder, says whether the file will be there and whether `./file` can run.
pub async fn git_tracked(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let (Some(dir), Some(rel)) = (query.path, query.rel.filter(|v| !v.is_empty())) else {
        return Err(ApiError::bad_request("path and rel required"));
    };
    let out = git(&dir, vec!["ls-files".into(), "-s".into(), "--".into(), rel], 15)
        .await
        .map_err(|e| ApiError::bad_request(error_line(&e.to_string())))?;
    // `<mode> <object> <stage>\t<path>`, or nothing for a file git does not track.
    let mode = out.split_whitespace().next().unwrap_or("");
    Ok(Json(json!({"tracked": !mode.is_empty(), "executable": mode == "100755"})))
}

pub async fn git_refs(
    State(app): State<AppState>,
    Query(query): Query<LocalQuery>,
) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    // The one read that fetches: a person opened the branch picker, and a branch pushed from
    // elsewhere is otherwise unseen until a fetch in a shell. The fetch is paced and run one at
    // a time per checkout by `Fetches`. The answer is then whether origin was fetched and, only
    // when it was, the references: a picker that opened again within the interval, or whose
    // fetch failed (logged, once per interval), has nothing new to show and reads nothing.
    if matches!(query.fetch.as_deref(), Some("1" | "true")) {
        return match app.fetches.origin(&dir).await {
            worktrees::Fetched::Fresh => {
                let Json(references) = git_refs_value(&dir).await?;
                Ok(Json(json!({"fetched":true,"references":references})))
            }
            worktrees::Fetched::Recent => Ok(Json(json!({"fetched":false}))),
            worktrees::Fetched::Failed(reason) => {
                let _ = app
                    .db
                    .add_log("worktree", "info", "branches_fetch_failed", &json!({"path":dir,"reason":reason}))
                    .await;
                Ok(Json(json!({"fetched":false})))
            }
        };
    }
    git_refs_value(&dir).await
}

/// `git_refs`'s work: every branch the checkout knows, the worktrees and the default branch, for
/// the app's branch pickers. A branch fetched from origin and never checked out is listed too,
/// marked `remote`: a session adopts it the same way (`create_worktree_value` lets `worktree add`
/// make the local branch from `origin/<name>`), so the picker must offer it. A new session's base
/// is not read from here; `sessions` asks git directly.
async fn git_refs_value(dir: &str) -> ApiResult<Value> {
    let format = format!(
        "%(HEAD){}%(refname){}%(upstream:short){}%(objectname:short)",
        '\x1f', '\x1f', '\x1f'
    );
    let raw = git(
        &dir,
        vec![
            "for-each-ref".into(),
            "--sort=-committerdate".into(),
            format!("--format={format}"),
            "refs/heads".into(),
            "refs/remotes/origin".into(),
        ],
        20,
    )
    .await
    .unwrap_or_default();
    let branches = fold_refs(&raw);
    let worktrees = list_worktrees(&dir)
        .await
        .into_iter()
        .map(|w| json!({"path":w.path,"branch":w.branch,"isMain":w.main}))
        .collect::<Vec<_>>();
    let default = git(
        &dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    .ok()
    .map(|v| v.trim_start_matches("origin/").into())
    .unwrap_or_else(|| default_branch_from_refs(&branches));
    Ok(Json(
        json!({"branches":branches,"worktrees":worktrees,"defaultBranch":default}),
    ))
}

pub async fn git_log(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let (branch, ahead, behind) = git_meta(&dir).await;
    let default = git(
        &dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    .ok()
    .map(|v| v.trim_start_matches("origin/").to_owned())
    .unwrap_or_default();
    let ahead_only = query.ahead_only.as_deref() == Some("1");
    // Ahead-only lists the worktree's own commits, so it always views HEAD.
    let viewing = if ahead_only {
        "HEAD".into()
    } else {
        query
            .reference
            .filter(|v| !v.is_empty() && !v.starts_with('-'))
            .unwrap_or_else(|| {
                if default.is_empty() {
                    "HEAD".into()
                } else {
                    default.clone()
                }
            })
    };
    // What the branch added on its base, even when that is nothing yet. A branch with no base to
    // measure against — detached, or the base itself — lists its whole history, with no base
    // reported.
    let base = query
        .base
        .clone()
        .filter(|v| !v.is_empty() && !v.starts_with('-'))
        .unwrap_or(default.clone());
    let detached = matches!(branch.as_str(), "" | "HEAD");
    let ahead_of = (ahead_only && !base.is_empty() && base != branch && !detached).then_some(base);
    // Resolved to commits once, before the log: the log runs on exactly these, and the list's
    // revision names them, so a page always belongs to the list it says, whatever lands meanwhile.
    // A commit on the branch, or its base moving, makes another list, which paging must not mix
    // into. The trailing `--` reads every name as a revision, even one that is also a folder.
    let names = match &ahead_of {
        Some(base) => vec![base.clone(), "HEAD".into()],
        None => vec![viewing.clone()],
    };
    let mut resolve = vec!["rev-parse".to_owned()];
    resolve.extend(names.iter().cloned());
    resolve.push("--".into());
    let tips = git(&dir, resolve, 15)
        .await
        .ok()
        // rev-parse echoes the `--` back after the commits.
        .map(|v| v.lines().filter(|l| *l != "--").map(str::to_owned).collect::<Vec<_>>())
        .filter(|v| v.len() == names.len())
        .unwrap_or(names);
    let revision = match &ahead_of {
        Some(_) => format!("{}..{}", tips[0], tips[1]),
        None => tips[0].clone(),
    };
    let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1e";
    let raw = git(
        &dir,
        vec![
            "log".into(),
            "--no-color".into(),
            format!("--max-count={}", query.limit.unwrap_or(100).clamp(1, 1000)),
            format!("--skip={}", query.skip.unwrap_or(0)),
            format!("--pretty=format:{format}"),
            revision.clone(),
            "--".into(),
        ],
        30,
    )
    .await
    .unwrap_or_default();
    let commits=raw.split('\x1e').filter(|v|!v.trim().is_empty()).map(|record|{let p=record.trim_start_matches('\n').split('\x1f').collect::<Vec<_>>();json!({"sha":p.first().copied().unwrap_or(""),"short":p.get(1).copied().unwrap_or(""),"parents":p.get(2).copied().unwrap_or("").split_whitespace().collect::<Vec<_>>(),"author":p.get(3).copied().unwrap_or(""),"email":p.get(4).copied().unwrap_or(""),"date":p.get(5).copied().unwrap_or(""),"refs":[],"subject":p.get(7).copied().unwrap_or("")})}).collect::<Vec<_>>();
    let history_revision = format!("{:x}", Sha256::digest(revision.as_bytes()));
    // Whether anything lies past the branch's own commits: the history it grew from is what it
    // shares with its base, which a branch with no common commit does not have.
    let older = match &ahead_of {
        Some(_) => Some(
            git(&dir, vec!["merge-base".into(), tips[0].clone(), tips[1].clone()], 15)
                .await
                .is_ok_and(|v| !v.is_empty()),
        ),
        None => None,
    };
    Ok(Json(
        json!({"commits":commits,"branch":branch,"ahead":ahead,"behind":behind,"viewing":viewing,"defaultBranch":default,"base":ahead_of,"older":older,"historyRevision":history_revision}),
    ))
}

pub async fn git_show(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path and sha required"))?;
    let sha = query
        .sha
        .filter(|v| Regex::new(r"^[0-9a-fA-F]{4,64}$").unwrap().is_match(v))
        .ok_or_else(|| ApiError::bad_request("path and sha required"))?;
    let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%B";
    let info = git(
        &dir,
        vec![
            "show".into(),
            "-s".into(),
            format!("--pretty=format:{format}"),
            sha.clone(),
        ],
        30,
    )
    .await
    .map_err(ApiError::internal)?;
    let patch = git(
        &dir,
        vec![
            "show".into(),
            sha,
            "-m".into(),
            "--first-parent".into(),
            "--no-color".into(),
            "--no-ext-diff".into(),
            "--format=".into(),
        ],
        30,
    )
    .await
    .map_err(ApiError::internal)?;
    let p = info.split('\x1f').collect::<Vec<_>>();
    Ok(Json(
        json!({"meta":{"sha":p.first().copied().unwrap_or(""),"short":p.get(1).copied().unwrap_or(""),"parents":p.get(2).copied().unwrap_or("").split_whitespace().collect::<Vec<_>>(),"author":p.get(3).copied().unwrap_or(""),"authorEmail":p.get(4).copied().unwrap_or(""),"authorDate":p.get(5).copied().unwrap_or(""),"committer":p.get(6).copied().unwrap_or(""),"committerEmail":p.get(7).copied().unwrap_or(""),"commitDate":p.get(8).copied().unwrap_or(""),"message":p.get(9..).unwrap_or(&[]).join("\u{1f}")},"diff":patch.trim_start_matches('\n')}),
    ))
}

pub async fn commit_avatars(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(repo) = query
        .repo
        .filter(|v| Regex::new(r"^[\w.-]+/[\w.-]+$").unwrap().is_match(v))
    else {
        return Ok(Json(json!({})));
    };
    let mut endpoint = format!(
        "/repos/{repo}/commits?per_page={}",
        query.limit.unwrap_or(100).clamp(1, 100)
    );
    if let Some(reference) = query.reference {
        endpoint.push_str("&sha=");
        endpoint.push_str(&reference)
    }
    let raw = cli::run(
        "gh",
        [
            "api",
            &endpoint,
            "--jq",
            ".[] | [.sha, (.author.avatar_url // \"\")] | @tsv",
        ],
        Duration::from_secs(30),
    )
    .await
    .unwrap_or_default();
    let mut map = Map::new();
    for line in raw.lines() {
        if let Some((sha, url)) = line.split_once('\t') {
            if !url.is_empty() {
                map.insert(sha.into(), Value::String(url.into()));
            }
        }
    }
    Ok(Json(Value::Object(map)))
}

#[cfg(test)]
mod tests {
    use super::fold_refs;

    #[test]
    fn origin_branches_are_listed_once_and_marked() {
        let raw = [
            "*\x1frefs/heads/main\x1forigin/main\x1faaa1",
            " \x1frefs/remotes/origin/HEAD\x1f\x1faaa1",
            " \x1frefs/remotes/origin/feature\x1f\x1fbbb2",
            " \x1frefs/remotes/origin/main\x1f\x1faaa1",
            " \x1frefs/heads/old\x1f\x1fccc3",
        ]
        .join("\n");
        let branches = fold_refs(&raw);
        let names = branches.iter().map(|b| b["name"].as_str().unwrap()).collect::<Vec<_>>();
        assert_eq!(names, ["main", "feature", "old"]);
        assert_eq!(branches[0]["current"], true);
        assert_eq!(branches[0]["upstream"], "origin/main");
        assert!(branches[0].get("remote").is_none());
        assert_eq!(branches[1]["remote"], true);
        assert!(branches[1]["upstream"].is_null(), "No local branch, so nothing tracks origin's");
        assert_eq!(branches[1]["short"], "bbb2");
        assert!(branches[2].get("remote").is_none());
    }
}
