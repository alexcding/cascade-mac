//! Scheduled automations: an agent started with a prompt at the times a schedule names.
//!
//! The engine ticks once a minute (`poller.rs`). A tick starts each scheduled automation that is
//! on whose latest time fell within its grace and after it was switched on, once per time (the
//! fired ledger keys it `slot:<time>`). Times missed while the Mac slept or the app was closed
//! are caught up on, not replayed: only the latest one runs. The backend makes or picks the
//! session and asks the app to start its agent (`Event::AutomationLaunch`), since only the app
//! types into a terminal; a run therefore needs the app open.

use std::path::Path;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc};

use super::model::{Automation, Kind, Mode, Repeat, Schedule, SessionMode, StepResult, Trace, Workspace};
use super::{runner, store};
use crate::sessions::{self, NewSession};
use crate::{cli, AppState, Session};

/// Scheduled runs closer together than this are refused at save: each one starts an agent.
pub const MIN_GAP_MINUTES: i64 = 10;
/// The longest a missed run may still start late.
pub const MAX_GRACE_MINUTES: i64 = 7 * 24 * 60;
/// What a precheck prints reaches the agent up to this many characters.
const PRECHECK_OUTPUT: usize = 4000;

/// When a schedule falls, as a test on a local minute: a cron expression, which every repeat
/// reduces to.
#[derive(Clone, Debug, PartialEq)]
pub struct Times {
    minutes: [bool; 60],
    hours: [bool; 24],
    days: [bool; 32],
    months: [bool; 13],
    /// 0 is Sunday, as cron counts.
    weekdays: [bool; 7],
    /// Cron matches either day field when both are restricted, and both otherwise; a field that
    /// starts with `*` counts as unrestricted for that choice.
    any_day: bool,
    any_weekday: bool,
}

impl Times {
    fn day_matches(&self, date: NaiveDate) -> bool {
        if !self.months[date.month() as usize] {
            return false;
        }
        let day = self.days[date.day() as usize];
        let weekday = self.weekdays[date.weekday().num_days_from_sunday() as usize];
        // Both fields always hold their values (a bare `*` holds every one); only when neither
        // starts with `*` is either one enough.
        if self.any_day || self.any_weekday { day && weekday } else { day || weekday }
    }

    fn matches(&self, at: NaiveDateTime) -> bool {
        self.day_matches(at.date()) && self.hours[at.hour() as usize] && self.minutes[at.minute() as usize]
    }

    /// The latest matching minute at or before `now`, no more than `within` minutes back.
    pub fn previous(&self, now: NaiveDateTime, within: i64) -> Option<NaiveDateTime> {
        let now = minute(now);
        (0..=within).map(|back| now - Duration::minutes(back)).find(|at| self.matches(*at))
    }

    /// The first matching minute after `after`, within two years.
    pub fn next(&self, after: NaiveDateTime) -> Option<NaiveDateTime> {
        let mut at = minute(after) + Duration::minutes(1);
        let end = at + Duration::days(366 * 2);
        while at < end {
            if !self.day_matches(at.date()) {
                at = at.date().succ_opt()?.and_time(NaiveTime::MIN);
            } else if !self.hours[at.hour() as usize] {
                at = minute(at) - Duration::minutes(at.minute() as i64) + Duration::hours(1);
            } else if !self.minutes[at.minute() as usize] {
                at += Duration::minutes(1);
            } else {
                return Some(at);
            }
        }
        None
    }
}

fn minute(at: NaiveDateTime) -> NaiveDateTime {
    at.with_second(0).and_then(|at| at.with_nanosecond(0)).unwrap_or(at)
}

