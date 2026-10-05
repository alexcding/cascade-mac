//! Ported from Synara `apps/server/src/orchestration/forkThreadTitle.ts`: stable, lineage-wide
//! sequence titles for forked threads. Sidechats are not ported, so no thread is one.

use std::collections::{HashMap, HashSet};

/// Synara `ForkLineageThread` (forkThreadTitle.ts:8)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForkLineageThread {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub fork_source_thread_id: Option<String>,
}

struct LineageRoot<'a> {
    thread: &'a ForkLineageThread,
    complete: bool,
}

/// Synara `findLineageRoot` (forkThreadTitle.ts:22)
fn find_lineage_root<'a>(
    source: &'a ForkLineageThread,
    threads_by_id: &HashMap<&str, &'a ForkLineageThread>,
) -> LineageRoot<'a> {
    let mut visited: HashSet<&str> = HashSet::from([source.id.as_str()]);
    let mut current = source;
    while let Some(parent_id) = current.fork_source_thread_id.as_deref().filter(|id| !id.is_empty()) {
        let parent = threads_by_id.get(parent_id).copied();
        match parent {
            Some(parent) if parent.project_id == source.project_id && !visited.contains(parent.id.as_str()) => {
                visited.insert(parent.id.as_str());
                current = parent;
            }
            _ => return LineageRoot { thread: current, complete: false },
        }
    }
    LineageRoot { thread: current, complete: true }
}

/// Synara `parseForkVersion` (forkThreadTitle.ts:40): `"<base> (<n>)"` with `n >= 2`.
fn parse_fork_version(title: &str) -> (String, u64) {
    let parsed = title.strip_suffix(')').and_then(|rest| {
        let open = rest.rfind(" (")?;
        let digits = &rest[open + 2..];
        if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        // Number.isSafeInteger: past 2^53 - 1 the version is not taken.
        let version: u64 = digits.parse().ok().filter(|v| *v <= 9_007_199_254_740_991)?;
        (version >= 2).then(|| (rest[..open].to_owned(), version))
    });
    parsed.unwrap_or_else(|| (title.to_owned(), 1))
}

/// Synara `buildForkThreadTitle` (forkThreadTitle.ts:56)
pub fn build_fork_thread_title(source: &ForkLineageThread, project_threads: &[ForkLineageThread]) -> String {
    let threads_by_id: HashMap<&str, &ForkLineageThread> =
        project_threads.iter().map(|thread| (thread.id.as_str(), thread)).collect();
    let source_root = find_lineage_root(source, &threads_by_id);
    let fallback_title = parse_fork_version(&source.title);
    let lineage_title =
        if source_root.complete { parse_fork_version(&source_root.thread.title) } else { fallback_title };
    let family: Vec<&ForkLineageThread> = project_threads
        .iter()
        .filter(|thread| {
            if thread.project_id != source.project_id {
                return false;
            }
            let root = find_lineage_root(thread, &threads_by_id);
            root.complete && source_root.complete && root.thread.id == source_root.thread.id
        })
        .collect();
    let latest_named_version = family.iter().fold(lineage_title.1, |latest, thread| {
        let (base, version) = parse_fork_version(&thread.title);
        if base == lineage_title.0 {
            latest.max(version)
        } else {
            latest
        }
    });
    let next_version = 2.max(family.len() as u64 + 1).max(latest_named_version + 1);
    format!("{} ({next_version})", lineage_title.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, title: &str, source: Option<&str>) -> ForkLineageThread {
        ForkLineageThread {
            id: id.into(),
            project_id: "p".into(),
            title: title.into(),
            fork_source_thread_id: source.map(str::to_owned),
        }
    }

    #[test]
    fn numbers_forks_across_the_lineage() {
        let root = thread("a", "Fix the build", None);
        assert_eq!(build_fork_thread_title(&root, std::slice::from_ref(&root)), "Fix the build (2)");
        let first = thread("b", "Fix the build (2)", Some("a"));
        let threads = vec![root.clone(), first.clone()];
        // Forking the root or the fork both continue the lineage's numbering.
        assert_eq!(build_fork_thread_title(&root, &threads), "Fix the build (3)");
        assert_eq!(build_fork_thread_title(&first, &threads), "Fix the build (3)");
    }

    #[test]
    fn a_broken_lineage_falls_back_to_the_source_title() {
        let orphan = thread("b", "Notes (4)", Some("gone"));
        assert_eq!(build_fork_thread_title(&orphan, std::slice::from_ref(&orphan)), "Notes (5)");
        assert_eq!(parse_fork_version("Plain (1)"), ("Plain (1)".into(), 1));
        assert_eq!(parse_fork_version("Plain (x)"), ("Plain (x)".into(), 1));
    }
}
