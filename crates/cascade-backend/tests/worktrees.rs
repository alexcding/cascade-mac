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
use cascade_backend::{build_app, AppState, Database};
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

async fn get(app: &axum::Router, path: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(Request::builder().method("GET").uri(path).body(Body::empty()).unwrap())
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

#[tokio::test]
async fn tracked_reports_what_a_new_worktree_will_check_out() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    fs::create_dir_all(dir.join("scripts")).unwrap();
    for name in ["run.sh", "plain.sh", "new.sh"] {
        fs::write(dir.join("scripts").join(name), "echo hi\n").unwrap();
    }
    git(&dir, &["add", "scripts/run.sh", "scripts/plain.sh"]);
    git(&dir, &["update-index", "--chmod=+x", "scripts/run.sh"]);
    git(&dir, &["commit", "-qm", "scripts"]);
    // Executable on disk only: git still records 644, and that is what a worktree gets.
    let mut mode = fs::metadata(dir.join("scripts/plain.sh")).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut mode, 0o755);
    fs::set_permissions(dir.join("scripts/plain.sh"), mode).unwrap();
    let get = |rel: &str| {
        let uri = format!("/api/git/tracked?path={}&rel={rel}", dir.display());
        let app = app.clone();
        async move {
            let response = app.oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap()).await.unwrap();
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            serde_json::from_slice::<Value>(&bytes).unwrap()
        }
    };
    assert_eq!(get("scripts/run.sh").await, json!({"tracked":true,"executable":true}));
    assert_eq!(get("scripts/plain.sh").await, json!({"tracked":true,"executable":false}));
    assert_eq!(get("scripts/new.sh").await, json!({"tracked":false,"executable":false}));
}

#[tokio::test]
async fn project_patterns_beat_the_default_and_a_worktreeinclude_beats_both() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    post(&app, "/api/config", json!({"worktree_include":".env"})).await;
    let (status, _) = post(&app, "/api/projects", json!({"name":"App","repo":"example/app","workspace":path,"worktreeInclude":"config/*.local"})).await;
    assert_eq!(status, StatusCode::OK);
    // Another project's patterns never apply here.
    post(&app, "/api/projects", json!({"name":"Other","repo":"example/other","workspace":root.join("other").to_str().unwrap(),"worktreeInclude":".env.local"})).await;

    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"project","create":true})).await;
    let tree = PathBuf::from(made["path"].as_str().unwrap());
    assert!(tree.join("config/app.local").exists());
    assert!(!tree.join(".env").exists() && !tree.join(".env.local").exists());

    fs::write(dir.join(".worktreeinclude"), ".env.local\n").unwrap();
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"repo-file","create":true})).await;
    let tree = PathBuf::from(made["path"].as_str().unwrap());
    assert!(tree.join(".env.local").exists());
    assert!(!tree.join("config/app.local").exists());
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
    // The setup script is the project's own; the branch cleanup is global.
    let (status, project) = post(&app, "/api/projects", json!({"name":"App","repo":"example/app","workspace":format!("{path}/"),"worktreeSetup":"printf %s \"$CASCADE_ROOT_PATH\" > setup-ran"})).await;
    assert_eq!(status, StatusCode::OK, "{project}");
    post(&app, "/api/config", json!({"worktree_delete_branch":"true"})).await;

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

