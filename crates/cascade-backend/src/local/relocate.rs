//! The one-time move of sessions' worktrees into Cascade's folder, `~/.cascade/worktrees`, made
//! before it was the default. The folder is the flag: until it exists the app asks once, and
//! whatever the answer, it is made then, so nobody is asked again. Someone who chose to keep
//! worktrees inside their checkouts or in a folder of their own is not asked at all.

use super::*;

/// A session worktree outside Cascade's folder, and where it would go.
struct Candidate {
    /// The path as git lists it.
    from: String,
    /// The path as each of its sessions stores it, which their records, chats, tabs and agent
    /// history are matched by: one spelling usually, more when sessions wrote it differently.
    stored: Vec<String>,
    workspace: String,
    to: PathBuf,
    sessions: Vec<String>,
    /// Why it stays where it is, when it cannot move.
    blocked: Option<String>,
}

fn shared_root() -> PathBuf {
    worktrees::default_root()
}

/// Whether the app should ask: Cascade's folder does not exist yet, and the location was never
/// chosen as inside the checkout or a custom folder. "Next to the project" was every install's
/// default, saved with the rest of Settings, so it does not say someone chose it.
async fn due(app: &AppState) -> bool {
    let chosen = app.db.config_value(worktrees::LOCATION).await.ok().flatten();
    !shared_root().exists() && !matches!(chosen.as_deref(), Some("inside" | "custom"))
}

/// Each checkout is listed once, all at once: this runs while the app waits to start. A session's
/// path is compared with git's resolved, so `/var/…` and `/private/var/…` are the same worktree.
async fn candidates(app: &AppState) -> anyhow::Result<Vec<Candidate>> {
    let root = resolved(&shared_root());
    let tasks = app.db.tasks().await?;
    let mut workspaces: Vec<String> = tasks.iter().map(|t| t.workspace.clone()).filter(|w| !w.is_empty()).collect();
    workspaces.sort();
    workspaces.dedup();
    let listings = futures_util::future::join_all(workspaces.iter().map(|w| list_worktrees(w))).await;
    // Every linked worktree, by its resolved path: the checkout it belongs to, and git's spelling.
    let mut linked: HashMap<PathBuf, (String, String)> = HashMap::new();
    for (workspace, trees) in workspaces.iter().zip(listings) {
        for tree in trees.into_iter().filter(|tree| !tree.main) {
            linked.insert(resolved(Path::new(&tree.path)), (workspace.clone(), tree.path));
        }
    }
    let mut found: Vec<Candidate> = Vec::new();
    for task in tasks {
        if task.worktree.is_empty() {
            continue;
        }
        let key = resolved(Path::new(&task.worktree));
        // Only a linked worktree of a session's checkout: never a checkout itself, nor a folder git
        // does not know, nor one already in Cascade's folder.
        let Some((workspace, from)) = linked.get(&key).filter(|_| !key.starts_with(&root)) else { continue };
        if let Some(known) = found.iter_mut().find(|c| resolved(Path::new(&c.from)) == key) {
            known.sessions.push(task.id);
            if !known.stored.contains(&task.worktree) {
                known.stored.push(task.worktree);
            }
            continue;
        }
        let leaf = key.file_name().map(|v| v.to_owned()).unwrap_or_default();
        let to = worktrees::root(workspace, &worktrees::Location::Custom(shared_root())).join(leaf);
        let blocked = to.exists().then(|| format!("{} already exists", to.display()));
        found.push(Candidate {
            from: from.clone(), stored: vec![task.worktree], workspace: workspace.clone(), to, sessions: vec![task.id], blocked,
        });
    }
    Ok(found)
}

pub async fn worktree_relocation(State(app): State<AppState>) -> ApiResult<Value> {
    if !due(&app).await {
        return Ok(Json(json!({"due": false, "worktrees": []})));
    }
    let found = candidates(&app).await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "due": true,
        "root": shared_root(),
        "worktrees": found.iter().map(|c| json!({
            "path": c.from, "to": c.to, "sessions": c.sessions, "blocked": c.blocked,
        })).collect::<Vec<_>>(),
    })))
}

