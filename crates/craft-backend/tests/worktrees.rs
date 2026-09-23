use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use craft_backend::{build_app, AppState, Database};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tempfile::TempDir;
use tower::ServiceExt;

fn app() -> (axum::Router, TempDir) {
    let directory = tempfile::tempdir().unwrap();
    let db = Database::open(directory.path()).unwrap();
    (build_app(AppState::new(db, None)), directory)
}

async fn post(app: &axum::Router, path: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap())
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

/// A checkout with tracked, ignored and merely untracked files, so a copy can be checked for
/// taking exactly the ignored files the patterns name.
fn repo(parent: &Path) -> PathBuf {
    let dir = parent.join("app");
    fs::create_dir_all(dir.join("config")).unwrap();
    git(&dir, &["init", "-q", "-b", "main"]);
    fs::write(dir.join(".gitignore"), ".env*\nconfig/*.local\nnode_modules/\n").unwrap();
    fs::write(dir.join(".env.example"), "tracked").unwrap();
    git(&dir, &["add", "-A"]);
    git(&dir, &["add", "-f", ".env.example"]);
    git(&dir, &["commit", "-qm", "init"]);
    fs::write(dir.join(".env"), "secret").unwrap();
    fs::write(dir.join(".env.local"), "local").unwrap();
    fs::write(dir.join("config/app.local"), "local config").unwrap();
    fs::create_dir_all(dir.join("node_modules/pkg")).unwrap();
    fs::write(dir.join("node_modules/pkg/.env"), "dependency").unwrap();
    fs::write(dir.join("notes.env"), "untracked, not ignored").unwrap();
    dir
}

#[tokio::test]
async fn new_worktrees_follow_the_location_setting_and_copy_included_ignored_files() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    // Worktrees are recorded by their real path, and /var is a link to /private/var.
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();

    // Sibling by default, with `.env*` as the default patterns.
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"feat/one","create":true})).await;
    let one = root.join("app.worktrees/one");
    assert_eq!(made["path"], one.to_str().unwrap(), "{made}");
    assert_eq!(fs::read_to_string(one.join(".env")).unwrap(), "secret");
    assert!(one.join(".env.local").exists());
    // Ignored only: an untracked file that no .gitignore names never follows.
    assert!(!one.join("notes.env").exists());
    assert!(!one.join("config/app.local").exists());

    // Inside the checkout, excluded through info/exclude so the main checkout stays clean.
    let custom = root.join("elsewhere");
    post(&app, "/api/config", json!({"worktree_location":"inside","worktree_include":"config/*.local\n.env\n!.env.local"})).await;
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"two","create":true})).await;
    let two = dir.join(".worktrees/two");
    assert_eq!(made["path"], two.to_str().unwrap(), "{made}");
    assert!(!git(&dir, &["status", "--porcelain"]).contains(".worktrees"));
    assert!(two.join("config/app.local").exists());
    assert!(two.join(".env").exists());
    assert!(!two.join(".env.local").exists(), "a later ! pattern re-includes");

    // A committed .worktreeinclude wins over Settings outright.
    fs::write(dir.join(".worktreeinclude"), "node_modules/pkg/.env\n").unwrap();
    post(&app, "/api/config", json!({"worktree_location":"custom","worktree_root":custom.to_str().unwrap()})).await;
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"three","create":true})).await;
    let three = PathBuf::from(made["path"].as_str().unwrap());
    // `<folder>/<checkout folder>-<hash>/<branch>`.
    assert_eq!(three.parent().unwrap().parent().unwrap(), custom, "{made}");
    assert!(three.parent().unwrap().file_name().unwrap().to_str().unwrap().starts_with("app-"));
    assert!(three.ends_with("three"));
    assert!(three.join("node_modules/pkg/.env").exists());
    assert!(!three.join(".env").exists());
}

