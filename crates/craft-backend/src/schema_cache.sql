CREATE TABLE IF NOT EXISTS pr_snapshots (
  id TEXT PRIMARY KEY, prs TEXT NOT NULL DEFAULT '[]', last_synced TEXT, error TEXT
);
CREATE TABLE IF NOT EXISTS jira_snapshots (
  id TEXT PRIMARY KEY, items TEXT NOT NULL DEFAULT '[]', jql TEXT, last_synced TEXT, error TEXT, meta TEXT
);
CREATE TABLE IF NOT EXISTS pr_scope_snapshots (
  id TEXT NOT NULL, state TEXT NOT NULL, identity TEXT NOT NULL, prs TEXT NOT NULL DEFAULT '[]',
  last_synced TEXT, error TEXT, PRIMARY KEY (id, state)
);