#[tokio::test]
async fn history_lists_the_branch_on_its_base_and_the_whole_history_on_request() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let dir = repo(parent.path());
    let log = |query: &str| {
        let uri = format!("/api/git/log?path={}&{query}", dir.to_str().unwrap());
        let app = app.clone();
        async move {
            let response = app.oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap()).await.unwrap();
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            let page = serde_json::from_slice::<Value>(&bytes).unwrap();
            let subjects = page["commits"].as_array().unwrap().iter().map(|c| c["subject"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
            (subjects, page["base"].clone(), page["viewing"].clone(), page["historyRevision"].as_str().unwrap().to_owned(), page["older"].clone())
        }
    };
    let ahead = "aheadOnly=1&base=main&ref=";
    let whole = "aheadOnly=0&base=&ref=HEAD";

    // On the base itself there is nothing to measure against: the whole history, no base.
    let page = log(ahead).await;
    assert_eq!((page.0, page.1, page.2), (vec!["init".to_owned()], Value::Null, json!("HEAD")));

    // A new branch has added nothing yet, and says so rather than listing its base's commits.
    git(&dir, &["checkout", "-qb", "feature"]);
    let page = log(ahead).await;
    assert_eq!((page.0, page.1, page.2, page.4), (vec![], json!("main"), json!("HEAD"), json!(true)));
    let before = log(whole).await;
    assert_eq!(before.0, ["init"]);

    for name in ["one", "two"] {
        fs::write(dir.join(name), name).unwrap();
        git(&dir, &["add", name]);
        git(&dir, &["commit", "-qm", name]);
    }
    assert_eq!(log(ahead).await.0, ["two", "one"]);
    // The branch moved, so its history is another list: paging on across that is caught.
    assert_ne!(log(whole).await.3, before.3);
    assert_eq!(log(whole).await.3, log(&format!("{whole}&skip=1")).await.3);
    assert_eq!(log(&format!("{ahead}&skip=1&limit=1")).await.0, ["one"]);
    assert_eq!(log(&format!("{ahead}&skip=2&limit=1")).await.0, Vec::<String>::new());
    assert_eq!(log(&format!("{whole}&skip=1")).await.0, ["one", "init"]);

    // A folder named like the base leaves the base a revision: still only the branch's commits, and
    // still a list that moves when the branch does.
    let moved = log(ahead).await.3;
    fs::create_dir_all(dir.join("main")).unwrap();
    fs::write(dir.join("main/three"), "three").unwrap();
    git(&dir, &["add", "main/three"]);
    git(&dir, &["commit", "-qm", "three"]);
    let page = log(ahead).await;
    assert_eq!(page.0, ["three", "two", "one"]);
    assert_ne!(page.3, moved);

    // A branch sharing nothing with its base has no older history to offer.
    git(&dir, &["checkout", "-q", "--orphan", "lone"]);
    git(&dir, &["commit", "-qm", "lone"]);
    let page = log(ahead).await;
    assert_eq!((page.0, page.4), (vec!["lone".to_owned()], json!(false)));
    git(&dir, &["checkout", "-q", "feature"]);

    // Detached, there is no branch to have added anything: the whole history again.
    git(&dir, &["checkout", "-q", "--detach"]);
    let page = log(ahead).await;
    assert_eq!((page.0, page.1, page.2), (vec!["three".to_owned(), "two".to_owned(), "one".to_owned(), "init".to_owned()], Value::Null, json!("HEAD")));
}