#[tokio::test]
async fn fetch_before_create_is_opt_in_and_cuts_from_the_fetched_tip() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let upstream = repo(&root);
    let clone = root.join("clone");
    git(&root, &["clone", "-q", upstream.to_str().unwrap(), clone.to_str().unwrap()]);
    fs::write(upstream.join("new.txt"), "new").unwrap();
    git(&upstream, &["add", "new.txt"]);
    git(&upstream, &["commit", "-qm", "upstream moved"]);
    let tip = git(&upstream, &["rev-parse", "HEAD"]);
    let path = clone.to_str().unwrap();

    // Off by default: cut from what the clone already has.
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"stale","create":true})).await;
    assert_ne!(git(Path::new(made["path"].as_str().unwrap()), &["rev-parse", "HEAD"]), tip);

    post(&app, "/api/config", json!({"worktree_fetch":"true"})).await;
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"fresh","create":true})).await;
    assert_eq!(git(Path::new(made["path"].as_str().unwrap()), &["rev-parse", "HEAD"]), tip);
}

/// Enough paths to fill both pipes of `check-ignore --stdin` many times over: a write that has
/// to finish before the output is read would hang New Session here.
#[tokio::test]
async fn a_large_include_set_copies_without_wedging_the_create() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let many = dir.join("node_modules/pkg");
    for i in 0..20_000 {
        fs::write(many.join(format!("file-with-a-longish-name-{i:05}.js")), "").unwrap();
    }
    fs::write(dir.join(".worktreeinclude"), "node_modules/\n").unwrap();
    let request = post(&app, "/api/worktree", json!({"path":dir.to_str().unwrap(),"branch":"many","create":true}));
    let (_, made) = tokio::time::timeout(Duration::from_secs(90), request).await.expect("create wedged");
    let tree = PathBuf::from(made["path"].as_str().unwrap());
    assert_eq!(fs::read_dir(tree.join("node_modules/pkg")).unwrap().count(), 20_001);
}

#[tokio::test]
async fn existing_files_are_never_overwritten() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    // Worktrees are recorded by their real path, and /var is a link to /private/var.
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    // The branch already carries its own .env as a tracked file.
    git(&dir, &["switch", "-qc", "carries-env"]);
    fs::write(dir.join(".env"), "branch").unwrap();
    git(&dir, &["add", "-f", ".env"]);
    git(&dir, &["commit", "-qm", "env"]);
    git(&dir, &["switch", "-q", "main"]);
    fs::write(dir.join(".env"), "secret").unwrap();

    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"carries-env"})).await;
    let tree = PathBuf::from(made["path"].as_str().unwrap());
    assert_eq!(fs::read_to_string(tree.join(".env")).unwrap(), "branch");
    assert!(tree.join(".env.local").exists());
}

#[tokio::test]
async fn setup_runs_in_the_new_worktree_and_removal_deletes_only_merged_branches() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    // Worktrees are recorded by their real path, and /var is a link to /private/var.
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    post(&app, "/api/config", json!({"worktree_setup":"printf %s \"$CRAFT_ROOT_PATH\" > setup-ran","worktree_delete_branch":"true"})).await;

    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"merged","create":true})).await;
    let merged = PathBuf::from(made["path"].as_str().unwrap());
    let marker = merged.join("setup-ran");
    let deadline = Instant::now() + Duration::from_secs(20);
    // On the content, not the file: the file appears before the shell writes into it.
    while fs::read_to_string(&marker).unwrap_or_default() != path && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(fs::read_to_string(&marker).unwrap(), path);

    let (_, removed) = post(&app, "/api/worktree/remove", json!({"path":path,"worktree":merged,"force":true})).await;
    assert_eq!(removed["branchDeleted"], true, "{removed}");
    assert_eq!(git(&dir, &["branch", "--list", "merged"]), "");

    // Unmerged work keeps its branch: removal is a cleanup, never a discard.
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"unmerged","create":true})).await;
    let unmerged = PathBuf::from(made["path"].as_str().unwrap());
    fs::write(unmerged.join("work.txt"), "work").unwrap();
    git(&unmerged, &["add", "work.txt"]);
    git(&unmerged, &["commit", "-qm", "work"]);
    let (_, removed) = post(&app, "/api/worktree/remove", json!({"path":path,"worktree":unmerged,"force":true})).await;
    assert_eq!(removed["branchDeleted"], false, "{removed}");
    assert_ne!(git(&dir, &["branch", "--list", "unmerged"]), "");
}
