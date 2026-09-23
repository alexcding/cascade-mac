use std::{
    ffi::OsStr,
    path::Path,
    process::{Output, Stdio},
    sync::OnceLock,
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use tokio::process::{Child, Command};

/// A command for an external CLI (`gh`, `acli`, `git`, agent CLIs). Finder and Xcode
/// launches hand the app a minimal PATH, and the backend runs inside the app, so the
/// child gets the usual install locations too. Set per command: mutating the process
/// environment would race with every other thread in the host app.
pub(crate) fn command(program: &str) -> Command {
    // Resolved here rather than by the spawn: see `resolve`.
    let mut command = Command::new(resolve(program, search_path()));
    // The child still gets the same PATH, for the programs IT starts (`npx` runs `node`).
    command.env("PATH", search_path());
    // The agent socket the user's terminal has. A Finder launch inherits Apple's ssh-agent,
    // while 1Password and friends export their own in the shell rc; without this a `git`
    // over SSH (a private Swift package, a fetch) reaches an agent with no keys and fails
    // instead of showing the approval prompt the user gets in a terminal.
    if let Some(socket) = shell_ssh_auth_sock() {
        command.env("SSH_AUTH_SOCK", socket);
    }
    // Its own process group, because the backend runs INSIDE the app: a child left in the
    // host's group shares its fate in both directions. Anything group-directed would reach
    // the app itself, and helpers the child spawns (`git` starts `git-remote-https`) would
    // outlive it holding its output pipe open, which is what `wait_or_kill` below now ends.
    command.process_group(0);
    command
}

/// The program as an absolute path: the file `path` resolves it to, or — when nothing matches —
/// where it would have been, which fails at the spawn with the same ENOENT as before.
///
/// It must never answer with a bare name. `fork()` inside a live AppKit process deadlocks: the
/// atfork handlers take the malloc and ObjC locks, and the host's main thread holds them often
/// enough that a launch-time `ghostty_init` -> `setlocale` -> malloc wedged the whole app
/// against a usage poll's `ccusage`. std only takes its fork-free `posix_spawn` path when the
/// program is a path: with PATH set on the Command and a bare name it must fall back to
/// fork+exec, because `posix_spawnp` would resolve against the PARENT's PATH. That applies just
/// as much to a program that is not installed — `ccusage` usually is not — so the miss gets a
/// path of its own rather than the name back.
///
/// Deliberately not cached: a CLI installed while the app runs must be found.
fn resolve(program: &str, path: &str) -> std::ffi::OsString {
    if program.contains('/') {
        return program.into();
    }
    let mut first: Option<std::path::PathBuf> = None;
    for directory in path.split(':').filter(|entry| !entry.is_empty()) {
        let directory = Path::new(directory);
        // `execvp` resolves a relative entry against the CHILD's cwd, which `run_in` may have
        // changed. Only the child knows that directory, so skip the entry rather than name a
        // file resolved against ours.
        if !directory.is_absolute() {
            continue;
        }
        let candidate = directory.join(program);
        if is_executable(&candidate) {
            return candidate.into_os_string();
        }
        first.get_or_insert(candidate);
    }
    first
        .unwrap_or_else(|| Path::new("/").join(program))
        .into_os_string()
}

/// Whether the spawn could execute this file. `access(X_OK)` rather than the mode bits, because
/// "somebody may execute it" is not "we may": a root-owned 0700 binary earlier on PATH would
/// otherwise shadow the copy that actually runs, which is not what `execvp` does — it tries the
/// exec, takes the EACCES and keeps searching.
fn is_executable(candidate: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(candidate.as_os_str().as_bytes()) else {
        return false;
    };
    if unsafe { libc::access(path.as_ptr(), libc::X_OK) } != 0 {
        return false;
    }
    // `access` answers X_OK for a directory too, and a directory is not a program.
    std::fs::metadata(candidate).is_ok_and(|data| data.is_file())
}

/// The group a child leads, or `None` if it does not lead one. Read once while the child is
/// still alive: `kill_on_drop` reaps it as soon as a timeout drops the wait, and `getpgid` on
/// a reaped pid answers -1 — which would look exactly like "not a group leader" and silently
/// skip the kill, leaving the helpers running. The check itself is the safety property:
/// `command` puts every child in its own group, but were that ever to stop, the child's group
/// would be the APP'S, and signalling it would take the host process down with it.
fn leader_group(child: &Child) -> Option<i32> {
    let pid = child.id()? as i32;
    (unsafe { libc::getpgid(pid) } == pid).then_some(pid)
}

/// Wait for `child`, or kill its whole process group when `duration` runs out. `output()`
/// alone is not recoverable: it waits for the output pipes to close, and a grandchild that
/// inherited them keeps it pending long after the child itself has exited.
async fn wait_or_kill(program: &str, child: Child, duration: Duration) -> Result<Output> {
    // Read before waiting: `getpgid` answers -1 once the leader is reaped, which would look
    // exactly like "not a group leader" and skip the kill, leaving the helpers running.
    let group = leader_group(&child);
    // The kill still reaches those helpers when the leader is already gone — a group lives as
    // long as any member does, and the wedged helper IS a member. What it cannot rule out is
    // the leader's pid being recycled between its reaping and this signal; that window is the
    // same one `tokio::time::timeout` had here, and it cannot touch the app, whose group is
    // never this pid.
    let wait = std::pin::pin!(child.wait_with_output());
    tokio::select! {
        // `timeout` polled the wait first; `select!` is otherwise random, and a tie would
        // report a command that actually finished as timed out.
        biased;
        result = wait => result.with_context(|| format!("wait for {program}")),
        _ = tokio::time::sleep(duration) => {
            if let Some(group) = group {
                unsafe { libc::killpg(group, libc::SIGKILL) };
            }
            Err(anyhow!("{program} timed out after {}s", duration.as_secs()))
        }
    }
}

/// `SSH_AUTH_SOCK` as the user's interactive login shell sets it, when that names a live socket
/// other than the one this process inherited. Filled by `prime_shell_environment`; until the
/// probe has answered, children keep the inherited socket rather than wait for it.
fn shell_ssh_auth_sock() -> Option<&'static str> {
    SHELL_SOCKET.get().and_then(Option::as_deref)
}

