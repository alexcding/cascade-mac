//! Worktrees: listing, resolving, creating, forking, switching and removing them.

use super::*;

#[derive(Clone)]
pub(crate) struct Worktree {
    pub(crate) path: String,
    pub(crate) branch: String,
    pub(crate) main: bool,
}
pub(crate) async fn list_worktrees(dir: &str) -> Vec<Worktree> {
    try_list_worktrees(dir).await.unwrap_or_default()
}

/// `list_worktrees`, telling a checkout git could not read from one with no worktrees.
async fn try_list_worktrees(dir: &str) -> anyhow::Result<Vec<Worktree>> {
    let out = git(
        dir,
        vec!["worktree".into(), "list".into(), "--porcelain".into()],
        20,
    )
    .await?;
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
    Ok(result)
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
        let _ = worktrees::fetch(dir, Some(branch), false, Duration::from_secs(10)).await;
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
        Ok(_) => {
            worktrees::mark_created(dir, branch).await;
            Ok(Json(prepared(&app, dir, &destination, branch).await))
        }
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
    worktrees::mark_created(dir, &branch).await;
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
    // A branch the checkout has: local, or origin's, which the picker offers too and which
    // `switch --track` makes local on the way. Anything else is refused rather than guessed at.
    let local = ref_exists(&main, &format!("refs/heads/{branch}")).await;
    if !local && !ref_exists(&main, &format!("refs/remotes/origin/{branch}")).await {
        return Err(unprocessable(format!("Branch \"{branch}\" was not found in {main}")));
    }
    let args = if local {
        vec!["switch".into(), branch.into()]
    } else {
        vec!["switch".into(), "--track".into(), format!("origin/{branch}")]
    };
    match git(&main, args, 60).await {
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
            let deleted = !tree.branch.is_empty() && worktrees::remove_branch(&app, dir, &tree.branch).await;
            Ok(Json(json!({"ok":true,"branchDeleted":deleted})))
        }
        Err(e) => Err(unprocessable(e.to_string())),
    }
}

/// A worktree folder in a shared root (`worktrees::shared_roots`), Settings → Worktrees' list.
struct Shared {
    path: PathBuf,
    /// The project that claims it. None: a leftover, its project removed from Cascade or its
    /// checkout deleted from under it.
    project: Option<Claim>,
    /// The checkout it was made from, when that is still there.
    repo: Option<String>,
    branch: String,
}

#[derive(Clone)]
struct Claim {
    id: String,
    name: String,
    workspace: String,
}

/// Every worktree at `<root>/<project folder>/<worktree>`, with the project that claims it. Only
/// what Cascade made counts: a project folder it named (`worktrees::is_project_folder`), holding a
/// folder whose `.git` says it is a linked worktree. A shared root may be a custom folder that holds
/// anything else, other tools' worktrees included, and none of that is ever listed or deleted. Paths are compared
/// resolved, as git records them. A project claims a worktree its checkout lists, or one made from
/// its checkout; one whose checkout git could not read just now claims its whole folder in each
/// root, so a slow or unmounted checkout never turns its worktrees into leftovers anyone may
/// delete, and so does one out of reach with the folder it sits in (a drive not mounted); one
/// whose checkout was deleted from a folder still there claims nothing.
async fn shared_worktrees(app: &AppState) -> anyhow::Result<Vec<Shared>> {
    let roots = worktrees::shared_roots(app).await;
    let projects: Vec<_> = app.db.projects().await?.into_iter().filter(|p| !p.workspace.is_empty()).collect();
    let listings = futures_util::future::join_all(projects.iter().map(|p| try_list_worktrees(&p.workspace))).await;
    let (mut claimed, mut folders, mut checkouts) = (HashMap::new(), HashMap::new(), HashMap::new());
    for (project, listing) in projects.iter().zip(listings) {
        let claim = Claim { id: project.id.clone(), name: project.name.clone(), workspace: project.workspace.clone() };
        checkouts.insert(resolved(Path::new(&project.workspace)), claim.clone());
        match listing {
            Ok(trees) => {
                for tree in trees {
                    claimed.insert(resolved(Path::new(&tree.path)), claim.clone());
                }
            }
            // Unreadable, or out of reach with the folder it sits in (a drive not mounted): still the
            // project's. Only a checkout whose own folder is there without it was deleted.
            Err(_) if Path::new(&project.workspace).exists() || out_of_reach(Path::new(&project.workspace)) => {
                for root in &roots {
                    let location = worktrees::Location::Custom(root.clone());
                    folders.insert(resolved(&worktrees::root(&project.workspace, &location)), claim.clone());
                }
            }
            Err(_) => {}
        }
    }
    // The walk reads folders and files, which a slow or network volume can hold: off the workers.
    let walk = move || {
        let mut found = Vec::new();
        for root in roots {
            for folder in subfolders(&root).into_iter().filter(|folder| named_by_cascade(folder)) {
                let folder = resolved(&folder);
                for path in subfolders(&folder) {
                    let Some(mut tree) = shared(resolved(&path)) else { continue };
                    tree.project = claimed.get(&tree.path).or_else(|| folders.get(&folder))
                        .or_else(|| tree.repo.as_ref().and_then(|repo| checkouts.get(&resolved(Path::new(repo)))))
                        .cloned();
                    if tree.project.is_some() || made_by_cascade(&folder, tree.repo.as_deref()) {
                        found.push(tree);
                    }
                }
            }
        }
        found.sort_by(|a, b| a.path.cmp(&b.path));
        found.dedup_by(|a, b| a.path == b.path);
        found
    };
    Ok(tokio::task::spawn_blocking(walk).await?)
}