/// A schedule's times, or why it has none.
pub fn times(schedule: &Schedule) -> Result<Times, String> {
    let at = || -> Result<(u32, u32), String> {
        let time = NaiveTime::parse_from_str(schedule.time.trim(), "%H:%M")
            .map_err(|_| format!("{} is not a time of day", schedule.time))?;
        Ok((time.hour(), time.minute()))
    };
    let daily = |weekdays: &str| -> Result<Times, String> {
        let (hour, minute) = at()?;
        parse_cron(&format!("{minute} {hour} * * {weekdays}"))
    };
    match schedule.repeat {
        Repeat::Daily => daily("*"),
        Repeat::Weekdays => daily("1-5"),
        Repeat::Weekly => {
            let mut days: Vec<u8> = schedule.days.iter().copied().filter(|d| (1..=7).contains(d)).collect();
            days.sort_unstable();
            days.dedup();
            if days.is_empty() {
                return Err("Choose at least one day".into());
            }
            daily(&days.iter().map(|d| (d % 7).to_string()).collect::<Vec<_>>().join(","))
        }
        Repeat::Hours => {
            let every = schedule.every_hours;
            if !(1..=24).contains(&every) {
                return Err("Repeat every 1 to 24 hours".into());
            }
            let (hour, minute) = at()?;
            let hours: Vec<String> =
                (0..24).filter(|h| (h + 24 - hour) % 24 % every == 0).map(|h| h.to_string()).collect();
            parse_cron(&format!("{minute} {} * * *", hours.join(",")))
        }
        Repeat::Cron => parse_cron(&schedule.cron),
    }
}

/// A five-field cron expression: minute, hour, day of month, month, day of week. Each field is
/// `*` or a list of values and ranges, any with a `/step`; months and weekdays take their
/// three-letter English names, and Sunday is 0 or 7.
pub fn parse_cron(expression: &str) -> Result<Times, String> {
    let fields: Vec<&str> = expression.split_whitespace().collect();
    if fields.len() != 5 {
        return Err("A cron expression has five fields: minute hour day month weekday".into());
    }
    const MONTHS: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    let minutes = field(fields[0], 0, 59, &[], 0)?;
    let hours = field(fields[1], 0, 23, &[], 0)?;
    let days = field(fields[2], 1, 31, &[], 0)?;
    let months = field(fields[3], 1, 12, &MONTHS, 1)?;
    let weekdays = field(fields[4], 0, 7, &WEEKDAYS, 0)?;
    let mut times = Times {
        minutes: [false; 60],
        hours: [false; 24],
        days: [false; 32],
        months: [false; 13],
        weekdays: [false; 7],
        // A field that starts with `*` (`*/2` too) restricts nothing, as Vixie cron reads it.
        any_day: fields[2].starts_with('*'),
        any_weekday: fields[4].starts_with('*'),
    };
    minutes.into_iter().for_each(|v| times.minutes[v as usize] = true);
    hours.into_iter().for_each(|v| times.hours[v as usize] = true);
    days.into_iter().for_each(|v| times.days[v as usize] = true);
    months.into_iter().for_each(|v| times.months[v as usize] = true);
    weekdays.into_iter().for_each(|v| times.weekdays[(v % 7) as usize] = true);
    Ok(times)
}

/// One cron field's values. `names[i]` stands for `first + i`.
fn field(text: &str, low: u32, high: u32, names: &[&str], first: u32) -> Result<Vec<u32>, String> {
    let bad = || format!("{text} is not a valid cron field");
    let value = |item: &str| -> Result<u32, String> {
        let lower = item.to_ascii_lowercase();
        if let Some(index) = names.iter().position(|name| *name == lower) {
            return Ok(first + index as u32);
        }
        let number: u32 = item.parse().map_err(|_| bad())?;
        if number < low || number > high {
            return Err(format!("{number} is out of range in {text}"));
        }
        Ok(number)
    };
    let mut values = Vec::new();
    for item in text.split(',') {
        let (range, step) = match item.split_once('/') {
            Some((range, step)) => (range, step.parse::<u32>().ok().filter(|s| *s > 0).ok_or_else(bad)?),
            None => (item, 1),
        };
        let (start, end) = if range == "*" {
            (low, high)
        } else if let Some((a, b)) = range.split_once('-') {
            (value(a)?, value(b)?)
        } else {
            let start = value(range)?;
            // `5/15` runs from 5 to the end, as cron reads it.
            (start, if item.contains('/') { high } else { start })
        };
        if start > end {
            return Err(bad());
        }
        values.extend((start..=end).step_by(step as usize));
    }
    if values.is_empty() {
        return Err(bad());
    }
    Ok(values)
}