static SHELL_SOCKET: OnceLock<Option<String>> = OnceLock::new();
/// `PATH` as the user's interactive login shell sets it. However a tool was installed —
/// Homebrew, a vendor installer, `npm -g`, or a version manager (nvm, fnm, Volta, asdf,
/// mise) — the user's terminal finds it through this, so the backend searches it too.
static SHELL_PATH: OnceLock<Option<String>> = OnceLock::new();

/// Start the shell probe on its own thread. Called once at backend start: the probe sources
/// the user's rc files, which can take seconds, and nothing on the request path may block on
/// it. The result lands in `SHELL_SOCKET` whether the probe answered or gave up.
pub fn prime_shell_environment() {
    // Gate on "started", not on the result: a stop/start cycle inside the probe's deadline
    // must not run a second login shell. Tests never source the developer's rc files.
    static STARTED: std::sync::Once = std::sync::Once::new();
    if cfg!(test) || std::env::var_os("CRAFT_NO_SHELL_PROBE").is_some() {
        return;
    }
    STARTED.call_once(|| {
        let inherited = std::env::var("SSH_AUTH_SOCK").ok();
        let shell = std::env::var("SHELL").ok();
        std::thread::Builder::new()
            .name("craft-shell-probe".into())
            .spawn(move || {
                let output = shell
                    .filter(|shell| shell.starts_with('/'))
                    .and_then(|shell| {
                        run_briefly(&shell, &["-ilc", SOCKET_PROBE], Duration::from_secs(5))
                    })
                    .map(|output| String::from_utf8_lossy(&output).into_owned());
                let _ = SHELL_PATH.set(output.as_deref().and_then(path_from_probe));
                let socket = output.and_then(|output| {
                    choose_socket(&output, inherited.as_deref(), |path| {
                        is_socket(Path::new(path))
                    })
                });
                let _ = SHELL_SOCKET.set(socket);
            })
            .ok();
    });
}

/// Markers, because an rc file may print anything before the value. The socket comes last:
/// its closing marker is what ends the read.
const SOCKET_PROBE: &str =
    "printf '\\n<craft-path>%s</craft-path>\\n<craft-ssh>%s</craft-ssh>\\n' \"$PATH\" \"$SSH_AUTH_SOCK\"";