fn named_by_cascade(folder: &Path) -> bool {
    folder.file_name().and_then(|name| name.to_str()).is_some_and(worktrees::is_project_folder)
}

/// Whether a worktree no project claims is one Cascade made: its project folder has the very name
/// Cascade gives the checkout it came from. Once that checkout is gone the name's shape is all
/// there is to go by.
fn made_by_cascade(folder: &Path, repo: Option<&str>) -> bool {
    let name = folder.file_name().and_then(|name| name.to_str());
    match repo {
        Some(repo) => {
            let expected = worktrees::root(repo, &worktrees::Location::Custom(PathBuf::new()));
            name.is_some() && expected.file_name().and_then(|n| n.to_str()) == name
        }
        None => named_by_cascade(folder),
    }
}

pub(crate) fn resolved(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn subfolders(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else { return vec![] };
    entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect()
}

/// The worktree at `path`, when it is one: its `.git` is a file saying `gitdir: <common
/// dir>/worktrees/<name>`, absolute or, as `worktree.useRelativePaths` writes it, relative to the
/// worktree. A checkout (whose `.git` is a folder) or any other folder is None. Its `HEAD` is there
/// while the checkout it came from exists; the checkout is the common dir's parent, or the common
/// dir itself for a bare repository.
fn shared(path: PathBuf) -> Option<Shared> {
    if !fs::symlink_metadata(path.join(".git")).is_ok_and(|meta| meta.is_file()) {
        return None;
    }
    let named = fs::read_to_string(path.join(".git"))
        .ok()?
        .trim()
        .strip_prefix("gitdir:")
        .map(|dir| path.join(dir.trim()))?;
    if !named.parent().and_then(Path::file_name).is_some_and(|name| name == "worktrees") {
        return None;
    }
    let gitdir = Some(resolved(&named)).filter(|dir| dir.is_dir());
    let repo = gitdir
        .as_deref()
        .and_then(|dir| dir.parent()?.parent())
        .map(|common| if common.file_name().is_some_and(|name| name == ".git") { common.parent().unwrap_or(common) } else { common })
        .map(|repo| repo.to_string_lossy().into_owned());
    let branch = gitdir
        .and_then(|dir| fs::read_to_string(dir.join("HEAD")).ok())
        .and_then(|head| head.trim().strip_prefix("ref: refs/heads/").map(str::to_owned))
        .unwrap_or_default();
    Some(Shared { path, project: None, repo, branch })
}

/// Whether a session works in the worktree at `path`: its stored worktree is that folder, or names
/// a folder that is no longer there with the same project folder and worktree names. A worktree
/// moved with the folder around it (one nested in another that moved) keeps its session's old
/// spelling, and is still that session's. Unreadable sessions count as in use: a session's
/// worktree is never offered on a guess.
async fn sessions_in(app: &AppState) -> Option<Vec<PathBuf>> {
    let tasks = app.db.tasks().await.ok()?;
    Some(tasks.into_iter().filter(|t| !t.worktree.is_empty()).map(|t| resolved(Path::new(&t.worktree))).collect())
}

/// Which of `paths` a session works in, worked out off the runtime's workers: a stale session path
/// is looked for on disk.
async fn in_use_of(sessions: Option<Vec<PathBuf>>, paths: Vec<PathBuf>) -> Result<Vec<bool>, ApiError> {
    tokio::task::spawn_blocking(move || paths.iter().map(|path| in_use(&sessions, path)).collect())
        .await
        .map_err(ApiError::internal)
}

fn in_use(sessions: &Option<Vec<PathBuf>>, path: &Path) -> bool {
    let Some(sessions) = sessions else { return true };
    let place = |p: &Path| p.components().rev().take(2).map(|c| c.as_os_str().to_owned()).collect::<Vec<_>>();
    sessions.iter().any(|stored| stored == path || (!stored.exists() && place(stored) == place(path)))
}

pub async fn shared_worktrees_route(State(app): State<AppState>) -> ApiResult<Value> {
    let found = shared_worktrees(&app).await.map_err(ApiError::internal)?;
    let used = in_use_of(sessions_in(&app).await, found.iter().map(|w| w.path.clone()).collect()).await?;
    Ok(Json(Value::Array(
        found
            .into_iter()
            .zip(used)
            .map(|(w, used)| json!({
                "inUse": used,
                "path": w.path,
                "branch": w.branch,
                "projectId": w.project.as_ref().map(|p| &p.id),
                "projectName": w.project.as_ref().map(|p| &p.name),
                "workspace": w.project.as_ref().map(|p| &p.workspace),
                "repo": w.repo.unwrap_or_default(),
            }))
            .collect(),
    )))
}

/// How much disk each of `paths`, the rows the list shows, takes. Asked for apart from the list,
/// so the rows show at once, and for the paths the app already holds, so nothing is listed again:
/// each is measured only if it is one of Cascade's worktrees in a shared root that no session works
/// in. Walked off the runtime's workers, a few at a time, so many large worktrees never thrash the
/// disk together.
pub async fn shared_worktree_sizes(State(app): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    const WALKS: usize = 4;
    let asked: Vec<String> = body["paths"].as_array().into_iter().flatten().filter_map(|p| p.as_str().map(str::to_owned)).collect();
    let roots: Vec<PathBuf> = worktrees::shared_roots(&app).await.iter().map(|root| resolved(root)).collect();
    let found: Vec<PathBuf> = tokio::task::spawn_blocking(move || {
        asked.iter().map(|p| resolved(Path::new(p))).filter(|path| {
            let folder = path.parent();
            folder.is_some_and(named_by_cascade)
                && folder.and_then(Path::parent).is_some_and(|root| roots.iter().any(|r| r == root))
                && shared(path.clone()).is_some()
        }).collect()
    })
    .await
    .map_err(ApiError::internal)?;
    let used = in_use_of(sessions_in(&app).await, found.clone()).await?;
    let paths: Vec<PathBuf> = found.into_iter().zip(used).filter(|(_, used)| !used).map(|(path, _)| path).collect();
    let sizes = tokio::task::spawn_blocking(move || {
        let mut sizes = Map::new();
        for batch in paths.chunks(WALKS) {
            std::thread::scope(|scope| {
                let walks: Vec<_> = batch.iter().map(|path| scope.spawn(move || folder_size(path))).collect();
                for (path, walk) in batch.iter().zip(walks) {
                    sizes.insert(path.to_string_lossy().into_owned(), json!(walk.join().unwrap_or(0)));
                }
            });
        }
        sizes
    })
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(Value::Object(sizes)))
}

