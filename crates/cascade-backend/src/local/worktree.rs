//! Worktrees: listing, resolving, creating, forking, switching and removing them.

use super::*;

#[derive(Clone)]
pub(crate) struct Worktree {
    pub(crate) path: String,
    pub(crate) branch: String,
    pub(crate) main: bool,
}
pub(crate) async fn list_worktrees(dir: &str) -> Vec<Worktree> {
    let Ok(out) = git(
        dir,
        vec!["worktree".into(), "list".into(), "--porcelain".into()],
        20,
    )
    .await
    else {
        return vec![];
    };
    let mut result = Vec::new();
    for line in out.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            result.push(Worktree {
                path: path.trim().into(),
                branch: String::new(),
                main: result.is_empty(),
            });
        } else if let Some(branch) = line.strip_prefix("branch ") {
            if let Some(last) = result.last_mut() {
                last.branch = branch.trim().trim_start_matches("refs/heads/").into();
            }
        }
    }
    result
}

pub async fn list_worktrees_route(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(dir) = query.path else {
        return Ok(Json(json!([])));
    };
    Ok(Json(Value::Array(
        list_worktrees(&dir)
            .await
            .into_iter()
            .filter(|w| !w.main)
            .map(|w| json!({"path":w.path,"branch":w.branch}))
            .collect(),
    )))
}

pub async fn resolve_worktree(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(dir) = query.path else {
        return Ok(Json(
            json!({"path":"","matched":false,"isWorktree":false,"branch":""}),
        ));
    };
    let trees = list_worktrees(&dir).await;
    let strict = matches!(query.strict.as_deref(), Some("1" | "true"));
    let found = if let Some(branch) = query.branch {
        trees.iter().find(|w| w.branch == branch).or_else(|| {
            if strict {
                None
            } else {
                let folder = branch.rsplit('/').next().unwrap_or(&branch);
                trees.iter().find(|w| {
                    !w.main
                        && Path::new(&w.path).file_name().and_then(|v| v.to_str()) == Some(folder)
                })
            }
        })
    } else if let Some(key) = query.key {
        let needle = key.to_ascii_lowercase();
        let pattern = Regex::new(&format!(
            r"(?i)(^|[^a-z0-9]){}([^0-9]|$)",
            regex::escape(&needle)
        ))
        .ok();
        let hits: Vec<_> = trees
            .iter()
            .filter(|w| {
                if strict {
                    pattern.as_ref().is_some_and(|r| r.is_match(&w.branch))
                } else {
                    w.branch.to_ascii_lowercase().contains(&needle)
                }
            })
            .collect();
        if hits.len() == 1 {
            Some(hits[0])
        } else {
            None
        }
    } else {
        None
    };
    Ok(Json(
        found
            .map(|w| json!({"path":w.path,"matched":true,"isWorktree":!w.main,"branch":w.branch}))
            .unwrap_or_else(|| json!({"path":"","matched":false,"isWorktree":false,"branch":""})),
    ))
}

fn valid_branch(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && !value.ends_with('/')
        && !value.ends_with('.')
        && !value.ends_with(".lock")
        && !value
            .split('/')
            .any(|v| v.is_empty() || v == "." || v == ".." || v.starts_with('.'))
        && !value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "~^:?*[\\|".contains(c))
        && !value.contains("..")
        && !value.contains("@{")
}

pub async fn create_worktree(
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    create_worktree_value(&app, &body).await
}

