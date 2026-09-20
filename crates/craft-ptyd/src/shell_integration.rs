//! Load only the pinned package's integration assets, never edit user dotfiles.
use portable_pty::CommandBuilder;
use std::{io::Read, path::Path};

const FILES: &[&str] = &[
    "shell-integration/zsh/.zshenv",
    "shell-integration/zsh/ghostty-integration",
    "shell-integration/bash/ghostty.bash",
    "shell-integration/bash/bash-preexec.sh",
    "shell-integration/bash/LICENSE-bash-preexec.md",
];

pub fn copy_resources(source: &Path, destination: &Path) -> Result<(), String> {
    if !source.is_absolute() {
        return Err("native shell resources must be absolute".into());
    }
    let mut remaining = 1024 * 1024;
    for relative in FILES {
        let mut bytes = Vec::new();
        std::fs::File::open(source.join(relative))
            .map_err(|e| format!("missing shell resource {relative}: {e}"))?
            .take(remaining + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.is_empty() || bytes.len() as u64 > remaining {
            return Err("native shell resources exceed their size limit or are empty".into());
        }
        remaining -= bytes.len() as u64;
        let target = destination.join(relative);
        std::fs::create_dir_all(target.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(target, bytes).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn configure(cmd: &mut CommandBuilder, shell: &Path, resources: &Path) {
    cmd.env("GHOSTTY_RESOURCES_DIR", resources);
    // The pinned MIT integration supports these features. Do not advertise
    // helpers (SSH/sudo/path) that this package does not implement.
    cmd.env("GHOSTTY_SHELL_FEATURES", "cursor,title");
    // A relative executable could resolve to Apple's patched Bash through
    // PATH. Auto-inject only an explicitly identified absolute executable.
    if !shell.is_absolute() {
        return;
    }
    match shell.file_name().and_then(|name| name.to_str()) {
        Some("zsh") => {
            if let Some(old) = cmd.get_env("ZDOTDIR").map(|value| value.to_owned()) {
                cmd.env("GHOSTTY_ZSH_ZDOTDIR", old);
            } else {
                cmd.env_remove("GHOSTTY_ZSH_ZDOTDIR");
            }
            cmd.env("ZDOTDIR", resources.join("shell-integration/zsh"));
        }
        Some("bash") => {
            // Match Ghostty's restriction: Apple's Bash disables ENV-based
            // POSIX injection. Preserve its normal login/startup semantics.
            if shell == Path::new("/bin/bash")
                || std::fs::canonicalize(shell).ok().as_deref() == Some(Path::new("/bin/bash"))
            {
                return;
            }
            cmd.arg("--posix");
            if let Some(old) = cmd.get_env("ENV").map(|value| value.to_owned()) {
                cmd.env("GHOSTTY_BASH_ENV", old);
            } else {
                cmd.env_remove("GHOSTTY_BASH_ENV");
            }
            cmd.env("ENV", resources.join("shell-integration/bash/ghostty.bash"));
            cmd.env("GHOSTTY_BASH_INJECT", "1");
            cmd.env_remove("GHOSTTY_BASH_RCFILE");
            cmd.env_remove("GHOSTTY_BASH_UNEXPORT_HISTFILE");
            if cmd.get_env("HISTFILE").is_none() {
                if let Some(home) = cmd.get_env("HOME").map(|value| value.to_owned()) {
                    cmd.env("HISTFILE", Path::new(&home).join(".bash_history"));
                    cmd.env("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn copied_resources_survive_source_removal_and_reject_missing_or_oversized_files() {
        let root =
            std::env::temp_dir().join(format!("craft-shell-resources-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let source = root.join("source");
        let target = root.join("target");
        assert!(copy_resources(&source, &target).is_err());
        for name in FILES {
            let path = source.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, name.as_bytes()).unwrap();
        }
        copy_resources(&source, &target).unwrap();
        std::fs::remove_dir_all(&source).unwrap();
        for name in FILES {
            assert_eq!(std::fs::read(target.join(name)).unwrap(), name.as_bytes());
        }
        std::fs::create_dir_all(source.join("shell-integration/zsh")).unwrap();
        std::fs::write(source.join(FILES[0]), vec![b'x'; 1024 * 1024 + 1]).unwrap();
        assert!(copy_resources(&source, &root.join("oversized")).is_err());
        assert!(!root.join("oversized").join(FILES[0]).exists());
        assert!(copy_resources(Path::new("relative"), &target).is_err());
    }

    #[test]
    fn startup_configuration_preserves_user_settings_and_skips_apple_bash() {
        let resources = Path::new("/tmp/native resources");
        let mut zsh = CommandBuilder::new("/bin/zsh");
        zsh.env_clear();
        zsh.env("ZDOTDIR", "/tmp/user dotfiles");
        configure(&mut zsh, Path::new("/bin/zsh"), resources);
        zsh.args(["-l", "-i"]);
        assert_eq!(
            zsh.get_env("GHOSTTY_ZSH_ZDOTDIR"),
            Some(std::ffi::OsStr::new("/tmp/user dotfiles"))
        );
        assert_eq!(
            zsh.get_env("ZDOTDIR"),
            Some(resources.join("shell-integration/zsh").as_os_str())
        );
        assert_eq!(zsh.get_argv().len(), 3);
        let mut bash = CommandBuilder::new("/opt/homebrew/bin/bash");
        bash.env_clear();
        bash.env("ENV", "/tmp/user.env");
        bash.env("HISTFILE", "/tmp/user.history");
        bash.env("GHOSTTY_BASH_UNEXPORT_HISTFILE", "stale");
        configure(&mut bash, Path::new("/opt/homebrew/bin/bash"), resources);
        bash.args(["-l", "-i"]);
        assert_eq!(bash.get_argv()[1], "--posix");
        assert_eq!(
            bash.get_env("GHOSTTY_BASH_ENV"),
            Some(std::ffi::OsStr::new("/tmp/user.env"))
        );
        assert_eq!(
            bash.get_env("HISTFILE"),
            Some(std::ffi::OsStr::new("/tmp/user.history"))
        );
        assert!(bash.get_env("GHOSTTY_BASH_UNEXPORT_HISTFILE").is_none());
        for path in ["/bin/bash", "/bin/sh", "bash"] {
            let mut command = CommandBuilder::new(path);
            command.env_clear();
            command.env("ENV", "/tmp/user.env");
            configure(&mut command, Path::new(path), resources);
            assert_eq!(command.get_argv().len(), 1);
            assert_eq!(
                command.get_env("ENV"),
                Some(std::ffi::OsStr::new("/tmp/user.env"))
            );
            assert!(command.get_env("GHOSTTY_BASH_INJECT").is_none());
        }
    }
}