/// Check a scheduled automation before it is stored: what the run needs, and times that are not
/// so close together that they would start agent after agent.
pub fn validate(schedule: &mut Schedule) -> Result<(), String> {
    schedule.prompt = schedule.prompt.trim().to_owned();
    schedule.branch = schedule.branch.trim().to_owned();
    if schedule.prompt.is_empty() {
        return Err("Write the prompt the agent starts with".into());
    }
    if schedule.project.is_empty() {
        return Err("Choose a project".into());
    }
    if !crate::agents::Agent::allowed_cli(&schedule.cli) {
        return Err("Unsupported agent".into());
    }
    if schedule.workspace == Workspace::Worktree && schedule.branch.is_empty() {
        return Err("Choose the worktree the agent works in".into());
    }
    schedule.grace_minutes = schedule.grace_minutes.clamp(0, MAX_GRACE_MINUTES);
    schedule.precheck_timeout = schedule.precheck_timeout.clamp(1, 600);
    let times = times(schedule)?;
    let mut at = Local::now().naive_local();
    let mut previous: Option<NaiveDateTime> = None;
    for _ in 0..48 {
        let Some(next) = times.next(at) else { break };
        if previous.is_some_and(|p| next - p < Duration::minutes(MIN_GAP_MINUTES)) {
            return Err(format!("Scheduled runs must be at least {MIN_GAP_MINUTES} minutes apart"));
        }
        previous = Some(next);
        at = next;
    }
    if previous.is_none() {
        return Err("This schedule never runs".into());
    }
    Ok(())
}

/// The time to run now: the latest the schedule fell at, within its grace and no earlier than
/// when it was switched on.
pub fn due(automation: &Automation, now: DateTime<Local>) -> Option<DateTime<Utc>> {
    if automation.kind != Kind::Schedule || automation.mode == Mode::Off {
        return None;
    }
    let times = times(&automation.schedule).ok()?;
    let grace = automation.schedule.grace_minutes.clamp(0, MAX_GRACE_MINUTES);
    let slot = times.previous(now.naive_local(), grace)?;
    // A local time the clocks skipped when they went forward never happens.
    let slot = Local.from_local_datetime(&slot).earliest()?.with_timezone(&Utc);
    let armed = DateTime::parse_from_rfc3339(automation.armed_at.as_deref()?).ok()?.with_timezone(&Utc);
    (slot >= armed).then_some(slot)
}

