use anyhow::{ensure, Context, Result};
use serde_json::Value;
use std::time::Duration;

// macOS ships curl. Pass credentials and request bodies over stdin, never argv,
// environment variables, logs, or temporary files. Redirects are not followed.
fn quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
    )
}

pub async fn request(
    url: &str,
    method: &str,
    headers: &[(&str, String)],
    user: Option<&str>,
    body: Option<&Value>,
) -> Result<Value> {
    let parsed = url::Url::parse(url)?;
    ensure!(
        parsed.scheme() == "https"
            && parsed.host_str().is_some()
            && parsed.username().is_empty()
            && parsed.password().is_none(),
        "Expected an HTTPS API address"
    );
    let mut config = format!("url = {}\nrequest = {}\n", quote(url), quote(method));
    for (name, value) in headers {
        ensure!(
            !name.contains(['\n', '\r']) && !value.contains(['\n', '\r']),
            "Invalid HTTP header"
        );
        config.push_str(&format!(
            "header = {}\n",
            quote(&format!("{name}: {value}"))
        ));
    }
    if let Some(user) = user {
        config.push_str(&format!("user = {}\n", quote(user)));
    }
    if let Some(body) = body {
        config.push_str(&format!("data = {}\n", quote(&body.to_string())));
    }
    let raw = crate::cli::run_with_input(
        "/usr/bin/curl",
        [
            "--disable",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            "--config",
            "-",
            "--write-out",
            "\n%{http_code}",
        ],
        config.as_bytes(),
        Duration::from_secs(35),
        None,
    )
    .await?;
    let (body, status) = raw
        .rsplit_once('\n')
        .context("Missing HTTP response status")?;
    let status: u16 = status.parse()?;
    ensure!(
        (200..300).contains(&status),
        "API request failed with HTTP {status}"
    );
    if body.trim().is_empty() {
        Ok(Value::Null)
    } else {
        Ok(serde_json::from_str(body)?)
    }
}
