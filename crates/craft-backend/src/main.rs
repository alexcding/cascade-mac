use std::{env, net::Ipv4Addr, path::PathBuf};

use anyhow::{Context, Result};
use craft_backend::{build_app, recovery, shutdown_signal, AppState, Database};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .init();

    if recovery::run_command(&env::args_os().skip(1).collect::<Vec<_>>())? {
        return Ok(());
    }

    let port = env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(3000);
    let data_dir = env::var_os("CRAFT_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(default_data_dir);
    std::fs::create_dir_all(&data_dir)
        .with_context(|| format!("create data directory {}", data_dir.display()))?;
    // Hold ownership across checkpoint, schema opening, and the entire server life.
    // Recovery commands above never create/open application stores or start CLIs.
    let _native_lease = if env::var("CRAFT_PACKAGED").as_deref() == Ok("1") {
        Some(recovery::prepare_packaged(&data_dir)?)
    } else {
        None
    };
    // Reserve the port before opening stores or starting automation.
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
        .await
        .with_context(|| format!("bind 127.0.0.1:{port}"))?;
    let database = Database::open(&data_dir)?;
    let state = AppState::new(database, env::var("CRAFT_INSTANCE_ID").ok());
    state.poller.start(state.clone());
    let bound_port = listener.local_addr()?.port();
    let port_file = data_dir.join(".server-port");
    std::fs::write(&port_file, bound_port.to_string())
        .with_context(|| format!("write {}", port_file.display()))?;
    state.forwarders.start(state.clone(), bound_port);
    let app = build_app(state.clone());
    tracing::info!("Craft Rust backend running at http://127.0.0.1:{bound_port}");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("serve Craft backend")?;
    state.forwarders.stop().await;
    let _ = std::fs::remove_file(port_file);
    Ok(())
}

fn default_data_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library/Application Support/Craft")
}
