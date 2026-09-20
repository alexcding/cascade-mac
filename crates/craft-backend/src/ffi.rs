//! C ABI for hosting the backend inside a native app process.
//!
//! The native macOS app links this crate as a static library and dispatches its
//! API calls straight into the axum `Router` (no TCP hop, no child process), so
//! every route, model and contract stays exactly what the web client sees. A
//! loopback listener on an ephemeral port is still served for the things that
//! must reach the backend over HTTP: webhook forwarders, agent hooks and the
//! web renderer during development. Its port is published in `.server-port` as
//! before.
//!
//! Every entry point catches panics: unwinding across the boundary is undefined
//! behaviour and would take the host app down with it.
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    net::Ipv4Addr,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::Duration,
};

use axum::{
    body::Body,
    http::{header, HeaderValue, Method, Request},
    Router,
};
use tokio::{net::TcpListener, runtime::Runtime, sync::oneshot, task::JoinHandle};
use tower::ServiceExt;

use crate::{build_app, recovery, AppState, Database};

/// Receives one response per `craft_backend_request`, on a runtime thread.
/// `content_type` may be null; `body` is valid only for the duration of the call.
pub type ResponseCallback = Option<
    unsafe extern "C" fn(ctx: *mut c_void, status: i32, content_type: *const c_char, body: *const u8, len: usize),
>;
/// Receives one broadcast event (the JSON the SSE route would put in `data:`).
pub type EventCallback = Option<unsafe extern "C" fn(ctx: *mut c_void, json: *const u8, len: usize)>;
/// Called exactly once when a subscription ends, however it ends, so the host can
/// release `ctx`.
pub type DropCallback = Option<unsafe extern "C" fn(ctx: *mut c_void)>;

pub struct CraftBackend {
    runtime: Runtime,
    state: AppState,
    router: Router,
    port: u16,
    port_file: PathBuf,
    subscriptions: Mutex<HashMap<u64, JoinHandle<()>>>,
    next_subscription: AtomicU64,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
    server: Mutex<Option<JoinHandle<()>>>,
    _lease: Option<recovery::NativeLease>,
}

/// Raw host pointers are opaque tokens to us; the host promises they stay valid
/// until the matching callback has run (responses) or the drop callback fires.
#[derive(Clone, Copy)]
struct HostContext(*mut c_void);
unsafe impl Send for HostContext {}
unsafe impl Sync for HostContext {}
impl HostContext {
    // Closures must capture the whole wrapper (Send), never the raw field.
    fn ptr(self) -> *mut c_void {
        self.0
    }
}

struct SubscriptionGuard {
    ctx: HostContext,
    dropped: DropCallback,
}
impl Drop for SubscriptionGuard {
    fn drop(&mut self) {
        if let Some(dropped) = self.dropped {
            unsafe { dropped(self.ctx.ptr()) };
        }
    }
}

fn c_string(value: &str) -> CString {
    CString::new(value.replace('\0', " ")).expect("interior NUL removed")
}

unsafe fn write_error(out: *mut *mut c_char, message: String) {
    if !out.is_null() {
        *out = c_string(&message).into_raw();
    }
}

unsafe fn read_str<'a>(value: *const c_char) -> Result<&'a str, String> {
    if value.is_null() {
        return Err("null string".into());
    }
    CStr::from_ptr(value).to_str().map_err(|_| "string is not UTF-8".into())
}

fn start(data_dir: PathBuf, packaged: bool, instance_id: Option<String>) -> anyhow::Result<CraftBackend> {
    use anyhow::Context;
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .try_init();
    std::fs::create_dir_all(&data_dir)
        .with_context(|| format!("create data directory {}", data_dir.display()))?;
    let lease = if packaged { Some(recovery::prepare_packaged(&data_dir)?) } else { None };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("craft-backend")
        .build()
        .context("start the backend runtime")?;
    // Pollers and forwarders spawn onto the ambient runtime, as they do under main.rs.
    let _entered = runtime.enter();
    let listener = runtime
        .block_on(TcpListener::bind((Ipv4Addr::LOCALHOST, 0)))
        .context("bind a loopback port for webhooks and hooks")?;
    let port = listener.local_addr()?.port();
    let database = Database::open(&data_dir)?;
    let state = AppState::new(database, instance_id);
    state.poller.start(state.clone());
    let port_file = data_dir.join(".server-port");
    std::fs::write(&port_file, port.to_string())
        .with_context(|| format!("write {}", port_file.display()))?;
    state.forwarders.start(state.clone(), port);
    let router = build_app(state.clone());
    let (shutdown, stopped) = oneshot::channel::<()>();
    let served = router.clone();
    let server = runtime.spawn(async move {
        let _ = axum::serve(listener, served)
            .with_graceful_shutdown(async { let _ = stopped.await; })
            .await;
    });
    tracing::info!("Craft backend embedded; loopback listener at http://127.0.0.1:{port}");
    Ok(CraftBackend {
        runtime,
        state,
        router,
        port,
        port_file,
        subscriptions: Mutex::new(HashMap::new()),
        next_subscription: AtomicU64::new(1),
        shutdown: Mutex::new(Some(shutdown)),
        server: Mutex::new(Some(server)),
        _lease: lease,
    })
}