const PROBE_END: &str = "</craft-ssh>";

/// The shell's PATH, keeping only absolute entries: a relative one would resolve against
/// whatever directory a command runs in.
fn path_from_probe(output: &str) -> Option<String> {
    let start = output.rfind("<craft-path>")? + "<craft-path>".len();
    let end = output[start..].find("</craft-path>")? + start;
    let entries: Vec<&str> = output[start..end]
        .trim()
        .split(':')
        .filter(|entry| entry.starts_with('/'))
        .collect();
    (!entries.is_empty()).then(|| entries.join(":"))
}

/// The socket to export, or nothing when the shell agrees with the inherited value or names a
/// path that is not a live socket.
fn choose_socket(
    output: &str,
    inherited: Option<&str>,
    live: impl Fn(&str) -> bool,
) -> Option<String> {
    let socket = socket_from_probe(output)?;
    if inherited == Some(socket.as_str()) {
        return None;
    }
    live(&socket).then_some(socket)
}

fn socket_from_probe(output: &str) -> Option<String> {
    let start = output.rfind("<craft-ssh>")? + "<craft-ssh>".len();
    let end = output[start..].find(PROBE_END)? + start;
    let value = output[start..end].trim();
    value.starts_with('/').then(|| value.to_owned())
}

fn is_socket(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::metadata(path).is_ok_and(|data| data.file_type().is_socket())
}

/// A short synchronous run with no stdin, bounded on both the process and its output. The read
/// stops at the closing marker or the deadline, not at end of file: a grandchild the rc file
/// backgrounded (an agent, a version manager's daemon) inherits the pipe and would hold it
/// open indefinitely. Whatever is left of the group is then killed, as `wait_or_kill` does.
/// `program` is absolute, so std takes `posix_spawn`.
fn run_briefly(program: &str, args: &[&str], deadline: Duration) -> Option<Vec<u8>> {
    use std::{io::Read, os::unix::io::AsRawFd, os::unix::process::CommandExt};
    let mut child = std::process::Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let pid = child.id() as i32;
    let mut stdout = child.stdout.take()?;
    let fd = stdout.as_raw_fd();
    // Non-blocking is what makes the deadline real; without it the read below would wait for
    // end of file, so a failure here ends the probe rather than proceed unbounded.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        drop(stdout);
        end_group(&mut child, pid);
        return None;
    }
    let started = std::time::Instant::now();
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let complete = loop {
        let remaining = deadline.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            break false;
        }
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe {
            libc::poll(
                &mut poll,
                1,
                remaining.as_millis().min(i32::MAX as u128) as i32,
            )
        };
        if ready < 0 {
            // A signal — tokio's SIGCHLD handler, for one — interrupts `poll`, and Darwin does
            // not restart it. That is a wait cut short, not a failed probe.
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break false;
        }
        match stdout.read(&mut chunk) {
            Ok(0) => break true,
            Ok(count) => {
                buffer.extend_from_slice(&chunk[..count]);
                // The marker can only straddle the last chunk boundary, so scan that tail alone.
                let tail = buffer.len().saturating_sub(count + PROBE_END.len() - 1);
                if buffer[tail..]
                    .windows(PROBE_END.len())
                    .any(|window| window == PROBE_END.as_bytes())
                {
                    break true;
                }
                if buffer.len() > PROBE_OUTPUT_CAP {
                    break false;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break false,
        }
    };
    drop(stdout);
    end_group(&mut child, pid);
    complete.then_some(buffer)
}

/// More than any rc file has reason to print before one `printf`.
const PROBE_OUTPUT_CAP: usize = 1 << 20;

/// The shell normally exits on its own right after the printf; give it that moment, then take
/// the whole group so a wedged rc leaves no helpers behind. Skip the signal when the leader is
/// already reaped: its pid could have been reused by then.
fn end_group(child: &mut std::process::Child, pid: i32) {
    let exited = (0..10).any(|_| {
        matches!(child.try_wait(), Ok(Some(_))) || {
            std::thread::sleep(Duration::from_millis(10));
            false
        }
    });
    if !exited {
        if unsafe { libc::getpgid(pid) } == pid {
            unsafe { libc::killpg(pid, libc::SIGKILL) };
        }
        let _ = child.wait();
    }
}