/// `create_worktree`'s work, for the session flow to call without a request of its own.
pub(crate) async fn create_worktree_value(app: &AppState, body: &Value) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    let branch = body["branch"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    if !valid_branch(branch) {
        return Err(unprocessable(format!("\"{branch}\" is not a valid branch name")));
    }
    let folder = branch.rsplit('/').next().unwrap_or(branch);
    let location = worktrees::location(&app).await;
    let root = worktrees::root(dir, &location);
    let destination = root.join(folder);
    // The branch's own worktree is reused; another branch's worktree at the folder is a conflict.
    if list_worktrees(dir)
        .await
        .iter()
        .any(|w| Path::new(&w.path) == destination && w.branch == branch)
    {
        return Ok(Json(json!({"ok":true,"path":destination})));
    }
    if destination.exists() && !body["override"].as_bool().unwrap_or(false) {
        return Err(ApiError::conflict(format!(
            "A folder already exists at {}",
            destination.display()
        )));
    }
    if location == worktrees::Location::Inside {
        // A `.worktrees` the repo itself commits as a symlink would put the worktree wherever
        // the link points; that is the repo choosing the location, not Settings.
        if root
            .symlink_metadata()
            .is_ok_and(|meta| meta.file_type().is_symlink())
        {
            return Err(ApiError::conflict(format!(
                "{} is a symlink; choose another worktree location in Settings",
                root.display()
            )));
        }
        // Before the folder exists, so `git status` in the checkout never lists it.
        worktrees::exclude_inside_root(dir)
            .await
            .map_err(ApiError::internal)?;
    }
    fs::create_dir_all(&root).map_err(ApiError::internal)?;
    // Clear stale admin entries, then add. Adding an EXISTING branch is the first move and
    // `-b` the fallback, so a `create` request whose branch is already present adopts it
    // instead of failing. This shape came from the node backend this crate replaced.
    let _ = git(dir, vec!["worktree".into(), "prune".into()], 20).await;
    let target = destination.to_string_lossy().into_owned();
    let create = body["create"].as_bool().unwrap_or(false);
    let add = vec![
        "worktree".into(),
        "add".into(),
        target.clone(),
        branch.into(),
    ];
    let mut failure = match git(dir, add.clone(), 90).await {
        Ok(_) => return Ok(Json(prepared(&app, dir, &destination, branch).await)),
        Err(error) => error.to_string(),
    };
    // The one place a fetch earns its cost: adopting a branch that exists only on origin, which
    // `worktree add` cannot resolve without refs/remotes/origin/<branch>. The JS backend fetched
    // up front on every path instead; that is what froze New Session for a minute, since a fetch
    // from the app (Xcode's git, a GUI process resolving credentials) is far slower than from a
    // shell, and on the create path the ref being fetched provably does not exist yet.
    if missing_ref(&failure) && !create {
        let _ = git(
            dir,
            vec!["fetch".into(), "origin".into(), branch.into()],
            10,
        )
        .await;
        match git(dir, add, 90).await {
            Ok(_) => return Ok(Json(prepared(&app, dir, &destination, branch).await)),
            Err(error) => failure = error.to_string(),
        }
    }
    // Only a missing ref means "this branch does not exist yet, make it". Anything else (a bad
    // path, a flag error) must surface as itself rather than silently creating a branch.
    if !create || !missing_ref(&failure) {
        return Err(unprocessable(worktree_failure(branch, failure)));
    }
    let explicit = body["base"].as_str().filter(|v| !v.is_empty());
    let base = match explicit {
        Some(base) => base.to_string(),
        None => default_branch(dir).await,
    };
    if explicit.is_some() && !valid_branch(&base) {
        return Err(unprocessable(format!("\"{base}\" is not a valid base branch name")));
    }
    // No fetch for the base either, unless Settings opted in: a new branch is cut from what this
    // checkout already has, so creating one never waits on the network. `origin/<base>` is still
    // preferred when it is present locally, so the start point is the newest tip the checkout knows about.
    worktrees::fetch_base(&app, dir, &base).await;
    // origin/<base> when it resolves — the freshest tip this checkout has — else the local branch
    // (a base that was never pushed). An EXPLICIT base resolving nowhere is an error: never
    // fork off whatever HEAD the main checkout happens to be on.
    let start = if ref_exists(dir, &format!("origin/{base}")).await {
        format!("origin/{base}")
    } else if ref_exists(dir, &base).await {
        base.clone()
    } else {
        String::new()
    };
    if start.is_empty() && explicit.is_some() {
        return Err(unprocessable(format!(
            "Base branch \"{base}\" was not found locally or on origin"
        )));
    }
    let mut args = vec![
        "worktree".into(),
        "add".into(),
        "-b".into(),
        branch.into(),
        target,
    ];
    if !start.is_empty() {
        args.push(start);
    }
    match git(dir, args, 90).await {
        Ok(_) => Ok(Json(prepared(&app, dir, &destination, branch).await)),
        Err(e) => Err(unprocessable(worktree_failure(branch, e.to_string()))),
    }
}