/// Starts the backend on `data_dir`. Returns 0 and writes the handle to `out`;
/// otherwise returns 1 and writes a message to `error` (free with
/// `craft_string_free`). `instance_id` may be null.
///
/// # Safety
/// `data_dir` and `instance_id` are NUL-terminated strings; `out` and `error`
/// are writable or null.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_start(
    data_dir: *const c_char,
    packaged: i32,
    instance_id: *const c_char,
    out: *mut *mut CraftBackend,
    error: *mut *mut c_char,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<CraftBackend, String> {
        let dir = PathBuf::from(read_str(data_dir)?);
        let instance = if instance_id.is_null() { None } else { Some(read_str(instance_id)?.to_owned()) };
        start(dir, packaged != 0, instance).map_err(|e| format!("{e:#}"))
    }));
    match result {
        Ok(Ok(backend)) => {
            if out.is_null() {
                drop(backend);
                write_error(error, "output handle pointer is null".into());
                return 1;
            }
            *out = Box::into_raw(Box::new(backend));
            0
        }
        Ok(Err(message)) => {
            write_error(error, message);
            1
        }
        Err(_) => {
            write_error(error, "the backend panicked while starting".into());
            1
        }
    }
}

/// The loopback port the embedded backend also serves on (webhooks, hooks, web UI).
///
/// # Safety
/// `backend` came from `craft_backend_start` and has not been stopped.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_port(backend: *const CraftBackend) -> u16 {
    if backend.is_null() { 0 } else { (*backend).port }
}

/// Owns the host's response callback until it has run exactly once. Dropped
/// undelivered (a request task discarded at stop), it answers 503 so the host
/// never waits on a reply that cannot come.
struct PendingResponse {
    ctx: HostContext,
    callback: unsafe extern "C" fn(*mut c_void, i32, *const c_char, *const u8, usize),
    delivered: bool,
}
impl PendingResponse {
    fn deliver(&mut self, status: i32, content_type: Option<CString>, bytes: Vec<u8>) {
        if self.delivered {
            return;
        }
        self.delivered = true;
        let callback = self.callback;
        let ctx = self.ctx;
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            callback(
                ctx.ptr(),
                status,
                content_type.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
                bytes.as_ptr(),
                bytes.len(),
            )
        }));
    }
}
impl Drop for PendingResponse {
    fn drop(&mut self) {
        if !self.delivered {
            let (status, kind, body) = error_response(503, "the backend stopped before answering");
            self.deliver(status, kind, body);
        }
    }
}

fn error_response(status: i32, message: &str) -> (i32, Option<CString>, Vec<u8>) {
    let body = serde_json::json!({ "error": message }).to_string().into_bytes();
    (status, Some(c_string("application/json")), body)
}