/// The login shell's PATH ahead of the inherited one once the probe has answered, then the
/// usual install locations, then version managers' directories for a shell that set none.
/// Until the probe answers — or when it cannot — the fallbacks alone.
fn build_search_path(shell: Option<&str>) -> String {
    let inherited = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    let path = match shell {
        Some(shell) => format!("{shell}:{inherited}"),
        None => inherited,
    };
    let home = std::env::var("HOME").ok();
    let path = with_install_locations(&path, home.as_deref());
    with_version_managers(&path, home.as_deref(), &|dir| {
        std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// The search path as last built, and whether the shell probe had answered by then. Each value
/// is leaked once so that callers can hold a `&'static str`: at start, when the probe answers,
/// and whenever `refresh_search_path` finds that an install changed it.
static SEARCH_PATH: std::sync::RwLock<Option<(bool, &'static str)>> = std::sync::RwLock::new(None);

fn probed_shell_path() -> Option<&'static str> {
    SHELL_PATH.get().and_then(|shell| shell.as_deref())
}

fn search_path() -> &'static str {
    let shell = probed_shell_path();
    if let Some((probed, path)) = *SEARCH_PATH.read().unwrap() {
        if probed == shell.is_some() {
            return path;
        }
    }
    let path: &'static str = Box::leak(build_search_path(shell).into_boxed_str());
    *SEARCH_PATH.write().unwrap() = Some((shell.is_some(), path));
    path
}

/// Builds the search path again, for a tool installed since it was built into a directory that
/// only a version manager knows: nvm and a keg-only Homebrew Node add one per version. True
/// when that changed it. The login shell is not asked again; its PATH is read once at start.
pub(crate) fn refresh_search_path() -> bool {
    let shell = probed_shell_path();
    let fresh = build_search_path(shell);
    let mut current = SEARCH_PATH.write().unwrap();
    if current.is_some_and(|(probed, path)| probed == shell.is_some() && path == fresh) {
        return false;
    }
    *current = Some((shell.is_some(), Box::leak(fresh.into_boxed_str())));
    true
}

/// Where version managers keep the tools they install, for a login shell that never set them
/// up on PATH (or did not answer in time). Each is appended only when missing, behind
/// everything else. nvm and a keg-only Homebrew Node have one directory per version: the
/// newest installed one is used, which is what `nvm install node` would leave as default.
fn with_version_managers(
    path: &str,
    home: Option<&str>,
    list: &dyn Fn(&str) -> Vec<String>,
) -> String {
    let mut entries: Vec<String> = path.split(':').map(String::from).collect();
    let mut extras = Vec::new();
    if let Some(home) = home.filter(|home| !home.is_empty()) {
        let home = home.trim_end_matches('/');
        extras.extend(
            [
                ".volta/bin",
                ".asdf/shims",
                ".local/share/mise/shims",
                ".nodenv/shims",
                "Library/Application Support/fnm/aliases/default/bin",
                ".fnm/aliases/default/bin",
            ]
            .iter()
            .map(|dir| format!("{home}/{dir}")),
        );
        let nvm = format!("{home}/.nvm/versions/node");
        if let Some(version) = newest_version(list(&nvm), "v") {
            extras.push(format!("{nvm}/{version}/bin"));
        }
    }
    for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
        if let Some(keg) = newest_version(list(prefix), "node@") {
            extras.push(format!("{prefix}/{keg}/bin"));
        }
    }
    for extra in extras {
        if !entries.iter().any(|entry| entry.trim_end_matches('/') == extra) {
            entries.push(extra);
        }
    }
    entries.join(":")
}

/// The name in `names` with the highest numeric version after `prefix`: `v22.1.0` over
/// `v9.0.0`, `node@22` over `node@20`.
fn newest_version(names: Vec<String>, prefix: &str) -> Option<String> {
    names
        .into_iter()
        .filter_map(|name| {
            let version: Vec<u32> = name
                .strip_prefix(prefix)?
                .split('.')
                .map(|part| part.parse().ok())
                .collect::<Option<_>>()?;
            Some((version, name))
        })
        .max()
        .map(|(_, name)| name)
}

/// The executable `program` resolves to on the search path, if there is one.
pub(crate) fn locate(program: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::path::PathBuf::from(resolve(program, search_path()));
    std::fs::metadata(&path)
        .is_ok_and(|data| data.is_file() && data.permissions().mode() & 0o111 != 0)
        .then_some(path)
}

pub(crate) fn installed(program: &str) -> bool {
    locate(program).is_some()
}

/// Homebrew, plus the per-user directories the agent CLIs install into: the Claude Code
/// and Codex native installers both drop their launcher in `~/.local/bin`, which a Finder
/// or Xcode launch never has on PATH, so without this the CLIs read as "not found".
fn with_install_locations(path: &str, home: Option<&str>) -> String {
    // A trailing slash names the same directory, and a shell rc exports either spelling,
    // so the inherited entries are matched on the trimmed form rather than verbatim.
    let key = |entry: &str| match entry.trim_end_matches('/') {
        "" => "/".to_string(),
        trimmed => trimmed.to_string(),
    };
    let mut entries: Vec<String> = path
        .split(':')
        .filter(|entry| !entry.is_empty())
        .map(String::from)
        .collect();
    let mut seen: Vec<String> = entries.iter().map(|entry| key(entry)).collect();
    // Per-user directories first, as a login shell has them: the native installers prepend
    // `~/.local/bin` in the shell rc, so the copy the user's terminal runs must win here too.
    // Behind Homebrew, a stale `npm -g` launcher there shadowed a working native install and
    // the CLI read as "not found".
    let mut extras = Vec::new();
    if let Some(home) = home.filter(|home| !home.is_empty()) {
        let home = home.trim_end_matches('/');
        extras.extend(
            [".local/bin", ".bun/bin", ".cargo/bin"]
                .iter()
                .map(|dir| format!("{home}/{dir}")),
        );
    }
    extras.extend(["/opt/homebrew/bin".to_string(), "/usr/local/bin".to_string()]);
    for extra in extras {
        let extra_key = key(&extra);
        if !seen.contains(&extra_key) {
            seen.push(extra_key);
            entries.push(extra);
        }
    }
    entries.join(":")
}

pub async fn run<I, S>(program: &str, args: I, duration: Duration) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    run_in(program, args, duration, None).await
}