/// When a scheduled automation that is on runs next, for the table.
pub fn next_run(automation: &Automation) -> Option<String> {
    if automation.kind != Kind::Schedule || automation.mode == Mode::Off {
        return None;
    }
    let times = times(&automation.schedule).ok()?;
    let mut at = Local::now().naive_local();
    // A local time the clocks skip never happens; the one after it is the next run.
    for _ in 0..4 {
        at = times.next(at)?;
        if let Some(next) = Local.from_local_datetime(&at).earliest() {
            return Some(next.with_timezone(&Utc).to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
        }
    }
    None
}

/// Once a minute: start every scheduled automation that is due and has not run for this time.
pub async fn tick(app: &AppState) {
    if super::paused(app).await {
        return;
    }
    let now = Local::now();
    for automation in store::list(&app.db).await.unwrap_or_default() {
        let Some(slot) = due(&automation, now) else { continue };
        let key = format!("slot:{}", slot.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
        if !store::claim(&app.db, &automation.id, &key).await.unwrap_or(false) {
            continue;
        }
        let app = app.clone();
        tokio::spawn(async move {
            run_and_record(&app, &automation, &key, "schedule").await;
        });
    }
}

/// Run a scheduled automation now, record the run, and tell Activity. `origin` is `schedule` for
/// a tick and `manual` for Run Now.
pub async fn run_and_record(app: &AppState, automation: &Automation, key: &str, origin: &str) -> Trace {
    let trace = run(app, automation, key, origin).await;
    runner::finish(app, automation, trace).await
}

fn step(id: &str, label: &str, status: &str, detail: impl Into<String>, commands: Vec<String>) -> StepResult {
    StepResult {
        step_id: id.into(),
        node: format!("schedule.{id}"),
        label: label.into(),
        status: status.into(),
        detail: detail.into(),
        commands,
    }
}

fn stamp() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

async fn run(app: &AppState, automation: &Automation, key: &str, origin: &str) -> Trace {
    let started_at = stamp();
    let schedule = &automation.schedule;
    let mut steps = Vec::new();
    let status = run_steps(app, automation, &mut steps).await;
    let project = app.db.project(&schedule.project).await.ok().flatten();
    Trace {
        automation_id: automation.id.clone(),
        automation_name: automation.name.clone(),
        event_kind: origin.into(),
        event_key: key.into(),
        subject: project.map(|p| p.name).unwrap_or_else(|| automation.name.clone()),
        mode: "live".into(),
        trigger_matched: true,
        trigger_detail: match key.strip_prefix("slot:") {
            Some(slot) => format!("scheduled for {slot}"),
            None => "run by hand".into(),
        },
        status: status.into(),
        steps,
        started_at,
        finished_at: stamp(),
    }
}

/// The run's steps — precheck, session, launch — and how it ended: `completed`, `filtered` when
/// the precheck said no, or `error`.
async fn run_steps(app: &AppState, automation: &Automation, steps: &mut Vec<StepResult>) -> &'static str {
    let schedule = &automation.schedule;
    let Some(project) = app.db.project(&schedule.project).await.ok().flatten() else {
        steps.push(step("session", "Session", "error", "The project this automation runs in is gone.", vec![]));
        return "error";
    };
    let mut prompt = schedule.prompt.clone();
    let script = schedule.precheck.trim();
    if !script.is_empty() {
        let command = vec![format!("zsh -lc {script:?}  (in {})", project.workspace)];
        let cwd = Path::new(&project.workspace);
        if project.workspace.is_empty() || !cwd.is_dir() {
            steps.push(step("precheck", "Precheck", "error", "The project folder is missing, so the precheck could not run.", command));
            return "error";
        }
        let cwd = Some(cwd);
        let timeout = StdDuration::from_secs(schedule.precheck_timeout.max(1));
        match cli::run_in("/bin/zsh", ["-lc", script], timeout, cwd).await {
            Ok(output) => {
                let output: String = output.chars().take(PRECHECK_OUTPUT).collect();
                let detail = if output.is_empty() { "exited 0".to_owned() } else { output.chars().take(500).collect() };
                if !output.is_empty() {
                    prompt.push_str("\n\nPrecheck output:\n");
                    prompt.push_str(&output);
                }
                steps.push(step("precheck", "Precheck", "passed", detail, command));
            }
            Err(error) => {
                steps.push(step("precheck", "Precheck", "failed", format!("skipped: {error}"), command));
                return "filtered";
            }
        }
    }
    let (session, fresh) = match session_for(app, automation).await {
        Ok(found) => found,
        Err(error) => {
            steps.push(step("session", "Session", "error", error, vec![]));
            return "error";
        }
    };
    let _ = store::set_last_session(&app.db, &automation.id, &session.id).await;
    steps.push(step(
        "session",
        "Session",
        "done",
        format!("{} in {}", if fresh { "new conversation" } else { "resumed" }, session.branch),
        vec![],
    ));
    app.publish(crate::Event::AutomationLaunch {
        task_id: session.id.clone(),
        prompt,
        fresh,
        automation: automation.name.clone(),
    });
    let agent = if session.cli.is_empty() { "the agent".to_owned() } else { session.cli.clone() };
    steps.push(step("launch", "Start agent", "done", format!("asked the app to start {agent}"), vec![]));
    "completed"
}

/// The session a run's agent works in, and whether it starts a new conversation there.
async fn session_for(app: &AppState, automation: &Automation) -> Result<(Session, bool), String> {
    let schedule = &automation.schedule;
    if schedule.session == SessionMode::Reuse {
        if let Some(id) = store::last_session(&app.db, &automation.id).await.ok().flatten() {
            if let Some(session) = app.db.task(&id).await.ok().flatten() {
                return Ok((session, false));
            }
        }
    }
    let create = |branch: String, create_branch: bool| {
        let body = NewSession::on_branch(&schedule.project, &branch, create_branch, &automation.name, &schedule.cli);
        async move { sessions::create(app, body).await.map_err(|error| error.to_string()) }
    };
    match schedule.workspace {
        Workspace::Worktree => {
            let tasks = app.db.tasks().await.map_err(|error| error.to_string())?;
            let existing = tasks
                .into_iter()
                .find(|task| task.project_id == schedule.project && task.branch == schedule.branch);
            match existing {
                Some(session) => Ok((session, schedule.session == SessionMode::Fresh)),
                None => Ok((create(schedule.branch.clone(), false).await?, true)),
            }
        }
        Workspace::New => Ok((create(run_branch(&automation.name, Local::now()), true).await?, true)),
    }
}

/// A new run's branch: `auto/<name>-<date>-<time>`.
fn run_branch(name: &str, at: DateTime<Local>) -> String {
    let mut slug = String::new();
    for c in name.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
        } else if !slug.ends_with('-') && !slug.is_empty() {
            slug.push('-');
        }
    }
    let slug: String = slug.trim_end_matches('-').chars().take(32).collect();
    let slug = if slug.is_empty() { "run".to_owned() } else { slug.trim_end_matches('-').to_owned() };
    // Two runs in one second (Run Now beside a tick) must not land on one branch, and so one worktree.
    let unique = uuid::Uuid::new_v4().simple().to_string();
    format!("auto/{slug}-{}-{}", at.format("%Y%m%d-%H%M"), &unique[..6])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local(text: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M").unwrap()
    }

    fn schedule(repeat: Repeat) -> Schedule {
        Schedule { repeat, prompt: "p".into(), project: "x".into(), ..Schedule::default() }
    }

    #[test]
    fn weekdays_at_nine_skip_the_weekend() {
        let times = times(&schedule(Repeat::Weekdays)).unwrap();
        // 2026-10-02 is a Friday.
        assert_eq!(times.next(local("2026-10-02 09:00")), Some(local("2026-10-05 09:00")));
        assert_eq!(times.next(local("2026-10-02 08:59")), Some(local("2026-10-02 09:00")));
        assert_eq!(times.previous(local("2026-10-04 12:00"), 3 * 24 * 60), Some(local("2026-10-02 09:00")));
        assert_eq!(times.previous(local("2026-10-05 08:00"), 12 * 60), None);
    }

    #[test]
    fn weekly_days_count_sunday_as_seven() {
        let mut weekly = schedule(Repeat::Weekly);
        weekly.days = vec![7, 3];
        weekly.time = "18:30".into();
        let times = times(&weekly).unwrap();
        // 2026-10-04 is a Sunday.
        assert_eq!(times.next(local("2026-10-04 10:00")), Some(local("2026-10-04 18:30")));
        assert_eq!(times.next(local("2026-10-04 19:00")), Some(local("2026-10-07 18:30")));
        weekly.days.clear();
        assert!(super::times(&weekly).is_err());
    }

    #[test]
    fn every_few_hours_counts_from_the_time() {
        let mut hours = schedule(Repeat::Hours);
        hours.every_hours = 4;
        hours.time = "09:15".into();
        let times = times(&hours).unwrap();
        assert_eq!(times.next(local("2026-10-04 09:15")), Some(local("2026-10-04 13:15")));
        assert_eq!(times.next(local("2026-10-04 22:00")), Some(local("2026-10-05 01:15")));
        // An interval that does not divide the day still runs at the chosen hour.
        hours.every_hours = 5;
        hours.time = "09:00".into();
        let times = super::times(&hours).unwrap();
        assert_eq!(times.next(local("2026-10-04 08:00")), Some(local("2026-10-04 09:00")));
        assert_eq!(times.next(local("2026-10-04 09:00")), Some(local("2026-10-04 14:00")));
    }

    #[test]
    fn cron_reads_lists_ranges_steps_and_names() {
        let times = parse_cron("*/30 9-17 * * mon-fri").unwrap();
        assert_eq!(times.next(local("2026-10-02 17:30")), Some(local("2026-10-05 09:00")));
        assert_eq!(times.next(local("2026-10-05 09:00")), Some(local("2026-10-05 09:30")));
        // Both day fields restricted: either one matches, as cron has it.
        let either = parse_cron("0 0 1 * sun").unwrap();
        assert_eq!(either.next(local("2026-10-01 00:00")), Some(local("2026-10-04 00:00")));
        // A stepped star restricts nothing: Mondays that are odd days, not odd days and Mondays.
        let stepped = parse_cron("0 9 */2 * 1").unwrap();
        assert_eq!(stepped.next(local("2026-10-04 00:00")), Some(local("2026-10-05 09:00")));
        assert_eq!(stepped.next(local("2026-10-05 09:00")), Some(local("2026-10-19 09:00")));
        assert!(parse_cron("0 0 * *").is_err());
        assert!(parse_cron("61 * * * *").is_err());
        assert!(parse_cron("0 0 30 feb *").unwrap().next(local("2026-01-01 00:00")).is_none());
    }

    #[test]
    fn a_schedule_must_run_and_not_too_often() {
        let mut cron = schedule(Repeat::Cron);
        cron.cron = "*/5 * * * *".into();
        assert!(validate(&mut cron).unwrap_err().contains("apart"));
        cron.cron = "0 0 30 feb *".into();
        assert!(validate(&mut cron).is_err());
        cron.cron = "0 */2 * * *".into();
        assert!(validate(&mut cron).is_ok());
        let mut worktree = schedule(Repeat::Daily);
        worktree.workspace = Workspace::Worktree;
        assert!(validate(&mut worktree).is_err(), "a worktree run names its branch");
        worktree.prompt = "  ".into();
        assert!(validate(&mut worktree).unwrap_err().contains("prompt"));
    }

    #[test]
    fn a_due_time_is_the_latest_within_grace_and_after_switching_on() {
        let mut automation = Automation { kind: Kind::Schedule, mode: Mode::Live, schedule: schedule(Repeat::Daily), ..Automation::default() };
        let now = Local.from_local_datetime(&local("2026-10-04 10:00")).earliest().unwrap();
        let nine = Local.from_local_datetime(&local("2026-10-04 09:00")).earliest().unwrap().with_timezone(&Utc);
        automation.armed_at = Some("2026-01-01T00:00:00Z".into());
        assert_eq!(due(&automation, now), Some(nine));
        automation.schedule.grace_minutes = 30;
        assert_eq!(due(&automation, now), None, "an hour late is past a half-hour grace");
        automation.schedule.grace_minutes = 120;
        automation.armed_at = Some((nine + Duration::seconds(30)).to_rfc3339());
        assert_eq!(due(&automation, now), None, "switched on after nine, so nine does not run");
        automation.armed_at = Some("2026-01-01T00:00:00Z".into());
        automation.mode = Mode::Off;
        assert_eq!(due(&automation, now), None);
    }

    #[test]
    fn a_run_branch_is_a_slug_and_a_time() {
        let at = Local.from_local_datetime(&local("2026-10-04 09:00")).earliest().unwrap();
        let branch = run_branch("Weekday repo audit!", at);
        assert!(branch.starts_with("auto/weekday-repo-audit-20261004-0900-") && branch.len() == "auto/weekday-repo-audit-20261004-0900-".len() + 6);
        assert!(run_branch("—", at).starts_with("auto/run-20261004-0900-"));
        assert_ne!(run_branch("x", at), run_branch("x", at));
    }
}