/// What a worktree `git worktree add` just made gets before the session opens it: the ignored
/// files it needs copied in, then the setup command started. Neither fails the create; a
/// worktree that already existed gets neither, since it was prepared when it was made.
async fn prepared(app: &AppState, dir: &str, destination: &Path, branch: &str) -> Value {
    let copied = worktrees::copy_included(app, Path::new(dir), destination).await;
    if !copied.failed.is_empty() {
        let _ = app.db.add_log(
            "worktree",
            "error",
            "worktree_copy_failed",
            &json!({"worktree":destination,"failed":copied.failed}),
        ).await;
    }
    worktrees::spawn_setup(app, dir, destination, branch).await;
    json!({"ok":true,"path":destination,"copied":copied.copied})
}

/// A forked session's worktree, as `fork_worktree` made it.
pub(crate) struct Forked {
    pub number: u32,
    pub branch: String,
    pub path: PathBuf,
    /// What of the source's uncommitted work could not be carried across; the fork stands anyway.
    pub warning: Option<String>,
}

/// A worktree for a fork of the session in `source`: a new branch cut at the source's HEAD, with
/// the source's uncommitted work carried across, so the code is what the forked conversation
/// remembers doing. `branch_for` names the branch for each number from `first`; the first whose
/// branch and folder are both free is taken, so the number the caller shows is one git has too.
/// The fork never touches the network, and never changes the source.
pub(crate) async fn fork_worktree(
    app: &AppState,
    dir: &str,
    source: &str,
    first: u32,
    branch_for: impl Fn(u32) -> String,
) -> Result<Forked, String> {
    // The uncommitted work is recorded first and the branch cut at the commit it was recorded on,
    // so a commit the source's agent makes meanwhile can't leave the two out of step. The new files
    // are listed before that: one committed after the listing is still copied, as the file it was.
    let mut warnings = Vec::new();
    let untracked = list_untracked(source).await;
    let stash = match git(source, vec!["stash".into(), "create".into()], 30).await {
        Ok(stash) => Some(stash).filter(|stash| !stash.is_empty()),
        Err(error) => {
            warnings.push(format!("its uncommitted changes could not be read: {}", error_line(&error.to_string())));
            None
        }
    };
    let start = stash.as_ref().map_or_else(|| "HEAD".to_owned(), |stash| format!("{stash}^1"));
    let head = git(source, vec!["rev-parse".into(), start], 15)
        .await
        .map_err(|error| error_line(&error.to_string()))?;
    let location = worktrees::location(app).await;
    let root = worktrees::root(dir, &location);
    let mut chosen = None;
    for number in first..first.saturating_add(100) {
        let branch = branch_for(number);
        if !valid_branch(&branch) {
            return Err(format!("\"{branch}\" is not a valid branch name"));
        }
        let folder = branch.rsplit('/').next().unwrap_or(&branch);
        let destination = root.join(folder);
        if destination.symlink_metadata().is_err() && !ref_exists(dir, &format!("refs/heads/{branch}")).await {
            chosen = Some((number, branch, destination));
            break;
        }
    }
    let (number, branch, destination) = chosen.ok_or("No free branch name was left for the fork")?;
    if location == worktrees::Location::Inside {
        if root
            .symlink_metadata()
            .is_ok_and(|meta| meta.file_type().is_symlink())
        {
            return Err(format!("{} is a symlink; choose another worktree location in Settings", root.display()));
        }
        worktrees::exclude_inside_root(dir)
            .await
            .map_err(|error| error.to_string())?;
    }
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    let _ = git(dir, vec!["worktree".into(), "prune".into()], 20).await;
    let target = destination.to_string_lossy().into_owned();
    git(
        dir,
        vec!["worktree".into(), "add".into(), "-b".into(), branch.clone(), target, head],
        90,
    )
    .await
    .map_err(|error| worktree_failure(&branch, error.to_string()))?;
    warnings.extend(carry_changes(source, &destination, stash, untracked).await);
    prepared(app, dir, &destination, &branch).await;
    let warning = (!warnings.is_empty()).then(|| warnings.join("; "));
    Ok(Forked { number, branch, path: destination, warning })
}