/// A missing checkout that may only be out of reach, not deleted: the folder it sits in is missing
/// too, or it is a drive's own folder under `/Volumes`, there only while the drive is mounted (and
/// macOS can leave an empty one behind once it is not).
fn out_of_reach(workspace: &Path) -> bool {
    if workspace.exists() {
        return false;
    }
    if !workspace.parent().is_some_and(Path::exists) {
        return true;
    }
    let mut parts = workspace.components();
    match (parts.next(), parts.next(), parts.next()) {
        (Some(std::path::Component::RootDir), Some(std::path::Component::Normal(volumes)), Some(std::path::Component::Normal(drive)))
            if volumes == "Volumes" => !mounted(&Path::new("/Volumes").join(drive)),
        _ => false,
    }
}

/// Whether `root` is a mounted drive: a folder on a device of its own, not `/Volumes`'.
fn mounted(root: &Path) -> bool {
    match (fs::metadata(root), fs::metadata("/Volumes")) {
        (Ok(drive), Ok(volumes)) => drive.dev() != volumes.dev(),
        _ => false,
    }
}

/// The disk a folder takes, as Finder counts it: the blocks of every file under it, links not
/// followed.
fn folder_size(root: &Path) -> u64 {
    let mut total = 0;
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.path().symlink_metadata() else { continue };
            if meta.is_dir() {
                pending.push(entry.path());
            } else {
                total += meta.blocks() * 512;
            }
        }
    }
    total
}

