//! A command's whole outcome, exit status included, for callers that read a refusal rather than
//! fail on it.
//!
//! Port of the part of Synara's `apps/server/src/processRunner.ts` the device layer uses:
//! `runProcess` with `allowNonZeroExit`, which resolves with the status, the output and whether
//! it timed out, and rejects only when the program could not be started. It runs through
//! `cli::run_raw`, so every command is resolved, grouped and timed out as the backend's others
//! are, and a test scripts it with `cli::ScriptedRunner`.
//!
//! One difference: `cli` keeps a failed command's stderr (or a description of how it ended), not
//! its stdout, so a non-zero exit carries an empty `stdout`.

use std::time::Duration;

use crate::cli;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RunResult {
    /// None when a signal ended it, as a timeout does.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

impl RunResult {
    pub fn succeeded(&self) -> bool {
        self.code == Some(0)
    }
}

/// Runs `program`, answering with how it ended. `Err` only when it could not be started.
pub async fn run(program: &str, args: &[String], timeout: Duration, env: &[(String, String)]) -> Result<RunResult, String> {
    let env: Vec<(&str, &str)> = env.iter().map(|(key, value)| (key.as_str(), value.as_str())).collect();
    match cli::run_raw(program, args, timeout, None, &env).await {
        Ok(stdout) => Ok(RunResult {
            code: Some(0),
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::new(),
            timed_out: false,
        }),
        Err(error) => match cli::Failure::of(&error) {
            Some(cli::Failure::Exited(code)) => {
                Ok(RunResult { code, stdout: String::new(), stderr: error.to_string(), timed_out: false })
            }
            Some(cli::Failure::TimedOut) => {
                Ok(RunResult { code: None, stdout: String::new(), stderr: error.to_string(), timed_out: true })
            }
            Some(cli::Failure::Start) | None => Err(format!("{error:#}")),
        },
    }
}