/// Takes back a fork whose session could not be saved, so no worktree or branch is left that no
/// session shows. The folder is the fork's own, made moments ago, so one git will not remove is
/// deleted outright and its entry pruned, which frees the branch to go too.
pub(crate) async fn discard_fork(dir: &str, forked: &Forked) {
    let path = forked.path.to_string_lossy().into_owned();
    if git(dir, vec!["worktree".into(), "remove".into(), "--force".into(), path], 60).await.is_err() {
        let _ = fs::remove_dir_all(&forked.path);
        let _ = git(dir, vec!["worktree".into(), "prune".into()], 20).await;
    }
    let _ = git(dir, vec!["branch".into(), "-D".into(), forked.branch.clone()], 15).await;
}

/// Copies `source`'s uncommitted work into `destination`, a checkout of the commit `stash` was
/// recorded on: staged changes staged, unstaged ones not, and untracked files as files. `stash
/// create` records the index and working tree as a commit without touching either, and a
/// worktree shares its repository's objects, so the fork applies it by id. Each part is tried
/// whatever became of the other; what failed is returned.
async fn carry_changes(
    source: &str,
    destination: &Path,
    stash: Option<String>,
    untracked: Result<Vec<PathBuf>, String>,
) -> Vec<String> {
    let mut failed = Vec::new();
    if let Some(stash) = stash {
        let target = destination.to_string_lossy().into_owned();
        if let Err(error) = git(&target, vec!["stash".into(), "apply".into(), "--index".into(), stash], 60).await {
            failed.push(format!("its uncommitted changes could not be copied: {}", error_line(&error.to_string())));
        }
    }
    if let Err(error) = copy_untracked(source, destination, untracked).await {
        failed.push(error);
    }
    failed
}

/// The files in `source` git does not track and does not ignore.
async fn list_untracked(source: &str) -> Result<Vec<PathBuf>, String> {
    let untracked = cli::run_nul(
        "git",
        ["-C", source, "ls-files", "--others", "--exclude-standard", "-z"],
        None,
        Duration::from_secs(30),
        None,
        &[],
    )
    .await
    .map_err(|error| format!("its new files could not be listed: {}", error_line(&error.to_string())))?;
    // A nested repository is listed as its folder, which git itself leaves alone.
    Ok(untracked
        .into_iter()
        .filter(|record| !record.ends_with(b"/"))
        .map(|record| PathBuf::from(std::ffi::OsString::from_vec(record)))
        .collect())
}

async fn copy_untracked(source: &str, destination: &Path, files: Result<Vec<PathBuf>, String>) -> Result<(), String> {
    let files = files?;
    if files.is_empty() {
        return Ok(());
    }
    let (from, to) = (PathBuf::from(source), destination.to_owned());
    let copied = tokio::task::spawn_blocking(move || worktrees::copy_files(&from, &to, &files))
        .await
        .map_err(|error| error.to_string())?;
    if copied.failed.is_empty() {
        return Ok(());
    }
    Err(format!("{} new file(s) could not be copied: {}", copied.failed.len(), copied.failed.join(", ")))
}

