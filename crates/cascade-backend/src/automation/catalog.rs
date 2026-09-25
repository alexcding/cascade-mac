//! Every node the editor can place. The app draws its pickers and param forms from this list,
//! so a new node is added here and in `filters.rs`/`actions.rs`, never in Swift.

use std::sync::LazyLock;

use serde_json::{json, Value};

fn param(key: &str, label: &str, kind: &str) -> Value {
    json!({"key":key,"label":label,"kind":kind})
}

fn with(mut value: Value, extra: Value) -> Value {
    if let (Some(object), Some(extra)) = (value.as_object_mut(), extra.as_object()) {
        for (key, v) in extra {
            object.insert(key.clone(), v.clone());
        }
    }
    value
}

fn options(pairs: &[(&str, &str)]) -> Value {
    json!(pairs
        .iter()
        .map(|(value, label)| json!({"value":value,"label":label}))
        .collect::<Vec<_>>())
}

fn node(kind: &str, node: &str, group: &str, label: &str, summary: &str, subject: &str, params: Vec<Value>) -> Value {
    json!({"kind":kind,"type":node,"group":group,"label":label,"summary":summary,"subject":subject,"params":params})
}

const MERGE_METHODS: &[(&str, &str)] = &[("squash", "Squash"), ("merge", "Merge commit"), ("rebase", "Rebase")];

