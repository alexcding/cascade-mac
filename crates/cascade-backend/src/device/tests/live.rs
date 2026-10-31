//! Against the installed Xcode: builds the vendored helper and runs its `--probe` under the
//! sandbox, as the backend does. Ignored by default; run it with
//! `cargo test device::tests::live -- --ignored --nocapture`.

use std::sync::Arc;

use crate::device::{
    cache::DEVICE_HELPER_SOURCE_FOLDER,
    helper::{methods, HelperClient, HelperClientOptions, HelperLaunch, REQUEST_TIMEOUT},
    ios_simulator::{IosSimulatorBackend, IosSimulatorOptions},
    sandbox::{opt_out_from_env, sandboxed_helper_command, HelperSandboxContext},
};

#[tokio::test(flavor = "multi_thread")]
#[ignore = "builds the helper with the installed Xcode, which takes a minute"]
async fn builds_the_vendored_helper_and_probes_it_under_the_sandbox() {
    let cache = tempfile::tempdir().unwrap();
    let mut options = IosSimulatorOptions::production();
    options.helper_cache_root = cache.path().to_path_buf();
    let backend: Arc<IosSimulatorBackend> = IosSimulatorBackend::new(options);

    let binary = backend.compile_helper_if_needed().await.expect("the helper builds");
    println!("built {}", binary.display());

    let developer_dir = std::env::var("DEVELOPER_DIR").ok().or_else(|| {
        std::process::Command::new("xcode-select")
            .arg("-p")
            .output()
            .ok()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    });
    let launch = sandboxed_helper_command(
        &[binary.to_string_lossy().into_owned(), "--probe".to_owned()],
        &HelperSandboxContext {
            binary_path: &binary,
            helper_source_dir: &binary.parent().unwrap().join(DEVICE_HELPER_SOURCE_FOLDER),
            developer_dir: developer_dir.as_deref(),
            opt_out: opt_out_from_env().as_deref(),
        },
    );
    assert!(launch.profile_path.is_some(), "the probe runs under the Seatbelt profile");
    let mut command = tokio::process::Command::new(&launch.command);
    command.args(&launch.args);
    if let Some(dir) = &developer_dir {
        command.env("DEVELOPER_DIR", dir);
    }
    let output = command.output().await.expect("the probe starts");
    println!("probe exit: {:?}", output.status.code());
    println!("probe stdout: {}", String::from_utf8_lossy(&output.stdout).trim());
    println!("probe stderr: {}", String::from_utf8_lossy(&output.stderr).trim());

    // The long-lived helper, through the client the backend uses: `ping` and `list` need no
    // booted device.
    let launch = sandboxed_helper_command(
        &[binary.to_string_lossy().into_owned()],
        &HelperSandboxContext {
            binary_path: &binary,
            helper_source_dir: &binary.parent().unwrap().join(DEVICE_HELPER_SOURCE_FOLDER),
            developer_dir: developer_dir.as_deref(),
            opt_out: opt_out_from_env().as_deref(),
        },
    );
    let client = HelperClient::new(HelperClientOptions {
        spawner: Arc::new(crate::chat::CliSpawner),
        launch: HelperLaunch {
            command: launch.command,
            args: launch.args,
            env: developer_dir.iter().map(|dir| ("DEVELOPER_DIR".to_owned(), dir.clone())).collect(),
            profile_path: launch.profile_path,
        },
        request_timeout: REQUEST_TIMEOUT,
        frames: tokio::sync::broadcast::channel(4).0,
        on_exit: None,
    });
    let ping = client.request(methods::PING, serde_json::Value::Null).await.expect("ping answers");
    println!("ping: {ping}");
    let list = client.request(methods::LIST, serde_json::Value::Null).await.expect("list answers");
    println!("list: {} devices", list["devices"].as_array().map_or(0, Vec::len));
    client.dispose().await;

    let availability = backend.availability().await;
    println!("availability: {}", serde_json::to_string(&availability).unwrap());
    backend.dispose().await;
}