/// Dispatches one request into the router. `path_and_query` is the request
/// target (`/api/projects?x=1`); `body` may be null with `body_len` 0. The
/// callback runs exactly once, on a runtime thread, with the response.
///
/// # Safety
/// Strings are NUL-terminated and `body` is readable for `body_len` bytes for
/// the duration of this call (it is copied); `ctx` stays valid until the
/// callback has returned.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_request(
    backend: *const CraftBackend,
    method: *const c_char,
    path_and_query: *const c_char,
    body: *const u8,
    body_len: usize,
    ctx: *mut c_void,
    callback: ResponseCallback,
) {
    let Some(callback) = callback else { return };
    let mut pending = PendingResponse { ctx: HostContext(ctx), callback, delivered: false };
    let prepared = catch_unwind(AssertUnwindSafe(|| -> Result<(Method, String, Vec<u8>), String> {
        if backend.is_null() {
            return Err("backend handle is null".into());
        }
        let method = Method::from_bytes(read_str(method)?.as_bytes()).map_err(|e| e.to_string())?;
        let target = read_str(path_and_query)?.to_owned();
        if !target.starts_with('/') {
            return Err("request target must start with '/'".into());
        }
        let bytes = if body.is_null() || body_len == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(body, body_len).to_vec()
        };
        Ok((method, target, bytes))
    }));
    let (method, target, bytes) = match prepared {
        Ok(Ok(values)) => values,
        Ok(Err(message)) => {
            let (status, kind, body) = error_response(400, &message);
            return pending.deliver(status, kind, body);
        }
        Err(_) => {
            let (status, kind, body) = error_response(500, "the backend panicked while reading the request");
            return pending.deliver(status, kind, body);
        }
    };
    let backend = &*backend;
    let router = backend.router.clone();
    backend.runtime.spawn(async move {
        let mut pending = pending;
        let outcome = AssertUnwindSafe(async move {
            let mut request = Request::builder().method(method).uri(target);
            if !bytes.is_empty() {
                request = request.header(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
            }
            let request = request.body(Body::from(bytes)).map_err(|e| e.to_string())?;
            let response = router.oneshot(request).await.map_err(|e| e.to_string())?;
            let status = response.status().as_u16() as i32;
            let content_type = response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .map(c_string);
            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .map_err(|e| e.to_string())?;
            Ok::<_, String>((status, content_type, body.to_vec()))
        });
        match futures_util::FutureExt::catch_unwind(outcome).await {
            Ok(Ok((status, kind, body))) => pending.deliver(status, kind, body),
            Ok(Err(message)) => {
                let (status, kind, body) = error_response(500, &message);
                pending.deliver(status, kind, body)
            }
            Err(_) => {
                let (status, kind, body) = error_response(500, "the backend panicked while handling the request");
                pending.deliver(status, kind, body)
            }
        }
    });
}

/// Subscribes to broadcast events. Returns a subscription id (never 0) or 0 on
/// failure. `dropped` runs exactly once when the subscription ends: after
/// `craft_backend_unsubscribe`, at `craft_backend_stop`, or if the event
/// channel closes.
///
/// # Safety
/// `ctx` stays valid until `dropped` has run.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_subscribe(
    backend: *const CraftBackend,
    ctx: *mut c_void,
    callback: EventCallback,
    dropped: DropCallback,
) -> u64 {
    let (Some(callback), false) = (callback, backend.is_null()) else {
        if let Some(dropped) = dropped {
            dropped(ctx);
        }
        return 0;
    };
    let backend = &*backend;
    let ctx = HostContext(ctx);
    let mut receiver = backend.state.events.subscribe();
    let id = backend.next_subscription.fetch_add(1, Ordering::Relaxed);
    // Built outside the future: a task aborted before its first poll drops its
    // captures without running its body, and the host must still get `dropped`.
    let guard = SubscriptionGuard { ctx, dropped };
    let task = backend.runtime.spawn(async move {
        let _guard = guard;
        loop {
            match receiver.recv().await {
                Ok(value) => {
                    let json = value.to_string();
                    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
                        callback(ctx.ptr(), json.as_ptr(), json.len())
                    }));
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    backend.subscriptions.lock().unwrap().insert(id, task);
    id
}

/// Ends a subscription; its `dropped` callback fires shortly after (asynchronously).
///
/// # Safety
/// `backend` came from `craft_backend_start` and has not been stopped.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_unsubscribe(backend: *const CraftBackend, id: u64) {
    if backend.is_null() {
        return;
    }
    if let Some(task) = (*backend).subscriptions.lock().unwrap().remove(&id) {
        task.abort();
    }
}

/// Stops forwarders, the loopback listener and every subscription, then frees
/// the handle. The handle must not be used afterwards.
///
/// # Safety
/// `backend` came from `craft_backend_start` and is stopped exactly once.
#[no_mangle]
pub unsafe extern "C" fn craft_backend_stop(backend: *mut CraftBackend) {
    if backend.is_null() {
        return;
    }
    let backend = Box::from_raw(backend);
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let subscriptions: Vec<_> = backend.subscriptions.lock().unwrap().drain().map(|(_, task)| task).collect();
        for task in &subscriptions {
            task.abort();
        }
        if let Some(shutdown) = backend.shutdown.lock().unwrap().take() {
            let _ = shutdown.send(());
        }
        let state = backend.state.clone();
        let server = backend.server.lock().unwrap().take();
        backend.runtime.block_on(async move {
            // Awaiting an aborted task guarantees its future (and the host
            // context guard) is dropped before the host sees stop() return.
            for task in subscriptions {
                let _ = task.await;
            }
            state.forwarders.stop().await;
            if let Some(server) = server {
                let _ = tokio::time::timeout(Duration::from_secs(2), server).await;
            }
        });
        let _ = std::fs::remove_file(&backend.port_file);
    }));
    let CraftBackend { runtime, .. } = *backend;
    runtime.shutdown_timeout(Duration::from_secs(2));
}