/// Moves a checkout to another branch. A branch can only be checked out once, so the main repo
/// sitting on a branch is what stops a session for it from getting a worktree; the app asks here
/// to free it. Uncommitted tracked work is never carried across silently — that case reports and
/// leaves the checkout alone. Untracked files follow a switch harmlessly and do not block it.
pub async fn git_switch(Json(body): Json<Value>) -> ApiResult<Value> {
    git_switch_value(&body).await
}

/// `git_switch`'s work, for the session flow: parking the main checkout frees a branch it holds.
pub(crate) async fn git_switch_value(body: &Value) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    let branch = body["branch"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    if !valid_branch(branch) {
        return Err(unprocessable(format!("\"{branch}\" is not a valid branch name")));
    }
    // The branch is held by the MAIN worktree, which is not always the folder the app calls its
    // workspace — a project can be configured on a linked worktree. Switching the wrong one leaves
    // the branch just as held.
    let trees = list_worktrees(dir).await;
    let Some(main) = trees.iter().find(|w| w.main).map(|w| w.path.clone()) else {
        return Err(unprocessable(format!("{dir} is not a git checkout")));
    };
    // A status that could not be read is treated as dirty: `switch` carries uncommitted work onto
    // the new branch whenever git sees no conflict, and that is not something to do on a guess.
    let dirty = match git(
        &main,
        vec![
            "status".into(),
            "--porcelain".into(),
            "--untracked-files=no".into(),
        ],
        30,
    )
    .await
    {
        Ok(out) => !out.trim().is_empty(),
        Err(e) => {
            return Err(ApiError::conflict(format!(
                "Could not read the state of {main}: {}",
                error_line(&e.to_string())
            )))
        }
    };
    if dirty {
        return Err(ApiError::conflict(format!(
            "{main} has uncommitted changes. Commit or stash them before moving it to \"{branch}\"."
        )));
    }
    // A local branch only: `switch` would otherwise create a tracking branch from origin, which
    // is a different act than the one the app asked for.
    if !ref_exists(&main, &format!("refs/heads/{branch}")).await {
        return Err(unprocessable(format!("Branch \"{branch}\" was not found in {main}")));
    }
    match git(&main, vec!["switch".into(), branch.into()], 60).await {
        Ok(_) => Ok(Json(json!({"ok":true}))),
        Err(e) => Err(unprocessable(error_line(&e.to_string()))),
    }
}

/// The narrow set of phrases `worktree add` emits for a ref it cannot resolve — matched, as in
/// the JS backend, so an unrelated failure is never read as "the branch does not exist yet".
fn missing_ref(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("invalid reference") || message.contains("unknown revision")
}

/// Git's "invalid reference" says nothing about what to do; a fork's PR branch is the usual way
/// to reach it, since that branch is on the fork's remote and never on origin.
fn worktree_failure(branch: &str, message: String) -> String {
    if missing_ref(&message) {
        return format!(
            "Branch \"{branch}\" isn't available locally or on origin (a PR from a fork needs its branch fetched first)"
        );
    }
    error_line(&message)
}

/// The line that says what went wrong, as the JS backend's `gitErrLine` picks it: git narrates
/// before it fails ("Preparing worktree (checking out 'x')\nfatal: …"), and a toast showing the
/// narration first reads as though nothing is wrong.
pub(crate) fn error_line(message: &str) -> String {
    message
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .find(|line| {
            let line = line.to_ascii_lowercase();
            line.contains("error") || line.contains("rejected") || line.contains("fatal")
        })
        .map(str::to_owned)
        .unwrap_or_else(|| message.trim().to_owned())
}