/// `{"move": true}` moves every session worktree it can, with what each session and its chats and
/// agent history know of its path (the history once for all of them, off the runtime's workers,
/// since it walks every agent's sessions), and makes Cascade's folder the location for new ones;
/// `{"move": false}` moves nothing. Either way Cascade's folder is made, which ends the asking. The
/// app stops the sessions' terminals first: a folder moved under a running shell leaves it nowhere.
pub async fn relocate_worktrees(State(app): State<AppState>, Json(body): Json<Value>) -> ApiResult<Value> {
    let root = shared_root();
    let (mut moved, mut skipped) = (Vec::new(), Vec::new());
    // Every spelling of every moved worktree, to its new path: the agents' history, in one pass.
    let mut history: HashMap<String, String> = HashMap::new();
    if body["move"].as_bool().unwrap_or(false) {
        for candidate in candidates(&app).await.map_err(ApiError::internal)? {
            if let Some(reason) = candidate.blocked {
                skipped.push(json!({"path": candidate.from, "reason": reason}));
                continue;
            }
            match relocate(&app, &candidate).await {
                Ok(()) => {
                    let to = candidate.to.to_string_lossy().into_owned();
                    for path in candidate.stored.iter().chain([&candidate.from]) {
                        history.insert(path.clone(), to.clone());
                    }
                    moved.push(json!({
                        "path": candidate.from, "stored": candidate.stored, "to": candidate.to, "sessions": candidate.sessions,
                    }));
                }
                Err(reason) => skipped.push(json!({"path": candidate.from, "reason": reason})),
            }
        }
        tokio::task::spawn_blocking(move || crate::agents::move_worktrees_history(&history))
            .await
            .map_err(ApiError::internal)?;
        let location = json!({ worktrees::LOCATION: "cascade" });
        app.db.set_config(location.as_object().unwrap()).await?;
    }
    fs::create_dir_all(&root).map_err(|e| unprocessable(format!("{}: {e}", root.display())))?;
    let _ = app.db.add_log(
        "worktree",
        if skipped.is_empty() { "info" } else { "warn" },
        "worktrees_relocated",
        &json!({"moved": moved.len(), "skipped": skipped}),
    ).await;
    Ok(Json(json!({"ok": true, "moved": moved, "skipped": skipped})))
}

/// `git worktree move` carries the folder, uncommitted and ignored files included, and git's
/// record of it; a locked worktree, or one with submodules, git refuses and it stays. The sessions'
/// records follow, or the folder goes back: a session is never left naming a folder that moved.
async fn relocate(app: &AppState, candidate: &Candidate) -> Result<(), String> {
    let parent = candidate.to.parent().ok_or("no folder to move into")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let to = candidate.to.to_string_lossy().into_owned();
    let mv = |from: &str, to: &str| vec!["worktree".into(), "move".into(), from.to_owned(), to.to_owned()];
    git(&candidate.workspace, mv(&candidate.from, &to), 60)
        .await
        .map_err(|e| error_line(&e.to_string()))?;
    if let Err(error) = app.db.move_worktree(&candidate.stored, &to).await {
        let back = git(&candidate.workspace, mv(&to, &candidate.from), 60).await;
        let _ = fs::remove_dir(parent);
        return Err(match back {
            Ok(_) => format!("its sessions could not be updated, so it was moved back: {error}"),
            Err(back) => format!("its sessions could not be updated, and moving it back failed: {error}; {}", error_line(&back.to_string())),
        });
    }
    for path in &candidate.stored {
        crate::chat::move_worktree_chats(app, path, &to).await;
        crate::xcode::forget_answers(app, Path::new(path)).await;
    }
    // The folder it was made in goes once it is empty: `<project>.worktrees` holds nothing else.
    if let Some(old) = Path::new(&candidate.from).parent() {
        let _ = fs::remove_dir(old);
    }
    Ok(())
}