/// Frees a string returned through an `error` out-parameter.
///
/// # Safety
/// `value` came from this library and is freed once.
#[no_mangle]
pub unsafe extern "C" fn craft_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    struct Reply {
        status: i32,
        content_type: Option<String>,
        body: String,
    }

    unsafe extern "C" fn on_response(ctx: *mut c_void, status: i32, content_type: *const c_char, body: *const u8, len: usize) {
        let sender = &*(ctx as *const mpsc::Sender<Reply>);
        let content_type = if content_type.is_null() { None } else { Some(CStr::from_ptr(content_type).to_string_lossy().into_owned()) };
        let body = String::from_utf8_lossy(std::slice::from_raw_parts(body, len)).into_owned();
        sender.send(Reply { status, content_type, body }).unwrap();
    }
    unsafe extern "C" fn on_event(ctx: *mut c_void, json: *const u8, len: usize) {
        let sender = &*(ctx as *const mpsc::Sender<String>);
        sender.send(String::from_utf8_lossy(std::slice::from_raw_parts(json, len)).into_owned()).unwrap();
    }
    static DROPS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    unsafe extern "C" fn on_dropped(ctx: *mut c_void) {
        drop(Box::from_raw(ctx as *mut mpsc::Sender<String>));
        DROPS.fetch_add(1, Ordering::SeqCst);
    }

    fn call(backend: *const CraftBackend, method: &str, target: &str, body: &str) -> Reply {
        let (sender, receiver) = mpsc::channel();
        let sender = Box::new(sender);
        let method = CString::new(method).unwrap();
        let target = CString::new(target).unwrap();
        unsafe {
            craft_backend_request(
                backend,
                method.as_ptr(),
                target.as_ptr(),
                body.as_ptr(),
                body.len(),
                &*sender as *const _ as *mut c_void,
                Some(on_response),
            );
        }
        receiver.recv_timeout(Duration::from_secs(10)).expect("response")
    }

    fn start_temp() -> (*mut CraftBackend, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let instance = CString::new("test-instance").unwrap();
        let mut handle: *mut CraftBackend = std::ptr::null_mut();
        let mut error: *mut c_char = std::ptr::null_mut();
        let code = unsafe { craft_backend_start(path.as_ptr(), 0, instance.as_ptr(), &mut handle, &mut error) };
        assert_eq!(code, 0, "start failed: {}", unsafe { CStr::from_ptr(error).to_string_lossy() });
        assert!(!handle.is_null());
        (handle, dir)
    }

    #[test]
    fn dispatches_requests_in_process_and_serves_a_loopback_port() {
        let (backend, dir) = start_temp();
        let port = unsafe { craft_backend_port(backend) };
        assert!(port > 0);
        assert_eq!(std::fs::read_to_string(dir.path().join(".server-port")).unwrap(), port.to_string());

        let health = call(backend, "GET", "/api/backend/health", "");
        assert_eq!(health.status, 200);
        assert_eq!(health.content_type.as_deref(), Some("application/json"));
        let value: serde_json::Value = serde_json::from_str(&health.body).unwrap();
        assert_eq!(value["service"], "craft");
        assert_eq!(value["instanceId"], "test-instance");
        assert_eq!(value["pid"], std::process::id());

        let projects = call(backend, "GET", "/api/projects", "");
        assert_eq!((projects.status, projects.body.as_str()), (200, "[]"));

        let created = call(backend, "POST", "/api/tabs", r#"{"url":"https://example.com/","kind":"web"}"#);
        assert!(created.status < 500, "{}", created.body);
        let created: serde_json::Value = serde_json::from_str(&created.body).unwrap();
        let id = created["tabs"][0]["id"].as_str().unwrap();
        let closed = call(backend, "DELETE", "/api/tabs", &format!(r#"{{"id":"{id}"}}"#));
        assert_eq!(closed.status, 200, "{}", closed.body);
        let closed: serde_json::Value = serde_json::from_str(&closed.body).unwrap();
        assert_eq!(closed["tabs"], serde_json::json!([]));
        let missing_url = call(backend, "DELETE", "/api/tabs", "{}");
        assert_eq!(missing_url.status, 400);

        let bad = call(backend, "GET", "/api/projects/missing", "");
        assert_eq!(bad.status, 404);
        let invalid = call(backend, "BOGUS METHOD", "/api/projects", "");
        assert_eq!(invalid.status, 400);
        let relative = call(backend, "GET", "api/projects", "");
        assert_eq!(relative.status, 400);

        // The loopback listener serves the same router for webhook forwarders.
        let over_tcp = std::net::TcpStream::connect(("127.0.0.1", port)).map(|mut s| {
            use std::io::{Read, Write};
            s.write_all(b"GET /api/backend/health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).unwrap();
            out
        });
        assert!(over_tcp.unwrap().contains("\"service\":\"craft\""));

        // A request still queued when the backend stops is answered, not dropped.
        let (sender, receiver) = mpsc::channel::<Reply>();
        let sender = Box::new(sender);
        let (method, target) = (CString::new("GET").unwrap(), CString::new("/api/projects").unwrap());
        unsafe {
            craft_backend_request(backend, method.as_ptr(), target.as_ptr(), std::ptr::null(), 0,
                                    &*sender as *const _ as *mut c_void, Some(on_response));
            craft_backend_stop(backend);
        }
        let late = receiver.recv_timeout(Duration::from_secs(5)).expect("queued request answered at stop");
        assert!(late.status == 200 || late.status == 503, "{}", late.body);
        assert!(!dir.path().join(".server-port").exists());
    }

    #[test]
    fn subscriptions_deliver_broadcasts_and_release_their_context() {
        let (backend, _dir) = start_temp();
        let (sender, receiver) = mpsc::channel::<String>();
        let ctx = Box::into_raw(Box::new(sender)) as *mut c_void;
        let drops = DROPS.load(Ordering::SeqCst);
        let id = unsafe { craft_backend_subscribe(backend, ctx, Some(on_event), Some(on_dropped)) };
        assert!(id > 0);
        // Give the subscriber task a moment to attach before broadcasting.
        std::thread::sleep(Duration::from_millis(50));
        unsafe { (*backend).state.broadcast(serde_json::json!({"type":"test","projectId":"p1"})) };
        let event = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&event).unwrap()["type"], "test");

        unsafe { craft_backend_unsubscribe(backend, id) };
        // Dropping the guard frees the sender; the receiver then disconnects.
        assert_released(&receiver, drops + 1);

        // A subscription still open at stop is released the same way.
        let (sender, receiver) = mpsc::channel::<String>();
        let ctx = Box::into_raw(Box::new(sender)) as *mut c_void;
        let drops = DROPS.load(Ordering::SeqCst);
        assert!(unsafe { craft_backend_subscribe(backend, ctx, Some(on_event), Some(on_dropped)) } > 0);
        unsafe { craft_backend_stop(backend) };
        assert_released(&receiver, drops + 1);
    }

    // The release is the drop callback firing (it runs on a runtime thread);
    // pollers and forwarders may still broadcast while shutting down.
    fn assert_released(receiver: &mpsc::Receiver<String>, expected: usize) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while std::time::Instant::now() < deadline {
            if DROPS.load(Ordering::SeqCst) >= expected {
                return;
            }
            let _ = receiver.recv_timeout(Duration::from_millis(20));
        }
        panic!("subscription context was not released: drops={} expected={expected}", DROPS.load(Ordering::SeqCst));
    }

    // The C header the app compiles against is written by hand; every exported
    // function must be declared there under the same name.
    #[test]
    fn the_swift_header_declares_every_exported_function() {
        let source = include_str!("ffi.rs");
        let header = include_str!("../../../macos/Vendor/CraftBackend/craft_backend.h");
        let exported: Vec<&str> = source
            .split("#[no_mangle]\npub unsafe extern \"C\" fn ")
            .skip(1)
            .map(|rest| rest.split('(').next().unwrap())
            .collect();
        assert_eq!(exported.len(), 7, "{exported:?}");
        for name in exported {
            assert!(header.contains(&format!(" {name}(")), "{name} is missing from craft_backend.h");
        }
    }

    #[test]
    fn start_reports_errors_instead_of_panicking() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let path = CString::new(file.path().to_str().unwrap()).unwrap();
        let mut handle: *mut CraftBackend = std::ptr::null_mut();
        let mut error: *mut c_char = std::ptr::null_mut();
        let code = unsafe { craft_backend_start(path.as_ptr(), 0, std::ptr::null(), &mut handle, &mut error) };
        assert_eq!(code, 1);
        assert!(handle.is_null());
        assert!(!error.is_null());
        assert!(unsafe { CStr::from_ptr(error) }.to_string_lossy().contains("create data directory"));
        unsafe { craft_string_free(error) };
    }
}
