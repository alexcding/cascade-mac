//! The one seam an adapter starts its CLI through. Production spawns a real process in a
//! process group of its own (the backend runs inside the app, and a child in the app's group
//! can take the app down with it); a test hands the adapter a pair of pipes and plays the CLI's
//! side from a recorded fixture.

use std::{
    future::Future,
    io,
    path::PathBuf,
    pin::Pin,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

use tokio::{
    io::{AsyncRead, AsyncWrite, DuplexStream},
    sync::oneshot,
};

/// What to run.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SpawnSpec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub env_remove: Vec<String>,
}

pub type ExitFuture = Pin<Box<dyn Future<Output = Option<i32>> + Send>>;

/// A started CLI: its pipes, its end, and a way to end it.
pub struct ChildProcess {
    pub stdin: Pin<Box<dyn AsyncWrite + Send>>,
    pub stdout: Pin<Box<dyn AsyncRead + Send>>,
    pub stderr: Option<Pin<Box<dyn AsyncRead + Send>>>,
    /// Resolves with the exit code once the process has ended (`None` for a signal).
    pub exited: ExitFuture,
    /// Ends the process and everything it started. Safe to call more than once.
    pub terminate: Box<dyn FnMut() + Send>,
}

pub trait Spawner: Send + Sync {
    fn spawn(&self, spec: &SpawnSpec) -> io::Result<ChildProcess>;
}

/// Spawns real processes, each the leader of its own process group.
pub struct ProcessSpawner;