/// Deletes a leftover worktree folder: one `shared_worktrees_route` lists with no project. A
/// project's own worktree goes through `remove_worktree`, or its session's removal, which stops
/// what runs there first. It is looked up as the list looks it up, so the two never disagree about
/// what is a leftover: a project whose checkout is gone claims nothing in either. While its checkout
/// still knows it git removes it, and a refusal (a locked worktree) is the answer; the folder is
/// deleted by hand only once its checkout is gone or has forgotten it. Its branch goes as any
/// removed worktree's does (`worktrees::remove_branch`).
pub async fn remove_leftover_worktree(
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    let target = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let target = fs::canonicalize(resolve_path(target)).map_err(|e| unprocessable(e.to_string()))?;
    // Found the way the list finds it, so what the list offers as a leftover is exactly what may be
    // deleted as one: one of Cascade's, in a shared root, that no project claims.
    let found = shared_worktrees(&app)
        .await
        .map_err(ApiError::internal)?
        .into_iter()
        .find(|w| w.path == target && w.project.is_none())
        .ok_or_else(|| ApiError::conflict(format!("{} is not a leftover worktree", target.display())))?;
    if in_use_of(sessions_in(&app).await, vec![found.path.clone()]).await?[0] {
        return Err(ApiError::conflict("A session works in this worktree. Remove the session instead."));
    }
    let path = found.path.to_string_lossy().into_owned();
    let derived = crate::xcode::derived_data_of(&found.path).await;
    let mut deleted = false;
    // A checkout git cannot read just now has not forgotten the worktree: that is an error to show,
    // never a reason to delete the folder by hand.
    let known = match &found.repo {
        Some(repo) => try_list_worktrees(repo)
            .await
            .map_err(|e| unprocessable(format!("git could not read {repo}: {}", error_line(&e.to_string()))))?
            .iter()
            .any(|tree| resolved(Path::new(&tree.path)) == target),
        None => false,
    };
    if let (Some(repo), true) = (&found.repo, known) {
        git(repo, vec!["worktree".into(), "remove".into(), "--force".into(), path.clone()], 60)
            .await
            .map_err(|e| unprocessable(worktree_failure(&found.branch, e.to_string())))?;
        if !found.branch.is_empty() {
            deleted = worktrees::remove_branch(&app, repo, &found.branch).await;
        }
    } else {
        let doomed = found.path.clone();
        tokio::task::spawn_blocking(move || fs::remove_dir_all(doomed))
            .await
            .map_err(ApiError::internal)?
            .map_err(|e| unprocessable(e.to_string()))?;
        if let Some(repo) = &found.repo {
            let _ = git(repo, vec!["worktree".into(), "prune".into()], 20).await;
        }
    }
    crate::xcode::forget_answers(&app, &found.path).await;
    worktrees::spawn_derived_data_removal(&app, &path, derived);
    // A project folder goes with its last worktree; one still holding another stays.
    if let Some(folder) = found.path.parent() {
        let _ = fs::remove_dir(folder);
    }
    Ok(Json(json!({"ok": true, "branchDeleted": deleted})))
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

#[cfg(test)]
mod reach_tests {
    use super::*;

    #[test]
    fn a_missing_checkout_is_out_of_reach_only_where_it_could_be_unmounted() {
        let here = tempfile::tempdir().unwrap();
        // Deleted: the folder it sat in is still there.
        assert!(!out_of_reach(&here.path().join("deleted")));
        // The folder it sat in is gone too.
        assert!(out_of_reach(&here.path().join("drive/app")));
        // A drive's own folder, or anything on it, while that drive is not mounted.
        assert!(out_of_reach(Path::new("/Volumes/No Such Drive 9f3e")));
        assert!(out_of_reach(Path::new("/Volumes/No Such Drive 9f3e/code/app")));
        // There: never out of reach.
        assert!(!out_of_reach(here.path()));
    }
}