static CATALOG: LazyLock<Value> = LazyLock::new(|| {
    let jql = with(
        param("jql", "JQL", "jql"),
        json!({"placeholder":"project = CASCADE AND assignee = currentUser()"}),
    );
    let triggers = vec![
        node("trigger", "pr.opened", "Pull requests", "PR opened", "A new pull request appears.", "pr", vec![]),
        node("trigger", "pr.ready_for_review", "Pull requests", "PR ready for review", "A draft PR is marked ready.", "pr", vec![]),
        node("trigger", "pr.updated", "Pull requests", "New commits pushed", "The PR's head commit changes.", "pr", vec![]),
        node("trigger", "pr.ci_passed", "Pull requests", "CI passed", "Checks on the head commit turn green.", "pr", vec![]),
        node("trigger", "pr.ci_failed", "Pull requests", "CI failed", "Checks on the head commit turn red.", "pr", vec![]),
        node("trigger", "pr.review_requested", "Pull requests", "My review requested", "You are asked to review a PR.", "pr", vec![]),
        node("trigger", "pr.approved", "Pull requests", "PR approved", "The review decision becomes approved.", "pr", vec![]),
        node("trigger", "pr.changes_requested", "Pull requests", "Changes requested", "A reviewer requests changes.", "pr", vec![]),
        node("trigger", "pr.conflicted", "Pull requests", "Merge conflict", "The PR can no longer merge cleanly.", "pr", vec![]),
        node("trigger", "pr.merged", "Pull requests", "PR merged", "A pull request is merged.", "pr", vec![]),
        node("trigger", "pr.closed", "Pull requests", "PR closed", "A pull request is closed without merging.", "pr", vec![]),
        node(
            "trigger",
            "pr.stale",
            "Pull requests",
            "PR stale",
            "An open PR has had no update for a number of days.",
            "pr",
            vec![with(param("days", "Days without update", "number"), json!({"default":7}))],
        ),
        node("trigger", "jira.entered", "Jira", "Ticket matches JQL", "A ticket newly matches the JQL.", "jira", vec![jql.clone()]),
        node("trigger", "jira.status_changed", "Jira", "Ticket status changed", "A ticket in the JQL changes status.", "jira", vec![jql]),
        node("trigger", "manual", "Manual", "Run manually", "Only runs from the Run button, against a chosen PR.", "pr", vec![]),
    ];
    let users = with(
        param("users", "Users", "list"),
        json!({"placeholder":"alice, dependabot, @me, @bots"}),
    );
    let filters = vec![
        node(
            "filter",
            "pr.author",
            "Pull request",
            "Author",
            "Who opened the PR. @me is you, @bots is any bot account.",
            "pr",
            vec![
                with(param("mode", "Match", "enum"), json!({"options":options(&[("in","is one of"),("not_in","is not one of")]),"default":"in"})),
                users,
            ],
        ),
        node("filter", "pr.base_branch", "Pull request", "Base branch", "Target branch matches a pattern (* and ** globs).", "pr", vec![with(param("patterns", "Patterns", "list"), json!({"placeholder":"main, release/*"}))]),
        node("filter", "pr.head_branch", "Pull request", "Head branch", "Source branch matches a pattern.", "pr", vec![with(param("patterns", "Patterns", "list"), json!({"placeholder":"dependabot/**"}))]),
        node(
            "filter",
            "pr.labels",
            "Pull request",
            "Labels",
            "The PR's labels.",
            "pr",
            vec![
                with(param("mode", "Match", "enum"), json!({"options":options(&[("any","has any of"),("all","has all of"),("none","has none of")]),"default":"any"})),
                param("labels", "Labels", "list"),
            ],
        ),
        node("filter", "pr.title", "Pull request", "Title matches", "Regular expression over the PR title.", "pr", vec![with(param("regex", "Regex", "text"), json!({"placeholder":"^chore\\(deps\\)"}))]),
        node("filter", "pr.draft", "Pull request", "Draft", "Whether the PR is a draft.", "pr", vec![with(param("is", "Is draft", "enum"), json!({"options":options(&[("no","Not a draft"),("yes","Draft")]),"default":"no"}))]),
        node("filter", "pr.ci", "Pull request", "CI state", "The combined state of checks on the head commit.", "pr", vec![with(param("is", "CI is", "enum"), json!({"options":options(&[("passing","Passing"),("failing","Failing"),("pending","Running"),("none","No checks")]),"default":"passing"}))]),
        node("filter", "pr.review", "Pull request", "Review decision", "GitHub's review decision.", "pr", vec![with(param("is", "Decision", "enum"), json!({"options":options(&[("APPROVED","Approved"),("CHANGES_REQUESTED","Changes requested"),("REVIEW_REQUIRED","Review required"),("none","No decision")]),"default":"APPROVED"}))]),
        node("filter", "pr.mergeable", "Pull request", "Mergeable", "Whether GitHub can merge the PR cleanly.", "pr", vec![with(param("is", "State", "enum"), json!({"options":options(&[("MERGEABLE","Mergeable"),("CONFLICTING","Conflicting")]),"default":"MERGEABLE"}))]),
        node(
            "filter",
            "pr.size",
            "Pull request",
            "Size",
            "Upper bounds on the change size. Leave a bound empty to ignore it.",
            "pr",
            vec![param("maxLines", "Max lines changed", "number"), param("maxFiles", "Max files changed", "number")],
        ),
        node(
            "filter",
            "pr.paths",
            "Pull request",
            "Changed paths",
            "Globs over the files the PR changes.",
            "pr",
            vec![
                with(param("mode", "Match", "enum"), json!({"options":options(&[("all","every file matches"),("any","any file matches"),("none","no file matches")]),"default":"all"})),
                with(param("patterns", "Patterns", "list"), json!({"placeholder":"**/*.strings, docs/**"})),
            ],
        ),
        node("filter", "jira.has_key", "Jira", "Has a linked ticket", "The PR links at least one Jira ticket (title, body or a saved link).", "any", vec![]),
        node("filter", "jira.project", "Jira", "Ticket project", "Keeps only tickets in these Jira projects.", "any", vec![with(param("keys", "Project keys", "list"), json!({"placeholder":"CASCADE, IOS"}))]),
        node("filter", "jira.status", "Jira", "Ticket status", "Keeps only tickets in one of these statuses.", "any", vec![with(param("statuses", "Statuses", "list"), json!({"placeholder":"In Progress, In Review"}))]),
        node("filter", "jira.type", "Jira", "Ticket type", "Keeps only tickets of these types.", "any", vec![with(param("types", "Types", "list"), json!({"placeholder":"Bug, Story"}))]),
        node("filter", "jira.priority", "Jira", "Ticket priority", "Keeps only tickets with these priorities.", "any", vec![with(param("priorities", "Priorities", "list"), json!({"placeholder":"High, Highest"}))]),
        node(
            "filter",
            "time.window",
            "Time",
            "Time window",
            "Only when the run happens on these days and hours (local time).",
            "any",
            vec![
                with(param("days", "Days", "list"), json!({"placeholder":"mon, tue, wed, thu, fri"})),
                with(param("from", "From", "text"), json!({"placeholder":"09:00"})),
                with(param("to", "To", "text"), json!({"placeholder":"18:00"})),
            ],
        ),
    ];
    let body = |label: &str| with(param("body", label, "template"), json!({"placeholder":"{{pr.title}} — {{pr.url}}"}));
    let merge = vec![
        with(param("method", "Method", "enum"), json!({"options":options(MERGE_METHODS),"default":"squash"})),
        param("deleteBranch", "Delete branch after merge", "bool"),
    ];
    let actions = vec![
        node("action", "github.approve", "GitHub", "Approve", "Approve the PR as you. Never approves your own PR.", "pr", vec![body("Comment (optional)")]),
        node("action", "github.request_changes", "GitHub", "Request changes", "Submit a changes-requested review.", "pr", vec![body("Review comment")]),
        node("action", "github.comment", "GitHub", "Comment", "Post a comment on the PR.", "pr", vec![body("Comment")]),
        node("action", "github.add_label", "GitHub", "Add labels", "Add labels to the PR.", "pr", vec![param("labels", "Labels", "list")]),
        node("action", "github.remove_label", "GitHub", "Remove labels", "Remove labels from the PR.", "pr", vec![param("labels", "Labels", "list")]),
        node("action", "github.request_reviewers", "GitHub", "Request reviewers", "Ask users or org/team slugs to review.", "pr", vec![param("reviewers", "Reviewers", "list")]),
        node("action", "github.assign", "GitHub", "Assign", "Assign users to the PR. @me is you.", "pr", vec![param("assignees", "Assignees", "list")]),
        node("action", "github.auto_merge", "GitHub", "Enable auto-merge", "Merge once required checks and reviews pass.", "pr", merge.clone()),
        node("action", "github.merge", "GitHub", "Merge now", "Merge the PR immediately.", "pr", merge),
        node("action", "github.close", "GitHub", "Close", "Close the PR without merging.", "pr", vec![body("Comment (optional)")]),
        node("action", "github.update_branch", "GitHub", "Update branch", "Bring the PR branch up to date with its base.", "pr", vec![param("rebase", "Rebase instead of merge", "bool")]),
        node("action", "github.rerun_failed", "GitHub", "Re-run failed checks", "Re-run failed GitHub Actions jobs on the head commit.", "pr", vec![]),
        node("action", "github.mark_ready", "GitHub", "Mark ready for review", "Take the PR out of draft.", "pr", vec![]),
        node("action", "jira.transition", "Jira", "Transition ticket", "Move each ticket to a status.", "any", vec![with(param("status", "Status", "text"), json!({"placeholder":"Done"}))]),
        node(
            "action",
            "jira.fix_version",
            "Jira",
            "Set Fix Version",
            "Record which Jira release each ticket ships in. Needs a Jira API token.",
            "any",
            vec![
                with(
                    param("source", "Version", "enum"),
                    json!({"default":"next","options":[
                        {"value":"next","label":"Next unreleased version"},
                        {"value":"template","label":"Name from a template"}
                    ],"help":"Next unreleased: the first release in the Jira project that is not yet released, whatever it is called. A template builds the name, and the release is created if Jira does not have it."}),
                ),
                with(
                    param("template", "Version name", "text"),
                    json!({"when":{"source":"template"},"placeholder":"{year}.{isoWeek}","help":"Dates: {year} {month} {day} {isoWeek}, unpadded {y} {m} {d} {w}, offsets like {year-2000}; also {prNumber} and any {{variable}} below. {year}.{isoWeek} is 2026.39 in week 39."}),
                ),
            ],
        ),
        node("action", "jira.comment", "Jira", "Comment on ticket", "Post a comment on each ticket.", "any", vec![with(param("body", "Comment", "template"), json!({"placeholder":"PR {{pr.url}} is {{event}}"}))]),
        node("action", "jira.assign", "Jira", "Assign ticket", "Assign each ticket. @me is you; empty unassigns.", "any", vec![with(param("assignee", "Assignee", "text"), json!({"placeholder":"@me or someone@company.com"}))]),
        node("action", "jira.add_label", "Jira", "Add ticket labels", "Add labels to each ticket. Needs a Jira API token.", "any", vec![param("labels", "Labels", "list")]),
        node(
            "action",
            "cascade.notify",
            "Cascade",
            "Notify me",
            "Post to Activity and show a macOS notification.",
            "any",
            vec![
                with(param("title", "Title", "template"), json!({"placeholder":"{{pr.title}}"})),
                with(param("body", "Message", "template"), json!({"placeholder":"{{repo}}#{{pr.number}} needs you"})),
            ],
        ),
        node(
            "action",
            "cascade.shell",
            "Cascade",
            "Run shell script",
            "Run a zsh script in the project's workspace (60 s limit). The event is in CASCADE_* variables.",
            "any",
            vec![with(param("script", "Script", "script"), json!({"placeholder":"echo \"$CASCADE_PR_URL\" >> ~/merged.txt"}))],
        ),
        node(
            "action",
            "cascade.webhook",
            "Cascade",
            "POST to webhook",
            "Send the event as JSON to an HTTPS URL (Slack, Teams, your own service).",
            "any",
            vec![
                with(param("url", "URL", "text"), json!({"placeholder":"https://hooks.slack.com/services/…"})),
                with(param("text", "Text (optional)", "template"), json!({"placeholder":"{{pr.title}} merged"})),
            ],
        ),
    ];
    json!({
        "triggers": triggers,
        "filters": filters,
        "actions": actions,
        "templates": templates(),
        "variables": ["event","repo","project.name","pr.number","pr.title","pr.url","pr.author","pr.base","pr.head","jira.key","jira.keys","jira.summary","jira.status","me"],
    })
});