#[tokio::test]
async fn a_fork_numbers_itself_after_its_family_and_carries_uncommitted_work() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    fs::write(dir.join("staged.txt"), "one").unwrap();
    fs::write(dir.join("edited.txt"), "one").unwrap();
    fs::write(dir.join("gone.txt"), "one").unwrap();
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "-qm", "files"]);
    let (_, made) = post(&app, "/api/worktree", json!({"path":path,"branch":"feat/fix","create":true})).await;
    let source = PathBuf::from(made["path"].as_str().unwrap());
    let task = json!({"id":"source","projectId":"p","workspace":path,"worktree":source,"branch":"feat/fix",
                      "title":"Fix it","url":"session:source","cli":"claude","sessionId":""});
    post(&app, "/api/tasks", task).await;

    fs::write(source.join("staged.txt"), "two").unwrap();
    git(&source, &["add", "staged.txt"]);
    fs::write(source.join("edited.txt"), "two").unwrap();
    fs::remove_file(source.join("gone.txt")).unwrap();
    fs::create_dir_all(source.join("new")).unwrap();
    fs::write(source.join("new/file.txt"), "fresh").unwrap();
    let before = git(&source, &["status", "--porcelain"]);

    let (status, forked) = post(&app, "/api/tasks/source/fork", json!({})).await;
    assert_eq!(status, StatusCode::OK, "{forked}");
    assert_eq!(forked["warning"], Value::Null, "{forked}");
    let task = &forked["task"];
    assert_eq!((&task["name"], &task["branch"], &task["title"]), (&json!("fix (2)"), &json!("feat/fix-2"), &json!("Fix it")));
    assert_eq!((&task["cli"], &task["sessionId"], &task["pinned"]), (&json!("claude"), &json!(""), &json!(false)));
    // No conversation on disk to fork: the fork's agent starts a new one.
    assert_eq!(task["forkFrom"], "", "{forked}");
    assert_eq!(task["forkedFrom"], "source", "{forked}");
    assert_ne!(task["url"], "session:source");
    let fork = PathBuf::from(task["worktree"].as_str().unwrap());
    assert!(fork.ends_with("fix-2"), "{forked}");
    assert_eq!(git(&fork, &["status", "--porcelain"]), before, "staged, unstaged and new alike");
    assert_eq!(fs::read_to_string(fork.join("new/file.txt")).unwrap(), "fresh");
    assert_eq!(git(&source, &["status", "--porcelain"]), before, "the source is left as it was");

    // A fork of the fork is the family's next, not `fix (2) (2)`; a branch already taken is skipped
    // and the name follows the branch. A fork not yet talked to has no conversation of its own, so
    // its fork starts from what it would have.
    let id = task["id"].as_str().unwrap().to_owned();
    let pending = app.clone().oneshot(Request::builder().method("PATCH").uri(format!("/api/tasks/{id}"))
        .header("content-type", "application/json").body(Body::from(json!({"forkFrom":"source-conversation"}).to_string())).unwrap())
        .await.unwrap();
    assert_eq!(pending.status(), StatusCode::OK);
    let (_, again) = post(&app, &format!("/api/tasks/{id}/fork"), json!({})).await;
    assert_eq!((&again["task"]["name"], &again["task"]["branch"]), (&json!("fix (3)"), &json!("feat/fix-3")), "{again}");
    assert_eq!(again["task"]["forkFrom"], "source-conversation", "{again}");
    git(&dir, &["branch", "feat/fix-4"]);
    let (_, skipped) = post(&app, "/api/tasks/source/fork", json!({})).await;
    assert_eq!((&skipped["task"]["name"], &skipped["task"]["branch"]), (&json!("fix (5)"), &json!("feat/fix-5")), "{skipped}");

    // Work git cannot snapshot (an intent-to-add file) is reported, and the new files still come across.
    fs::write(source.join("intent.txt"), "planned").unwrap();
    git(&source, &["add", "-N", "intent.txt"]);
    fs::write(source.join("loose.txt"), "loose").unwrap();
    let (status, partial) = post(&app, "/api/tasks/source/fork", json!({})).await;
    assert_eq!(status, StatusCode::OK, "{partial}");
    assert!(partial["warning"].as_str().is_some_and(|w| w.contains("uncommitted")), "{partial}");
    let partial = PathBuf::from(partial["task"]["worktree"].as_str().unwrap());
    assert_eq!(fs::read_to_string(partial.join("loose.txt")).unwrap(), "loose");

    // Two forks at once are made one after the other: each gets a number of its own.
    let (one, two) = tokio::join!(post(&app, "/api/tasks/source/fork", json!({})), post(&app, "/api/tasks/source/fork", json!({})));
    let mut names = [one.1["task"]["name"].clone(), two.1["task"]["name"].clone()];
    names.sort_by_key(|name| name.to_string());
    assert_eq!(names, [json!("fix (7)"), json!("fix (8)")], "{one:?} {two:?}");

    let shell = json!({"id":"shell","projectId":"p","workspace":path,"worktree":source,"branch":"feat/fix","cli":""});
    post(&app, "/api/tasks", shell).await;
    let (status, refused) = post(&app, "/api/tasks/shell/fork", json!({})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{refused}");
}

