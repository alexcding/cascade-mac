use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A project's stored pull requests for one state: the lean list as `github::lean` copies it,
/// when it was synced, and the error that stood in for a fetch. Serializes to the
/// `{"prs","lastSynced","error"}` the dashboard and tray have always read. A default value is
/// the never-synced snapshot: no pull requests, `null` stamp, `null` error.
///
/// The items stay `Value` for now: the poller reads them enriched (before `lean`), the
/// snapshot holds them lean, and a merge webhook fills a REST payload in from them, so one
/// struct does not yet fit all three.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PrSnapshot {
    pub prs: Vec<Value>,
    pub last_synced: Option<String>,
    pub error: Option<String>,
}

impl PrSnapshot {
    /// A snapshot taken now: `prs` as fetched, or the list that stood while `error` happened.
    pub fn taken(prs: Vec<Value>, error: Option<String>) -> Self {
        Self {
            prs,
            last_synced: Some(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)),
            error,
        }
    }

    /// When it was synced, if it was and the stamp reads.
    pub fn synced_at(&self) -> Option<DateTime<Utc>> {
        let stamp = self.last_synced.as_deref()?;
        DateTime::parse_from_rfc3339(stamp)
            .ok()
            .map(|time| time.with_timezone(&Utc))
    }

    /// Whether it was synced more than `max_age` seconds ago, or never.
    pub fn is_stale(&self, max_age: i64) -> bool {
        self.synced_at()
            .is_none_or(|time| Utc::now().signed_duration_since(time).num_seconds() > max_age)
    }

    /// Whether a fetched list, or the error that stood in for one, differs from what is stored.
    /// `lastSynced` moves on every tick and is not a change the app needs to hear about: each
    /// `sync` it hears costs it a dashboard and a tray read for every project.
    pub fn differs(&self, prs: &[Value], error: Option<&str>) -> bool {
        self.prs != prs || self.error.as_deref() != error
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_snapshot_serializes_to_the_json_the_routes_read() {
        let never = serde_json::to_value(PrSnapshot::default()).unwrap();
        assert_eq!(never, json!({"prs": [], "lastSynced": null, "error": null}));
        let taken = PrSnapshot::taken(vec![json!({"number": 1})], Some("gh: offline".into()));
        let value = serde_json::to_value(&taken).unwrap();
        assert_eq!(value["prs"], json!([{"number": 1}]));
        assert_eq!(value["error"], "gh: offline");
        assert!(value["lastSynced"].as_str().unwrap().ends_with('Z'));
        let read: PrSnapshot =
            serde_json::from_value(json!({"prs": [{"number": 2}], "lastSynced": "t", "error": null}))
                .unwrap();
        assert_eq!(read.prs, vec![json!({"number": 2})]);
        assert_eq!(read.last_synced.as_deref(), Some("t"));
        assert_eq!(read.error, None);
    }

    #[test]
    fn staleness_reads_the_stamp() {
        assert!(PrSnapshot::default().is_stale(60));
        let stamped = |stamp: String| PrSnapshot {
            last_synced: Some(stamp),
            ..PrSnapshot::default()
        };
        let old = (Utc::now() - chrono::Duration::seconds(120)).to_rfc3339();
        let fresh = Utc::now().to_rfc3339();
        assert!(stamped(old).is_stale(60));
        assert!(!stamped(fresh).is_stale(60));
        assert!(stamped("not a time".into()).is_stale(60));
    }

    #[test]
    fn only_the_list_and_the_error_count_as_a_change() {
        let prs = vec![json!({"number": 1, "title": "a"})];
        let clean = PrSnapshot::taken(prs.clone(), None);
        let failed = PrSnapshot::taken(prs.clone(), Some("gh: rate limited".into()));
        assert!(!clean.differs(&prs, None));
        assert!(clean.differs(&[json!({"number": 1, "title": "b"})], None));
        assert!(clean.differs(&[], None));
        assert!(clean.differs(&prs, Some("gh: rate limited")));
        assert!(failed.differs(&prs, Some("gh: offline")));
        assert!(failed.differs(&prs, None));
        assert!(!failed.differs(&prs, Some("gh: rate limited")));
    }
}