/// Starting points for the "+" menu. Each starts off, so nothing acts before a dry run.
fn templates() -> Value {
    let filter = |node: &str, params: Value| json!({"kind":"filter","type":node,"params":params});
    let action = |node: &str, params: Value| json!({"kind":"action","type":node,"params":params});
    let template = |id: &str, name: &str, summary: &str, types: &[&str], params: Value, steps: Vec<Value>| {
        json!({"id":id,"name":name,"summary":summary,
            "automation":{"name":name,"mode":"off","trigger":{"types":types,"projects":[],"params":params},"steps":steps}})
    };
    json!([
        template(
            "approve-trusted",
            "Auto-approve trusted authors",
            "Approve PRs from people you trust once CI is green.",
            &["pr.opened", "pr.updated", "pr.ci_passed"],
            json!({}),
            vec![
                filter("pr.author", json!({"mode":"in","users":[]})),
                filter("pr.draft", json!({"is":"no"})),
                filter("pr.ci", json!({"is":"passing"})),
                action("github.approve", json!({"body":"Auto-approved by [Cascade](https://github.com/alexcding/cascade-mac)"})),
            ],
        ),
        template(
            "merge-jira",
            "On merge → Jira",
            "Set a Fix Version and close linked tickets when a PR merges.",
            &["pr.merged"],
            json!({}),
            vec![
                filter("jira.has_key", json!({})),
                action("jira.fix_version", json!({"source":"next"})),
                action("jira.transition", json!({"status":"Done"})),
            ],
        ),
        template(
            "opened-in-review",
            "My PR opened → In Review",
            "Move your ticket to In Review and link the PR on it.",
            &["pr.opened", "pr.ready_for_review"],
            json!({}),
            vec![
                filter("pr.author", json!({"mode":"in","users":["@me"]})),
                filter("pr.draft", json!({"is":"no"})),
                filter("jira.has_key", json!({})),
                action("jira.transition", json!({"status":"In Review"})),
                action("jira.comment", json!({"body":"PR opened: {{pr.url}}"})),
            ],
        ),
        template(
            "changes-in-progress",
            "Changes requested → In Progress",
            "Send your ticket back to In Progress and tell you.",
            &["pr.changes_requested"],
            json!({}),
            vec![
                filter("pr.author", json!({"mode":"in","users":["@me"]})),
                action("jira.transition", json!({"status":"In Progress"})),
                action("cascade.notify", json!({"title":"Changes requested","body":"{{repo}}#{{pr.number}} {{pr.title}}"})),
            ],
        ),
        template(
            "dependabot",
            "Dependabot → approve and auto-merge",
            "Approve green dependency bumps and let GitHub merge them.",
            &["pr.ci_passed"],
            json!({}),
            vec![
                filter("pr.author", json!({"mode":"in","users":["@bots"]})),
                filter("pr.head_branch", json!({"patterns":["dependabot/**"]})),
                action("github.approve", json!({"body":"Green dependency bump, approved by Cascade."})),
                action("github.auto_merge", json!({"method":"squash","deleteBranch":true})),
            ],
        ),
        template(
            "rerun-ci",
            "CI failed → re-run checks",
            "Re-run failed jobs on your PRs once per commit.",
            &["pr.ci_failed"],
            json!({}),
            vec![
                filter("pr.author", json!({"mode":"in","users":["@me"]})),
                action("github.rerun_failed", json!({})),
            ],
        ),
        template(
            "review-requested",
            "Review requested → notify",
            "A notification the moment someone asks for your review.",
            &["pr.review_requested"],
            json!({}),
            vec![action("cascade.notify", json!({"title":"Review requested","body":"{{pr.author}}: {{pr.title}}"}))],
        ),
        template(
            "stale",
            "Stale PR → nudge",
            "Notify you when one of your PRs has sat untouched for five days.",
            &["pr.stale"],
            json!({"days":5}),
            vec![
                filter("pr.author", json!({"mode":"in","users":["@me"]})),
                action("cascade.notify", json!({"title":"Stale PR","body":"{{pr.title}} has had no update in 5 days"})),
            ],
        ),
        template(
            "ticket-assigned",
            "Ticket assigned → notify",
            "Hear about new tickets assigned to you.",
            &["jira.entered"],
            json!({"jql":"assignee = currentUser() AND statusCategory != Done"}),
            vec![action("cascade.notify", json!({"title":"Assigned: {{jira.key}}","body":"{{jira.summary}}"}))],
        ),
    ])
}

pub fn catalog() -> &'static Value {
    &CATALOG
}

pub fn find(section: &str, node: &str) -> Option<&'static Value> {
    catalog()[section]
        .as_array()?
        .iter()
        .find(|item| item["type"] == node)
}

pub fn label(section: &str, node: &str) -> String {
    find(section, node)
        .and_then(|item| item["label"].as_str())
        .unwrap_or(node)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn node_types_are_unique_and_well_formed() {
        let mut seen = HashSet::new();
        for section in ["triggers", "filters", "actions"] {
            for item in catalog()[section].as_array().unwrap() {
                let node = item["type"].as_str().unwrap();
                assert!(seen.insert(node.to_owned()), "duplicate node {node}");
                assert!(item["label"].as_str().is_some_and(|v| !v.is_empty()));
                for param in item["params"].as_array().unwrap() {
                    let kind = param["kind"].as_str().unwrap();
                    assert!(
                        ["text", "template", "bool", "enum", "list", "number", "jql", "script"].contains(&kind),
                        "{node}: unknown param kind {kind}"
                    );
                    if kind == "enum" {
                        assert!(param["options"].as_array().is_some_and(|v| !v.is_empty()));
                    }
                }
            }
        }
    }
}