/// The most recently committed local branch that is not in `exclude`, if any.
pub(crate) async fn most_recent_branch(dir: &str, exclude: &[String]) -> Option<String> {
    let listed = git(
        dir,
        vec![
            "for-each-ref".into(),
            "--sort=-committerdate".into(),
            "--format=%(refname:short)".into(),
            "refs/heads".into(),
        ],
        15,
    )
    .await
    .ok()?;
    listed
        .lines()
        .map(str::trim)
        .find(|name| !name.is_empty() && !exclude.iter().any(|taken| taken == name))
        .map(str::to_owned)
}

/// Whether `reference` (a full ref name) points at a commit here.
pub(crate) async fn ref_exists(dir: &str, reference: &str) -> bool {
    git(
        dir,
        vec![
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            format!("{reference}^{{commit}}"),
        ],
        15,
    )
    .await
    .is_ok()
}

/// origin/HEAD when the remote publishes one, else the first conventional branch that exists.
/// The repository's default branch: what `origin/HEAD` names, else the first of `main`, `master`
/// and `develop` that exists, else `main`.
pub(crate) async fn default_branch(dir: &str) -> String {
    if let Ok(head) = git(
        dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    {
        let name = head.trim().trim_start_matches("origin/");
        if !name.is_empty() {
            return name.to_owned();
        }
    }
    for candidate in ["main", "master", "develop"] {
        if ref_exists(dir, &format!("refs/heads/{candidate}")).await {
            return candidate.to_owned();
        }
    }
    "main".to_owned()
}

pub async fn remove_worktree(
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and worktree required"))?;
    let target = body["worktree"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and worktree required"))?;
    let trees = list_worktrees(dir).await;
    let Some(tree) = trees
        .iter()
        .find(|w| Path::new(&w.path) == Path::new(target))
    else {
        return Err(unprocessable(format!("{target} is not a worktree of this project")));
    };
    if tree.main {
        return Err(ApiError::conflict("refusing to remove the main checkout"));
    }
    // Collected before the removal: the folders are named after the worktree's projects.
    let derived = crate::xcode::derived_data_of(&resolve_path(target)).await;
    let mut args = vec!["worktree".into(), "remove".into()];
    if body["force"].as_bool().unwrap_or(false) {
        args.push("--force".into())
    }
    args.push(target.into());
    match git(dir, args, 60).await {
        Ok(_) => {
            // What xcodebuild said about the worktree is kept by its path; nothing asks again.
            crate::xcode::forget_answers(&app, &resolve_path(target)).await;
            worktrees::spawn_derived_data_removal(&app, target, derived);
            // A detached worktree has no branch to delete.
            let deleted = !tree.branch.is_empty()
                && worktrees::delete_branch(&app).await
                && worktrees::remove_branch(&app, dir, &tree.branch).await;
            Ok(Json(json!({"ok":true,"branchDeleted":deleted})))
        }
        Err(e) => Err(unprocessable(e.to_string())),
    }
}

pub async fn worktree_holders(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(path) = query.path else {
        return Ok(Json(json!({"holders":[]})));
    };
    let output = cli::run("lsof", ["-F", "pcft", "+D", &path], Duration::from_secs(8))
        .await
        .unwrap_or_default();
    let mut holders = BTreeMap::new();
    let (mut pid, mut command, mut fd) = (String::new(), String::new(), String::new());
    for line in output.lines() {
        let (tag, value) = line.split_at(1);
        match tag {
            "p" => {
                pid = value.into();
                command.clear();
                fd.clear()
            }
            "c" => command = value.into(),
            "f" => fd = value.into(),
            "t" if value == "REG" && fd.chars().next().is_some_and(|c| c.is_ascii_digit()) => {
                holders.insert(pid.clone(), command.clone());
            }
            _ => {}
        }
    }
    Ok(Json(
        json!({"holders":holders.into_iter().map(|(pid,command)|json!({"pid":pid.parse::<i64>().unwrap_or(0),"command":command})).collect::<Vec<_>>()}),
    ))
}
