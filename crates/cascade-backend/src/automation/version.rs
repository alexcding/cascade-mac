//! Fix Version names from a placeholder template, for the `jira.fix_version` action.

use std::sync::OnceLock;

use chrono::{Datelike, Local, NaiveDate};
use regex::Regex;

use crate::error::ApiError;

/// Renders a Fix Version name from a placeholder template against the local clock. Literal
/// text such as a platform prefix (`ios-`) is kept as written.
///
/// Placeholders are `{name}` or `{name+N}` / `{name-N}`: `year`, `month`, `day`, `isoWeek`
/// (zero-padded), `y`, `m`, `d`, `w` (unpadded) and `prNumber`. An offset shifts the value and
/// drops the padding, so `ios-{year-2026}.{m}.{d}` renders `ios-0.9.21` on 2026-09-21. Dates use the machine's time zone,
/// which is the one the user reads the version in.
pub(super) fn render_version_template(template: &str, pr_number: i64) -> Result<String, ApiError> {
    render_version_template_at(template, pr_number, Local::now().date_naive())
}

fn render_version_template_at(
    template: &str,
    pr_number: i64,
    today: NaiveDate,
) -> Result<String, ApiError> {
    let raw = template.trim();
    if raw.is_empty() {
        return Err(ApiError::bad_request("version template is empty"));
    }
    if raw.contains("${") || raw.contains("return ") || raw.contains("=>") || raw.contains("function") {
        return Err(ApiError::bad_request(
            "JavaScript version scripts are no longer executed. Replace this value with a template such as ios-{year-2026}.{m}.{d}.",
        ));
    }
    static PLACEHOLDER: OnceLock<Regex> = OnceLock::new();
    let placeholder = PLACEHOLDER.get_or_init(|| {
        Regex::new(r"\{([A-Za-z]+)(?:([+-])(\d{1,6}))?\}").expect("valid placeholder regex")
    });
    let mut error = None;
    let value = placeholder.replace_all(raw, |caps: &regex::Captures| {
        let (base, width) = match &caps[1] {
            "year" => (i64::from(today.year()), 4),
            "month" => (i64::from(today.month()), 2),
            "day" => (i64::from(today.day()), 2),
            "isoWeek" => (i64::from(today.iso_week().week()), 2),
            "y" => (i64::from(today.year()), 0),
            "m" => (i64::from(today.month()), 0),
            "d" => (i64::from(today.day()), 0),
            "w" => (i64::from(today.iso_week().week()), 0),
            "prNumber" => (pr_number, 0),
            other => {
                error.get_or_insert(format!("Unknown version-template placeholder {{{other}}}"));
                return String::new();
            }
        };
        let offset = caps.get(3).and_then(|digits| digits.as_str().parse::<i64>().ok()).unwrap_or(0);
        let shifted = if caps.get(2).map(|sign| sign.as_str()) == Some("-") { base - offset } else { base + offset };
        if shifted < 0 {
            error.get_or_insert(format!("Version-template placeholder {} renders a negative number", &caps[0]));
            return String::new();
        }
        let width = if caps.get(2).is_some() { 0 } else { width };
        format!("{shifted:0width$}")
    });
    if let Some(message) = error {
        return Err(ApiError::bad_request(message));
    }
    if value.contains('{') || value.contains('}') || value.chars().any(char::is_control) {
        return Err(ApiError::bad_request("Unknown or invalid version-template placeholder"));
    }
    let value = value.trim();
    if value.is_empty() || value.len() > 128 {
        return Err(ApiError::bad_request("version template must produce 1–128 characters"));
    }
    Ok(value.into())
}

#[cfg(test)]
mod version_template_tests {
    use super::render_version_template_at;
    use chrono::NaiveDate;

    fn render(template: &str) -> Result<String, String> {
        render_at(template, 2026, 9, 21)
    }

    fn render_at(template: &str, year: i32, month: u32, day: u32) -> Result<String, String> {
        let today = NaiveDate::from_ymd_opt(year, month, day).unwrap();
        render_version_template_at(template, 482, today).map_err(|e| format!("{e:?}"))
    }

    #[test]
    fn padded_placeholders_keep_their_shape() {
        assert_eq!(render("{year}.{month}.{day}").unwrap(), "2026.09.21");
        assert_eq!(render("0.{isoWeek}").unwrap(), "0.39");
        assert_eq!(render("{prNumber}").unwrap(), "482");
    }

    #[test]
    fn unpadded_and_offset_placeholders_match_the_old_script() {
        assert_eq!(render("ios-{year-2026}.{m}.{d}").unwrap(), "ios-0.9.21");
        assert_eq!(render("{year+1}.{w}").unwrap(), "2027.39");
        assert_eq!(render("{y-2000}").unwrap(), "26");
        assert_eq!(render("{month+3}").unwrap(), "12");
        assert_eq!(render_at("{day}.{d}.{isoWeek}.{w}", 2026, 1, 5).unwrap(), "05.5.02.2");
    }

    #[test]
    fn negative_results_are_rejected() {
        assert!(render("{year-2030}").is_err());
        assert!(render("{m-9}").is_ok());
        assert!(render("{m-10}").is_err());
    }

    #[test]
    fn javascript_and_unknown_placeholders_are_rejected() {
        assert!(render("((d)=>`${d.getFullYear()}`)(new Date())").is_err());
        assert!(render("{yeer}").is_err());
        assert!(render("{year}.{").is_err());
        assert!(render("   ").is_err());
    }
}