impl Spawner for ProcessSpawner {
    fn spawn(&self, spec: &SpawnSpec) -> io::Result<ChildProcess> {
        let mut command = tokio::process::Command::new(&spec.program);
        command
            .args(&spec.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .kill_on_drop(true);
        if let Some(cwd) = &spec.cwd {
            command.current_dir(cwd);
        }
        for key in &spec.env_remove {
            command.env_remove(key);
        }
        for (key, value) in &spec.env {
            command.env(key, value);
        }
        let mut child = command.spawn()?;
        // The group is ended once: when the session asks, when it drops its child unasked (a
        // dropped or panicked task; `kill_on_drop` reaches only the leader), or when the leader
        // exits on its own, which leaves its tool processes behind otherwise. After that the id
        // is not signalled again, since a group long gone may have had its id reused.
        let ended = Arc::new(AtomicBool::new(false));
        let mut guard = child.id().map(|pid| GroupGuard { pid: pid as libc::pid_t, ended: ended.clone() });
        let pid = child.id().map(|pid| pid as libc::pid_t);
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let stderr = child.stderr.take().expect("stderr is piped");
        let exited = Box::pin(async move {
            let status = child.wait().await;
            if let Some(pid) = pid {
                end_group_once(pid, &ended);
            }
            status.ok().and_then(|status| status.code())
        });
        Ok(ChildProcess {
            stdin: Box::pin(stdin),
            stdout: Box::pin(stdout),
            stderr: Some(Box::pin(stderr)),
            exited,
            terminate: Box::new(move || {
                if let Some(guard) = guard.as_mut() {
                    guard.terminate();
                }
            }),
        })
    }
}

/// How long a group asked to stop has before it is killed.
const TERMINATE_GRACE: Duration = Duration::from_secs(2);

/// Ends a child's process group when it is asked to, or when it is dropped unasked.
struct GroupGuard {
    pid: libc::pid_t,
    ended: Arc<AtomicBool>,
}

impl GroupGuard {
    fn terminate(&mut self) {
        end_group_once(self.pid, &self.ended);
    }
}

impl Drop for GroupGuard {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn end_group_once(pid: libc::pid_t, ended: &AtomicBool) {
    if !ended.swap(true, Ordering::SeqCst) {
        terminate_group(pid);
    }
}

/// Asks the group to stop, and kills what is still there a moment later.
fn terminate_group(pid: libc::pid_t) {
    // SAFETY: signalling the process group we created, at most once and no later than its
    // leader's exit; a group already gone only fails with ESRCH.
    unsafe { libc::killpg(pid, libc::SIGTERM) };
    schedule(PendingKill { pid, armed: true });
}

/// The SIGKILL that follows a SIGTERM. It is sent when it is dropped, so a runtime shutting down
/// before the grace period ends still sends it. A group id cannot be reused while any member is
/// alive, and the grace period is far shorter than the system takes to wrap ids.
struct PendingKill {
    pid: libc::pid_t,
    armed: bool,
}

impl Drop for PendingKill {
    fn drop(&mut self) {
        if !std::mem::take(&mut self.armed) {
            return;
        }
        // SAFETY: as in `terminate_group`; signal 0 only asks whether the group still exists.
        unsafe {
            if libc::killpg(self.pid, 0) == 0 {
                libc::killpg(self.pid, libc::SIGKILL);
            }
        }
    }
}

/// Sends `kill` after the grace period: on the runtime when there is one, else on one shared
/// thread, never a thread per child.
fn schedule(kill: PendingKill) {
    if let Ok(runtime) = tokio::runtime::Handle::try_current() {
        runtime.spawn(async move {
            tokio::time::sleep(TERMINATE_GRACE).await;
            drop(kill);
        });
        return;
    }
    static REAPER: OnceLock<Mutex<std::sync::mpsc::Sender<(Instant, PendingKill)>>> = OnceLock::new();
    let reaper = REAPER.get_or_init(|| {
        let (send, receive) = std::sync::mpsc::channel::<(Instant, PendingKill)>();
        let _ = std::thread::Builder::new().name("cascade-chat-reaper".into()).spawn(move || {
            let mut waiting: Vec<(Instant, PendingKill)> = Vec::new();
            loop {
                let now = Instant::now();
                waiting.retain(|(at, _)| *at > now); // dropping a due kill sends it
                let next = waiting.iter().map(|(at, _)| *at).min();
                let received = match next {
                    Some(at) => receive.recv_timeout(at.saturating_duration_since(now)),
                    None => receive.recv().map_err(|_| std::sync::mpsc::RecvTimeoutError::Disconnected),
                };
                match received {
                    Ok(entry) => waiting.push(entry),
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        });
        Mutex::new(send)
    });
    let deadline = Instant::now() + TERMINATE_GRACE;
    if let Err(std::sync::mpsc::SendError((_, kill))) = reaper.lock().unwrap().send((deadline, kill)) {
        drop(kill); // no reaper thread: kill now rather than never
    }
}

/// The CLI's side of a scripted child: read what the adapter wrote, write what the CLI says.
pub struct ScriptedChild {
    pub spec: SpawnSpec,
    /// What the adapter writes to the CLI's stdin.
    pub stdin: DuplexStream,
    /// Where the test writes the CLI's stdout.
    pub stdout: DuplexStream,
    /// Send an exit code to end the process.
    pub exit: oneshot::Sender<Option<i32>>,
}

/// Hands out pipes instead of processes; each spawn is delivered to the test.
#[derive(Clone, Default)]
pub struct ScriptedSpawner {
    children: Arc<Mutex<Vec<ScriptedChild>>>,
    notify: Arc<tokio::sync::Notify>,
}

impl ScriptedSpawner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Waits for the next spawn and returns the CLI's side of it.
    pub async fn next(&self) -> ScriptedChild {
        loop {
            let notified = self.notify.notified();
            if let Some(child) = {
                let mut children = self.children.lock().unwrap();
                (!children.is_empty()).then(|| children.remove(0))
            } {
                return child;
            }
            notified.await;
        }
    }
}

impl Spawner for ScriptedSpawner {
    fn spawn(&self, spec: &SpawnSpec) -> io::Result<ChildProcess> {
        let (adapter_stdin, cli_stdin) = tokio::io::duplex(1 << 20);
        let (cli_stdout, adapter_stdout) = tokio::io::duplex(1 << 20);
        let (exit, exited) = oneshot::channel();
        self.children.lock().unwrap().push(ScriptedChild {
            spec: spec.clone(),
            stdin: cli_stdin,
            stdout: cli_stdout,
            exit,
        });
        self.notify.notify_waiters();
        self.notify.notify_one();
        Ok(ChildProcess {
            stdin: Box::pin(adapter_stdin),
            stdout: Box::pin(adapter_stdout),
            stderr: None,
            exited: Box::pin(async move { exited.await.unwrap_or(None) }),
            terminate: Box::new(|| {}),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncBufReadExt;

    fn alive(pid: libc::pid_t) -> bool {
        // SAFETY: signal 0 only asks whether the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[tokio::test]
    async fn dropping_a_child_unterminated_ends_its_whole_group() {
        let spec = SpawnSpec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "sleep 30 & echo $!; wait".into()],
            ..SpawnSpec::default()
        };
        let child = ProcessSpawner.spawn(&spec).unwrap();
        let mut stdout = tokio::io::BufReader::new(child.stdout).lines();
        let grandchild: libc::pid_t = tokio::time::timeout(Duration::from_secs(5), stdout.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(alive(grandchild));

        // What a session task that drops or panics leaves behind: everything but `terminate` called.
        drop((child.stdin, child.stderr, child.exited, child.terminate, stdout));

        let deadline = Instant::now() + Duration::from_secs(5);
        while alive(grandchild) {
            assert!(Instant::now() < deadline, "the grandchild {grandchild} outlived its dropped group");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[tokio::test]
    async fn a_leader_that_exits_takes_its_stubborn_tools_with_it() {
        // A tool process that ignores SIGTERM, left behind by a CLI that exits on its own.
        let spec = SpawnSpec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "(trap '' TERM; sleep 30) & echo $!; exit 0".into()],
            ..SpawnSpec::default()
        };
        let child = ProcessSpawner.spawn(&spec).unwrap();
        let mut stdout = tokio::io::BufReader::new(child.stdout).lines();
        let tool: libc::pid_t = stdout.next_line().await.unwrap().unwrap().trim().parse().unwrap();
        assert_eq!(child.exited.await, Some(0));
        assert!(alive(tool), "SIGTERM alone should not end it");

        let deadline = Instant::now() + TERMINATE_GRACE + Duration::from_secs(3);
        while alive(tool) {
            assert!(Instant::now() < deadline, "the tool {tool} outlived its leader");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}
