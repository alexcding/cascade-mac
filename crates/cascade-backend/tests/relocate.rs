//! The one-time move of sessions' worktrees into Cascade's folder. One test, alone in its binary,
//! since Cascade's folder is named by the environment and that is the whole process's.

use std::{fs, path::{Path, PathBuf}, process::Command};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use cascade_backend::{build_app, AppState, Database};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn send(app: &axum::Router, method: &str, path: &str, body: Option<Value>) -> (StatusCode, Value) {
    let request = Request::builder().method(method).uri(path).header("content-type", "application/json");
    let body = body.map_or_else(Body::empty, |value| Body::from(value.to_string()));
    let response = app.clone().oneshot(request.body(body).unwrap()).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t", "-C"])
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[tokio::test]
async fn sessions_worktrees_move_into_cascades_folder_once_and_only_when_asked_to() {
    let data = tempfile::tempdir().unwrap();
    let parent = tempfile::tempdir().unwrap();
    // As the temporary folder is named, `/var/…`, while git lists its real path, `/private/var/…`:
    // the two spellings are one worktree.
    let base = parent.path().to_path_buf();
    let real = base.canonicalize().unwrap();
    let shared = real.join("cascade-worktrees");
    std::env::set_var("CASCADE_WORKTREES_DIR", &shared);
    let app = build_app(AppState::new(Database::open(data.path()).unwrap(), None));

    let dir = base.join("app");
    fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    git(&dir, &["commit", "-q", "--allow-empty", "-m", "init"]);
    // Made where every worktree went before Cascade's folder was the default.
    send(&app, "POST", "/api/config", Some(json!({"worktree_location":"sibling"}))).await;
    let (_, project) = send(&app, "POST", "/api/projects", Some(json!({"name":"App","workspace":dir.to_str().unwrap()}))).await;
    let (status, session) = send(&app, "POST", "/api/sessions", Some(json!({"projectId":project["id"],"branch":"feat","createBranch":true,"base":"main","cli":"claude"}))).await;
    assert_eq!(status, StatusCode::OK, "{session}");
    let old = PathBuf::from(session["worktree"].as_str().unwrap());
    assert_eq!(old.canonicalize().unwrap(), real.join("app.worktrees/feat"));
    fs::write(old.join("draft.txt"), "uncommitted").unwrap();
    // A second session on the same worktree, which stored its path another way.
    let twin = json!({"id":"twin","projectId":project["id"],"workspace":dir.to_str().unwrap(),"worktree":format!("{}/", old.display()),"branch":"feat","cli":""});
    let (status, _) = send(&app, "POST", "/api/tasks", Some(twin)).await;
    assert_eq!(status, StatusCode::OK);

    let (_, offer) = send(&app, "GET", "/api/worktrees/relocation", None).await;
    assert_eq!(offer["due"], true, "{offer}");
    assert_eq!(offer["worktrees"].as_array().map(Vec::len), Some(1), "{offer}");
    let sessions = offer["worktrees"][0]["sessions"].as_array().unwrap();
    assert!(sessions.contains(&session["id"]) && sessions.contains(&json!("twin")), "one worktree, both sessions: {offer}");

    // Declined: nothing moves, the folder is made, and nobody is asked again.
    let (status, _) = send(&app, "POST", "/api/worktrees/relocation", Some(json!({"move": false}))).await;
    assert_eq!(status, StatusCode::OK);
    assert!(shared.is_dir() && old.is_dir());
    let (_, offer) = send(&app, "GET", "/api/worktrees/relocation", None).await;
    assert_eq!(offer["due"], false, "{offer}");

    // Accepted: the worktree, its uncommitted file and its session move, and new ones follow.
    fs::remove_dir(&shared).unwrap();
    let (status, moved) = send(&app, "POST", "/api/worktrees/relocation", Some(json!({"move": true}))).await;
    assert_eq!(status, StatusCode::OK, "{moved}");
    let new = Path::new(moved["moved"][0]["to"].as_str().unwrap()).to_path_buf();
    assert!(new.starts_with(&shared) && new.ends_with("feat"), "{moved}");
    assert_eq!(fs::read_to_string(new.join("draft.txt")).unwrap(), "uncommitted");
    assert!(!old.exists() && !real.join("app.worktrees").exists());
    assert!(git(&dir, &["worktree", "list"]).contains(new.to_str().unwrap()));

    // The session works on where it went: git there is the same checkout on the same branch, with
    // the same uncommitted file, and the session record and everything that reads it say so.
    assert_eq!(git(&new, &["rev-parse", "--abbrev-ref", "HEAD"]), "feat");
    assert_eq!(git(&new, &["status", "--porcelain"]), "?? draft.txt");
    let (_, tasks) = send(&app, "GET", "/api/tasks", None).await;
    let paths: Vec<&str> = tasks.as_array().unwrap().iter().map(|t| t["worktree"].as_str().unwrap()).collect();
    assert_eq!(paths, [new.to_str().unwrap(); 2], "both sessions follow, however each spelled it");
    let (_, resolved) = send(&app, "GET", &format!("/api/worktree?path={}&branch=feat", dir.to_str().unwrap()), None).await;
    assert_eq!(resolved["path"], new.to_str().unwrap(), "{resolved}");
    let (_, config) = send(&app, "GET", "/api/config", None).await;
    assert_eq!(config["worktree_location"], "cascade");
    let (_, offer) = send(&app, "GET", "/api/worktrees/relocation", None).await;
    assert_eq!(offer["due"], false);

    // And removing it later works as for any worktree.
    let (status, removed) = send(&app, "POST", "/api/worktree/remove", Some(json!({"path":dir.to_str().unwrap(),"worktree":new.to_str().unwrap(),"force":true}))).await;
    assert_eq!(status, StatusCode::OK, "{removed}");
    assert!(!new.exists());
}