pub async fn run_in<I, S>(
    program: &str,
    args: I,
    duration: Duration,
    cwd: Option<&Path>,
) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = command(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let child = command
        .spawn()
        .with_context(|| format!("start {program}"))?;
    let output = wait_or_kill(program, child, duration).await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(anyhow!(if stderr.is_empty() {
            format!("{program} exited {}", output.status)
        } else {
            stderr
        }));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

pub async fn run_with_input<I, S>(
    program: &str,
    args: I,
    input: &[u8],
    duration: Duration,
    cwd: Option<&Path>,
) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    use tokio::io::AsyncWriteExt;
    let mut command = command(program);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let mut child = command
        .spawn()
        .with_context(|| format!("start {program}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(input).await?;
    }
    let output = wait_or_kill(program, child, duration).await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(anyhow!(if stderr.is_empty() {
            format!("{program} exited {}", output.status)
        } else {
            stderr
        }));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_probe_reads_the_marked_value_past_rc_noise() {
        assert_eq!(
            socket_from_probe("Last login: today\nmotd\n<craft-ssh>/tmp/agent.sock</craft-ssh>\n"),
            Some("/tmp/agent.sock".to_owned())
        );
        assert_eq!(socket_from_probe("<craft-ssh></craft-ssh>\n"), None);
        assert_eq!(
            socket_from_probe("<craft-ssh>relative.sock</craft-ssh>"),
            None
        );
        assert_eq!(socket_from_probe("no marker at all"), None);
    }

    #[test]
    fn shell_socket_is_exported_only_when_it_is_new_and_live() {
        let probe = "<craft-ssh>/tmp/agent.sock</craft-ssh>";
        assert_eq!(
            choose_socket(probe, None, |_| true),
            Some("/tmp/agent.sock".to_owned())
        );
        assert_eq!(
            choose_socket(probe, Some("/tmp/agent.sock"), |_| true),
            None
        );
        assert_eq!(
            choose_socket(probe, Some("/var/run/other"), |_| false),
            None
        );
        assert_eq!(choose_socket("garbage", None, |_| true), None);
    }

    #[test]
    fn brief_run_returns_at_the_marker_while_a_grandchild_holds_the_pipe() {
        // `sleep` inherits stdout and outlives the shell: a read to end of file would wait 30s.
        let started = std::time::Instant::now();
        let output = run_briefly(
            "/bin/sh",
            &[
                "-c",
                "(sleep 30 &); printf '<craft-ssh>/x</craft-ssh>\\n'; sleep 30",
            ],
            Duration::from_secs(5),
        )
        .expect("marker read");
        assert!(String::from_utf8_lossy(&output).contains("</craft-ssh>"));
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn brief_run_finds_a_marker_split_across_chunks_and_caps_runaway_output() {
        // 5000 bytes of noise pushes the marker past the first 4096-byte chunk.
        let output = run_briefly(
            "/bin/sh",
            &[
                "-c",
                "head -c 5000 /dev/zero | tr '\\0' x; printf '<craft-ssh>/y</craft-ssh>\\n'",
            ],
            Duration::from_secs(5),
        )
        .expect("marker read");
        assert_eq!(
            socket_from_probe(&String::from_utf8_lossy(&output)),
            Some("/y".to_owned())
        );
        let started = std::time::Instant::now();
        assert!(run_briefly(
            "/bin/sh",
            &["-c", "yes | head -c 3000000"],
            Duration::from_secs(5)
        )
        .is_none());
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn brief_run_gives_up_at_the_deadline_and_kills_the_group() {
        let started = std::time::Instant::now();
        assert!(run_briefly("/bin/sh", &["-c", "sleep 30"], Duration::from_millis(300)).is_none());
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn install_locations_are_appended_once_after_the_inherited_path() {
        assert_eq!(
            with_install_locations("/usr/bin:/bin", None),
            "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        );
        assert_eq!(
            with_install_locations("/opt/homebrew/bin::/usr/bin", None),
            "/opt/homebrew/bin:/usr/bin:/usr/local/bin"
        );
    }

    // The agent CLIs' native installers put their launcher here, so a Finder launch finds them.
    #[test]
    fn per_user_install_directories_come_from_home() {
        assert_eq!(
            with_install_locations("/usr/bin", Some("/Users/me/")),
            "/usr/bin:/Users/me/.local/bin:/Users/me/.bun/bin:/Users/me/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
        );
        assert_eq!(
            with_install_locations("/Users/me/.local/bin:/usr/bin", Some("/Users/me")),
            "/Users/me/.local/bin:/usr/bin:/Users/me/.bun/bin:/Users/me/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
        );
        // Same directory, other spelling: appending it again would only cost a second lookup.
        assert_eq!(
            with_install_locations("/Users/me/.local/bin/:/usr/bin", Some("/Users/me")),
            "/Users/me/.local/bin/:/usr/bin:/Users/me/.bun/bin:/Users/me/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
        );
    }

    #[test]
    fn the_login_shell_path_is_read_past_rc_noise_and_keeps_absolute_entries() {
        let output = "motd\n<craft-path>/Users/me/.nvm/versions/node/v22.1.0/bin:bin:/usr/bin</craft-path>\n<craft-ssh></craft-ssh>\n";
        assert_eq!(
            path_from_probe(output).as_deref(),
            Some("/Users/me/.nvm/versions/node/v22.1.0/bin:/usr/bin")
        );
        assert_eq!(path_from_probe("<craft-path></craft-path>"), None);
        assert_eq!(path_from_probe("no marker"), None);
        // The socket still reads from the same output.
        assert_eq!(
            socket_from_probe("<craft-path>/usr/bin</craft-path>\n<craft-ssh>/tmp/a.sock</craft-ssh>\n").as_deref(),
            Some("/tmp/a.sock")
        );
    }

    #[test]
    fn version_managers_are_appended_after_everything_else() {
        let list = |dir: &str| -> Vec<String> {
            match dir {
                "/Users/me/.nvm/versions/node" => vec!["v9.11.2".into(), "v22.1.0".into(), "v20.18.0".into(), "junk".into()],
                "/opt/homebrew/opt" => vec!["node@20".into(), "node@22".into(), "openssl@3".into()],
                _ => vec![],
            }
        };
        let path = with_version_managers("/Users/me/.volta/bin:/usr/bin", Some("/Users/me"), &list);
        let entries: Vec<&str> = path.split(':').collect();
        assert_eq!(&entries[..2], ["/Users/me/.volta/bin", "/usr/bin"], "the shell's order wins");
        assert_eq!(entries.iter().filter(|e| **e == "/Users/me/.volta/bin").count(), 1);
        assert!(entries.contains(&"/Users/me/.asdf/shims"));
        assert!(entries.contains(&"/Users/me/.local/share/mise/shims"));
        assert!(entries.contains(&"/Users/me/.nvm/versions/node/v22.1.0/bin"), "{path}");
        assert!(entries.contains(&"/opt/homebrew/opt/node@22/bin"), "{path}");
        assert!(!path.contains("v9.11.2") && !path.contains("node@20"));
        // No home: only the Homebrew kegs.
        assert_eq!(with_version_managers("/usr/bin", None, &|_| vec![]), "/usr/bin");
    }

    /// A rebuild that finds nothing new keeps the very path callers already hold.
    #[test]
    fn rebuilding_an_unchanged_search_path_keeps_it() {
        let _ = refresh_search_path();
        let held = search_path();
        assert!(!refresh_search_path(), "nothing was installed, so nothing changed");
        assert!(std::ptr::eq(search_path(), held));
    }

    // A program is resolved to its file before the spawn, so std never reaches for fork().
    #[tokio::test]
    async fn a_command_resolves_programs_against_the_search_path() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let tool = dir.path().join("craft-path-probe");
        std::fs::write(&tool, "#!/bin/sh\necho found\n").unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:/usr/bin:/bin", dir.path().display());

        assert_eq!(resolve("craft-path-probe", &path), tool.as_os_str());
        // A path of its own is already spawnable, and may be relative to the CHILD's cwd.
        assert_eq!(resolve("./craft-path-probe", &path), "./craft-path-probe");
        // A directory on PATH is not a program, so it is no match. The answer is still a path,
        // never the bare name — a bare name is what makes std fork — and the spawn fails on it.
        std::fs::create_dir(dir.path().join("craft-path-dir")).unwrap();
        let miss = resolve("craft-path-dir", &path);
        assert_ne!(miss, "craft-path-dir");
        assert!(Path::new(&miss).is_absolute(), "{miss:?}");
        // Nothing on PATH matches at all: still a path, and still where it would have been.
        let missing = resolve("craft-path-probe", "/usr/bin:/bin");
        assert_eq!(missing, "/usr/bin/craft-path-probe");
        // A file nobody may execute is not a match, and does not shadow the one further along.
        let blocked = tempfile::tempdir().unwrap();
        let shadow = blocked.path().join("craft-path-probe");
        std::fs::write(&shadow, "#!/bin/sh\necho shadow\n").unwrap();
        std::fs::set_permissions(&shadow, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            resolve(
                "craft-path-probe",
                &format!("{}:{}", blocked.path().display(), dir.path().display())
            ),
            tool.as_os_str()
        );

        // The property that keeps the app off fork(): what `command` spawns is always a path.
        for program in ["sh", "craft-definitely-not-installed"] {
            let built = command(program);
            let spawned = Path::new(built.as_std().get_program());
            assert!(spawned.is_absolute(), "{program} spawned as {spawned:?}");
        }

        // And the resolved command still runs.
        let output = Command::new(resolve("craft-path-probe", &path))
            .output()
            .await
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "found");
    }

    // A timed-out command must take its helpers with it. `git fetch` froze New Session for a
    // minute this way: git died, its `git-remote-https` child kept the output pipe open, and
    // the wait stayed pending. The marker file is the grandchild's proof of life.
    #[tokio::test]
    async fn a_timeout_kills_the_helpers_the_child_started() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("grandchild-survived");
        let script = format!(
            "(sleep 1; touch {}) & sleep 30",
            marker.display()
        );
        let started = std::time::Instant::now();
        let error = run("sh", ["-c", script.as_str()], Duration::from_millis(200))
            .await
            .expect_err("the command outlived its timeout");
        assert!(error.to_string().contains("timed out"), "{error}");
        // Returns on the timeout rather than waiting for the pipe the grandchild holds.
        assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert!(
            !marker.exists(),
            "the grandchild outlived the timeout and kept running"
        );
    }
}