#[tokio::test]
async fn a_session_is_created_in_one_request_reusing_or_making_its_worktree() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    git(&dir, &["branch", "develop"]);
    let (status, project) = post(&app, "/api/projects", json!({"name":"App","repo":"example/app","workspace":path})).await;
    assert_eq!(status, StatusCode::OK, "{project}");
    let project_id = project["id"].as_str().unwrap();

    // A new branch: cut from the base, its worktree made, the record written last and answered
    // as the task list will show it.
    let (status, session) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/one","createBranch":true,"base":"main","title":"One","cli":"claude"})).await;
    assert_eq!(status, StatusCode::OK, "{session}");
    let one = root.join("app.worktrees/one");
    assert_eq!(session["worktree"], one.to_str().unwrap());
    assert_eq!(session["title"], "One");
    assert_eq!(session["branch"], "feat/one");
    assert_eq!(session["cli"], "claude");
    assert_eq!(session["pinned"], false);
    assert!(session["url"].as_str().unwrap().starts_with("session:"));
    assert!(one.join(".git").exists());
    let (_, tasks) = get(&app, "/api/tasks").await;
    assert_eq!(tasks.as_array().map(Vec::len), Some(1));
    assert_eq!(tasks[0]["id"], session["id"]);

    // The same branch again reuses the worktree; the session is new and titled by the branch.
    let (status, again) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/one"})).await;
    assert_eq!(status, StatusCode::OK, "{again}");
    assert_eq!(again["worktree"], session["worktree"]);
    assert_ne!(again["id"], session["id"]);
    assert_eq!(again["title"], "feat/one");

    // A page that resolved to a worktree that is gone is refused rather than silently remade.
    let (status, stale) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/one","reuseWorktree":"/nowhere"})).await;
    assert_eq!(status, StatusCode::CONFLICT, "{stale}");
    let (status, reused) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/one","reuseWorktree":one.to_str().unwrap()})).await;
    assert_eq!(status, StatusCode::OK, "{reused}");

    // The branch the main checkout holds: the checkout is parked on the base first, then the
    // branch gets a worktree of its own, never the main repository's path.
    let (status, held) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"main","base":"develop"})).await;
    assert_eq!(status, StatusCode::OK, "{held}");
    assert_eq!(git(&dir, &["rev-parse", "--abbrev-ref", "HEAD"]), "develop");
    assert_eq!(held["worktree"], root.join("app.worktrees/main").to_str().unwrap());

    // Nowhere to park it: the branch is the base this session forks from.
    let (status, refused) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"develop","base":"develop"})).await;
    assert_eq!(status, StatusCode::CONFLICT, "{refused}");
    assert!(refused["error"].as_str().unwrap().contains("cannot be moved off it"), "{refused}");

    // A bad address, or an unknown project, is refused before anything is touched.
    let (status, _) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/two","createBranch":true,"url":"file:///etc/passwd"})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(!root.join("app.worktrees/two").exists());
    let (status, _) = post(&app, "/api/sessions", json!({"projectId":"missing","branch":"feat/two"})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

/// A new branch with no base named is cut from the repository's default branch, even when that
/// branch is gone locally: `origin/main` is what the checkout knows, never the branch that happens
/// to have the newest commit. The most-recent fallback is for parking the main checkout alone.
#[tokio::test]
async fn a_fork_with_no_base_starts_from_the_default_branch_not_the_newest() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = repo(&root);
    let path = dir.to_str().unwrap();
    // A remote publishing main as its HEAD; then the local main is dropped after moving on.
    let origin = root.join("origin.git");
    git(&root, &["clone", "-q", "--bare", path, origin.to_str().unwrap()]);
    git(&dir, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&dir, &["fetch", "-q", "origin"]);
    git(&dir, &["remote", "set-head", "origin", "main"]);
    git(&dir, &["checkout", "-q", "-b", "feature/a"]);
    fs::write(dir.join("later.txt"), "later").unwrap();
    git(&dir, &["add", "later.txt"]);
    git(&dir, &["commit", "-qm", "later"]);
    git(&dir, &["branch", "-D", "main"]);
    let main = git(&dir, &["rev-parse", "origin/main"]);
    assert_ne!(git(&dir, &["rev-parse", "feature/a"]), main);
    let (status, project) = post(&app, "/api/projects", json!({"name":"App","repo":"example/app","workspace":path})).await;
    assert_eq!(status, StatusCode::OK, "{project}");
    let project_id = project["id"].as_str().unwrap();

    let (status, session) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/new","createBranch":true})).await;
    assert_eq!(status, StatusCode::OK, "{session}");
    assert_eq!(git(&dir, &["rev-parse", "feat/new"]), main, "forked from origin/main, not feature/a");
    assert_eq!(git(&dir, &["rev-parse", "--abbrev-ref", "HEAD"]), "feature/a", "nothing was parked");
}

/// A repository whose default branch git cannot name (no `origin/HEAD`, none of main, master or
/// develop) forks from its most recently committed branch, not from a name only guessed at.
#[tokio::test]
async fn a_fork_with_no_base_and_no_known_default_starts_from_the_newest_branch() {
    let (app, _data) = app();
    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().canonicalize().unwrap();
    let dir = root.join("app");
    fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q", "-b", "trunk"]);
    fs::write(dir.join("a.txt"), "a").unwrap();
    git(&dir, &["add", "a.txt"]);
    git(&dir, &["commit", "-qm", "init"]);
    let trunk = git(&dir, &["rev-parse", "trunk"]);
    let path = dir.to_str().unwrap();
    let (status, project) = post(&app, "/api/projects", json!({"name":"App","repo":"example/app","workspace":path})).await;
    assert_eq!(status, StatusCode::OK, "{project}");
    let project_id = project["id"].as_str().unwrap();

    let (status, session) = post(&app, "/api/sessions", json!({"projectId":project_id,"branch":"feat/new","createBranch":true})).await;
    assert_eq!(status, StatusCode::OK, "{session}");
    assert_eq!(git(&dir, &["rev-parse", "feat/new"]), trunk, "forked from trunk, the one branch there is");
}
