//! The one seam checkpoints run `git` through. Production spawns the `git` on `PATH` in a process
//! group of its own (the engine runs inside the app); a test can hand the store a runner of its
//! own.

use std::{future::Future, io, path::Path, pin::Pin, process::Stdio, time::Duration};

/// What a git command printed, and how it ended.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitOutput {
    /// The exit code, `None` when a signal ended it.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl GitOutput {
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }
}

pub type GitFuture = Pin<Box<dyn Future<Output = io::Result<GitOutput>> + Send>>;

pub trait GitRunner: Send + Sync {
    /// Runs `git <args>` in `cwd` with `env` added to the environment.
    fn run(&self, cwd: &Path, args: &[String], env: &[(String, String)]) -> GitFuture;
}

/// How long one git command may take before it is ended.
const GIT_COMMAND_TIMEOUT: Duration = Duration::from_secs(60);

/// Runs the `git` on `PATH`.
pub struct ProcessGit;

impl GitRunner for ProcessGit {
    fn run(&self, cwd: &Path, args: &[String], env: &[(String, String)]) -> GitFuture {
        let mut command = tokio::process::Command::new("git");
        command
            .args(args)
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("GIT_TERMINAL_PROMPT", "0")
            .process_group(0)
            .kill_on_drop(true);
        for (key, value) in env {
            command.env(key, value);
        }
        Box::pin(async move {
            let output = tokio::time::timeout(GIT_COMMAND_TIMEOUT, command.output())
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "git did not finish in time"))??;
            Ok(GitOutput {
                code: output.status.code(),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            })
        })
    }
}
