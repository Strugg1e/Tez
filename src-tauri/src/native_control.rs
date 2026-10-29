use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tauri_plugin_mihomo::models::ProxyType;

use crate::{
    cmd::{CmdResult, CommandFailure, proxy_aware_coded_error},
    config::Config,
    core::{
        CoreManager,
        handle::Handle,
        manager::RunningMode,
        proxy_view::{ProxyGroupView, ProxyMemberRef, ProxyViewV1},
        service::SERVICE_MANAGER,
    },
};

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct RouteParams {
    pub(crate) group: String,
    pub(crate) name: String,
}

#[derive(Debug, PartialEq, Eq)]
enum Request {
    Select(RouteParams),
    CloseConnection(String),
    Start,
    Stop,
    Restart,
    Runtime,
}

fn parse_request(command: &str, params: Value) -> CmdResult<Request> {
    if command == "native_close_connection" {
        return parse_connection_id(params).map(Request::CloseConnection);
    }
    if command == "native_select_route" {
        let route: RouteParams =
            serde_json::from_value(params).map_err(|error| CommandFailure::coded("INVALID_PARAMS", error))?;
        if route.group.trim().is_empty() || route.name.trim().is_empty() {
            return Err(CommandFailure::coded(
                "INVALID_PARAMS",
                "group and name must not be empty",
            ));
        }
        return Ok(Request::Select(route));
    }
    let request = match command {
        "native_core_start" => Request::Start,
        "native_core_stop" => Request::Stop,
        "native_core_restart" => Request::Restart,
        "native_get_runtime" => Request::Runtime,
        _ => {
            return Err(CommandFailure::coded(
                "UNKNOWN_COMMAND",
                "Unknown native control command",
            ));
        }
    };
    if !params.as_object().is_some_and(serde_json::Map::is_empty) {
        return Err(CommandFailure::coded(
            "INVALID_PARAMS",
            "This command requires an empty object",
        ));
    }
    Ok(request)
}

pub(crate) fn parse_connection_id(params: Value) -> CmdResult<String> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Close { id: String }
    let request: Close = serde_json::from_value(params)
        .map_err(|_| CommandFailure::coded("INVALID_PARAMS", "Expected a single connection ID"))?;
    if request.id.is_empty() || request.id.len() > 128
        || !request.id.bytes().all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, b'-' | b'_')) {
        return Err(CommandFailure::coded("INVALID_PARAMS", "Invalid connection ID"));
    }
    Ok(request.id)
}

pub(crate) async fn close_connection(client: &tauri_plugin_mihomo::Mihomo, id: &str) -> CmdResult<Value> {
    tokio::time::timeout(std::time::Duration::from_secs(3), client.close_connection(id)).await
        .map_err(|_| CommandFailure::coded("CONNECTION_CLOSE_FAILED", "Connection close timed out"))?
        .map_err(|_| CommandFailure::coded("CONNECTION_CLOSE_FAILED", "Cannot close the selected connection"))?;
    Ok(json!({"closed": true, "id": id}))
}

pub(crate) fn validate_route<'a>(view: &'a ProxyViewV1, route: &RouteParams) -> CmdResult<&'a ProxyGroupView> {
    let group = view
        .groups
        .iter()
        .chain(view.global.iter())
        .find(|group| group.name == route.group)
        .ok_or_else(|| CommandFailure::coded("INVALID_ROUTE", "Proxy group does not exist"))?;
    if !matches!(
        group.proxy_type,
        ProxyType::Selector | ProxyType::URLTest | ProxyType::Fallback
    ) {
        return Err(CommandFailure::coded(
            "INVALID_ROUTE",
            "Proxy group does not support manual selection",
        ));
    }
    let mut matches = group.members.iter().filter(|member| match member {
        ProxyMemberRef::Group { name }
        | ProxyMemberRef::Node { name, .. }
        | ProxyMemberRef::Unresolved { name, .. } => name == &route.name,
    });
    let member = matches.next();
    if matches.next().is_some() || matches!(member, Some(ProxyMemberRef::Unresolved { .. })) {
        return Err(CommandFailure::coded(
            "INVALID_ROUTE",
            "Proxy member identity is ambiguous or unavailable",
        ));
    }
    if member.is_none() {
        return Err(CommandFailure::coded(
            "INVALID_ROUTE",
            "Proxy is not a member of this group",
        ));
    }
    Ok(group)
}

pub(crate) async fn finish_selection<F, Fut>(name: &str, persist: F) -> Value
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = CmdResult<()>>,
{
    match persist().await {
        Ok(()) => json!({"applied": true, "persisted": true, "selected": name}),
        Err(failure) => json!({"applied": true, "persisted": false, "selected": name, "failure": failure}),
    }
}

#[derive(Debug, Serialize)]
struct ConnectionCleanup {
    requested: bool,
    completed: bool,
    closed: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure: Option<CommandFailure>,
}

async fn apply_route_selection<Guard>(
    client: &tauri_plugin_mihomo::Mihomo,
    route: &RouteParams,
    previous_proxy: Option<&str>,
    auto_close: bool,
    ensure_ready: Guard,
) -> CmdResult<ConnectionCleanup>
where
    Guard: Fn() -> CmdResult<()>,
{
    ensure_ready()?;
    client
        .select_node_for_group(&route.group, &route.name)
        .await
        .map_err(|error| CommandFailure::coded("ROUTE_SELECT_FAILED", format_args!("{error:#}")))?;
    let previous_proxy = previous_proxy.filter(|previous| !previous.is_empty() && *previous != route.name);
    let mut cleanup = ConnectionCleanup {
        requested: auto_close && previous_proxy.is_some(),
        completed: false,
        closed: 0,
        failure: None,
    };
    if !cleanup.requested {
        return Ok(cleanup);
    }
    let connections = async {
        ensure_ready()?;
        tokio::time::timeout(std::time::Duration::from_secs(3), client.get_connections()).await
            .map_err(|_| CommandFailure::coded("CONNECTION_CLEANUP_FAILED", "Reading connections timed out"))?
            .map_err(|_| CommandFailure::coded("CONNECTION_CLEANUP_FAILED", "Cannot read connections after route selection"))
    }.await;
    let connections = match connections {
        Ok(connections) => connections,
        Err(failure) => {
            cleanup.failure = Some(failure);
            return Ok(cleanup);
        }
    };
    for connection in connections.connections.unwrap_or_default() {
        // Chains run from the exit to outer groups; match this group's direct choice.
        if !connection.chains.windows(2).any(|pair| {
            Some(pair[0].as_str()) == previous_proxy && pair[1] == route.group
        }) {
            continue;
        }
        if let Err(failure) = ensure_ready() {
            cleanup.failure.get_or_insert(failure);
            break;
        }
        match close_connection(client, &connection.id).await {
            Ok(_) => cleanup.closed += 1,
            Err(failure) => { cleanup.failure.get_or_insert(failure); }
        }
    }
    cleanup.completed = cleanup.failure.is_none();
    Ok(cleanup)
}

async fn select_route(route: RouteParams) -> CmdResult<Value> {
    let manager = CoreManager::global();
    let generation = manager.current_core_readiness_generation();
    ownership_guard(
        &Request::Select(RouteParams {
            group: route.group.clone(),
            name: route.name.clone(),
        }),
        *manager.get_running_mode(),
        generation.is_some(),
    )?;
    let view = crate::cmd::get_proxy_view().await?;
    let previous_proxy = validate_route(&view, &route)?.now.as_deref();
    let auto_close = Config::verge().await.latest_arc().auto_close_connection.unwrap_or(false);
    let ensure_ready = || {
        if manager.current_core_readiness_generation() != generation
            || matches!(*manager.get_running_mode(), RunningMode::NotRunning)
        {
            return Err(CommandFailure::coded(
                "CORE_NOT_READY",
                "Owned core changed while selecting a route",
            ));
        }
        Ok(())
    };
    ensure_ready()?;
    // A background profile activation must not overwrite this newer runtime choice.
    crate::config::profiles::supersede_selected_activation();
    let cleanup = apply_route_selection(&Handle::mihomo(), &route, previous_proxy, auto_close, ensure_ready).await?;
    Handle::refresh_clash();
    let mut result = finish_selection(&route.name, || async {
        crate::config::profiles::record_selected_node(&route.group, &route.name)
            .await
            .map_err(|error| CommandFailure::plain(format_args!("{error:#}")))?;
        // record_selected_node deliberately does nothing when there is no current profile.
        let profiles = Config::profiles().await.data_arc();
        let saved = profiles.current.as_ref().is_some_and(|current| {
            profiles.items.as_ref().is_some_and(|items| {
                items.iter().any(|item| {
                    item.uid.as_ref() == Some(current)
                        && item.selected.as_ref().is_some_and(|selected| {
                            selected.iter().any(|entry| {
                                entry.name.as_deref() == Some(route.group.as_str())
                                    && entry.now.as_deref() == Some(route.name.as_str())
                            })
                        })
                })
            })
        });
        if !saved {
            return Err(CommandFailure::coded(
                "ROUTE_PERSIST_FAILED",
                "Selection has no saved current profile",
            ));
        }
        Ok(())
    })
    .await;
    result["connectionCleanup"] = json!(cleanup);
    Ok(result)
}

/// Called only by the exclusively owned, initialized managed backend, never attach mode.
pub async fn dispatch(command: &str, params: Value) -> CmdResult<Value> {
    dispatch_with(command, params, dispatch_request).await
}

async fn dispatch_with<F, Fut>(command: &str, params: Value, execute: F) -> CmdResult<Value>
where
    F: FnOnce(Request) -> Fut,
    Fut: std::future::Future<Output = CmdResult<Value>>,
{
    execute(parse_request(command, params)?).await
}

async fn dispatch_request(request: Request) -> CmdResult<Value> {
    let manager = CoreManager::global();
    dispatch_owned_with(
        request,
        *manager.get_running_mode(),
        manager.current_core_readiness_generation().is_some(),
        dispatch_owned_request,
        runtime,
    )
    .await
}

fn ownership_guard(request: &Request, mode: RunningMode, ready: bool) -> CmdResult<bool> {
    let running = !matches!(mode, RunningMode::NotRunning);
    match request {
        Request::Select(_) | Request::CloseConnection(_) | Request::Restart if !running => {
            Err(CommandFailure::coded("CORE_NOT_RUNNING", "No owned core is running"))
        }
        Request::Select(_) | Request::CloseConnection(_) if !ready => Err(CommandFailure::coded("CORE_NOT_READY", "Owned core is not ready")),
        Request::Stop if !running => Ok(false),
        Request::Start if running => {
            verify_started(mode, ready)?;
            Ok(false)
        },
        _ => Ok(true),
    }
}

async fn dispatch_owned_with<Execute, ExecuteFuture, Snapshot, SnapshotFuture>(
    request: Request,
    mode: RunningMode,
    ready: bool,
    execute: Execute,
    snapshot: Snapshot,
) -> CmdResult<Value>
where
    Execute: FnOnce(Request) -> ExecuteFuture,
    ExecuteFuture: std::future::Future<Output = CmdResult<Value>>,
    Snapshot: FnOnce() -> SnapshotFuture,
    SnapshotFuture: std::future::Future<Output = CmdResult<Value>>,
{
    if ownership_guard(&request, mode, ready)? {
        execute(request).await
    } else {
        snapshot().await
    }
}

async fn dispatch_owned_request(request: Request) -> CmdResult<Value> {
    let (result, code) = match request {
        Request::Select(route) => return select_route(route).await,
        Request::CloseConnection(id) => return close_connection(&Handle::mihomo(), &id).await,
        Request::Runtime => return runtime().await,
        Request::Start => (
            run_prepared(prepare_runtime, || CoreManager::global().start_core()).await,
            "CORE_START_FAILED",
        ),
        Request::Stop => (CoreManager::global().stop_core().await, "CORE_STOP_FAILED"),
        Request::Restart => (
            run_prepared(prepare_runtime, || CoreManager::global().restart_core()).await,
            "CORE_RESTART_FAILED",
        ),
    };
    // Even a failed transition can have changed the running core or system proxy.
    let state = runtime().await;
    result.map_err(|error| proxy_aware_coded_error(&error, code))?;
    if code == "CORE_START_FAILED" || code == "CORE_RESTART_FAILED" {
        verify_started(*CoreManager::global().get_running_mode(), CoreManager::global().current_core_readiness_generation().is_some())?;
        crate::core::timer::Timer::global().init().await
            .map_err(|_| CommandFailure::coded("SUBSCRIPTION_TIMER_FAILED", "Core is running, but subscription scheduling failed"))?;
    }
    state
}

fn verify_started(mode: RunningMode, ready: bool) -> CmdResult<()> {
    if !matches!(mode, RunningMode::NotRunning) && ready {
        return Ok(());
    }
    Err(CommandFailure::coded("CORE_START_NOT_READY", "The owned core did not become ready. Check service availability and configuration before retrying."))
}

async fn prepare_runtime() -> anyhow::Result<()> {
    static PREPARATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _preparation = PREPARATION.lock().await;
    if Config::runtime().await.data_arc().config.is_some() {
        return Ok(());
    }
    // Initial generation must never replace the configuration of a running core.
    anyhow::ensure!(
        matches!(*CoreManager::global().get_running_mode(), RunningMode::NotRunning),
        "cannot initialize runtime configuration while a core is running"
    );
    SERVICE_MANAGER.detect_startup_status().await;
    Config::init_config_before_window().await?;
    Config::init_runtime_config().await
}

async fn run_prepared<Prepare, PrepareFuture, Execute, ExecuteFuture>(
    prepare: Prepare,
    execute: Execute,
) -> anyhow::Result<()>
where
    Prepare: FnOnce() -> PrepareFuture,
    PrepareFuture: std::future::Future<Output = anyhow::Result<()>>,
    Execute: FnOnce() -> ExecuteFuture,
    ExecuteFuture: std::future::Future<Output = anyhow::Result<()>>,
{
    prepare().await?;
    execute().await
}

async fn runtime() -> CmdResult<Value> {
    let state = crate::cmd::get_runtime_state().await.map_err(CommandFailure::plain)?;
    serde_json::to_value(state).map_err(CommandFailure::plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_start_requires_confirmed_owned_readiness() {
        for (mode, ready) in [(RunningMode::NotRunning, false), (RunningMode::NotRunning, true), (RunningMode::Service, false)] {
            assert_eq!(verify_started(mode, ready).unwrap_err().code.as_deref(), Some("CORE_START_NOT_READY"));
        }
        assert!(verify_started(RunningMode::Service, true).is_ok());
        assert!(verify_started(RunningMode::Sidecar, true).is_ok());
        assert!(ownership_guard(&Request::Start, RunningMode::Service, false).is_err());
    }

    #[test]
    fn control_parameters_are_strict_before_backend_access() {
        for id in ["", "..", "a/b", "a?all=true", "a#b", "a%2fb", "a b", "*"] {
            assert!(parse_request("native_close_connection", json!({"id":id})).is_err());
        }
        assert!(parse_request("native_close_connection", json!({"id":"connection-1","all":true})).is_err());
        assert_eq!(parse_request("native_close_connection", json!({"id":"connection-1"})).unwrap(),
            Request::CloseConnection("connection-1".into()));
        for command in [
            "native_core_start",
            "native_core_stop",
            "native_core_restart",
            "native_get_runtime",
        ] {
            assert!(parse_request(command, json!({})).is_ok());
            for params in [Value::Null, json!([]), json!({"extra": true})] {
                assert!(parse_request(command, params).is_err());
            }
        }
        for params in [
            json!({}),
            json!({"group": "g", "name": " "}),
            json!({"group": "g", "name": "n", "extra": 1}),
        ] {
            assert!(parse_request("native_select_route", params).is_err());
        }
        assert!(parse_request("native_select_route", json!({"group": "g", "name": "n"})).is_ok());
        assert_eq!(
            parse_request("unknown", json!({}))
                .err()
                .and_then(|error| error.code)
                .as_deref(),
            Some("UNKNOWN_COMMAND")
        );
    }

    #[tokio::test]
    async fn persistence_failure_preserves_the_applied_selection() {
        let result = finish_selection("node", || async { Err(CommandFailure::plain("disk full")) }).await;
        assert_eq!(
            result,
            json!({"applied": true, "persisted": false, "selected": "node", "failure": {"detail": "disk full"}})
        );
        let result = finish_selection("node", || async { Ok(()) }).await;
        assert_eq!(result, json!({"applied": true, "persisted": true, "selected": "node"}));
    }

    #[tokio::test]
    async fn invalid_dispatch_never_calls_backend() {
        let called = std::cell::Cell::new(false);
        let result = dispatch_with("native_core_stop", json!({"force": true}), |_| async {
            called.set(true);
            Ok(Value::Null)
        })
        .await;
        assert!(result.is_err());
        assert!(!called.get());
        let result = dispatch_with("native_core_restart", json!({}), |request| async move {
            assert_eq!(request, Request::Restart);
            Ok(json!({"runtime": "injected"}))
        })
        .await;
        assert_eq!(result.ok(), Some(json!({"runtime": "injected"})));
    }

    #[tokio::test]
    async fn preparation_precedes_lifecycle_and_failure_prevents_start() {
        let calls = std::cell::RefCell::new(Vec::new());
        let result = run_prepared(
            || async {
                calls.borrow_mut().push("prepare");
                Ok(())
            },
            || async {
                calls.borrow_mut().push("start");
                Ok(())
            },
        )
        .await;
        assert!(result.is_ok());
        assert_eq!(*calls.borrow(), ["prepare", "start"]);

        calls.borrow_mut().clear();
        let result = run_prepared(
            || async {
                calls.borrow_mut().push("prepare");
                anyhow::bail!("configuration unavailable")
            },
            || async {
                calls.borrow_mut().push("unexpected-start");
                Ok(())
            },
        )
        .await;
        assert!(result.is_err());
        assert_eq!(*calls.borrow(), ["prepare"]);
    }

    #[tokio::test]
    async fn ownership_guards_do_not_call_mutating_backend_for_unowned_core() {
        for request in [
            Request::Stop,
            Request::Restart,
            Request::CloseConnection("connection-1".into()),
            Request::Select(RouteParams {
                group: "g".into(),
                name: "n".into(),
            }),
        ] {
            let is_stop = request == Request::Stop;
            let calls = std::cell::Cell::new(0);
            let result = dispatch_owned_with(
                request,
                RunningMode::NotRunning,
                false,
                |_| async {
                    calls.set(calls.get() + 1);
                    Ok(Value::Null)
                },
                || async { Ok(json!({"mode": "NotRunning"})) },
            )
            .await;
            assert_eq!(calls.get(), 0);
            assert_eq!(result.is_ok(), is_stop);
        }
        assert_eq!(ownership_guard(&Request::Start, RunningMode::Sidecar, true), Ok(false));
        assert!(ownership_guard(&Request::CloseConnection("connection-1".into()), RunningMode::Sidecar, false).is_err());
        assert!(
            ownership_guard(
                &Request::Select(RouteParams {
                    group: "g".into(),
                    name: "n".into()
                }),
                RunningMode::Sidecar,
                false,
            )
            .is_err()
        );
    }

    #[cfg(unix)]
    struct RouteController {
        client: tauri_plugin_mihomo::Mihomo,
        path: std::path::PathBuf,
        requests: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
        task: tokio::task::JoinHandle<()>,
    }

    #[cfg(unix)]
    impl RouteController {
        fn new(select_status: u16, close_status: u16) -> Self {
            Self::with_connections(select_status, close_status, json!({"connections":[
                {"id":"target-1","chains":["Old","Group"]},
                {"id":"other-group","chains":["Old","Other"]},
                {"id":"new-route","chains":["New","Group"]},
                {"id":"new-nested-route","chains":["Old","New","Group"]},
                {"id":"unrelated","chains":["DIRECT"]}
            ]}))
        }

        fn with_connections(select_status: u16, close_status: u16, connections: Value) -> Self {
            use tauri_plugin_mihomo::{Mihomo, MihomoContext, models::Protocol};
            use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

            let path = std::env::temp_dir().join(format!("tez-route-{}.sock", nanoid::nanoid!(8)));
            let listener = tokio::net::UnixListener::bind(&path).unwrap();
            let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
            let observed = requests.clone();
            let task = tokio::spawn(async move {
                loop {
                    let (mut socket, _) = listener.accept().await.unwrap();
                    let mut headers = Vec::new();
                    let mut byte = [0];
                    while !headers.ends_with(b"\r\n\r\n") {
                        assert_eq!(socket.read(&mut byte).await.unwrap(), 1);
                        headers.push(byte[0]);
                        assert!(headers.len() < 4096);
                    }
                    let headers = std::str::from_utf8(&headers).unwrap();
                    let request = headers.lines().next().unwrap();
                    observed.lock().unwrap().push(request.to_owned());
                    let length = headers.lines().find_map(|line| {
                        line.split_once(':').filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                            .map(|(_, value)| value.trim().parse::<usize>().unwrap())
                    }).unwrap_or(0);
                    let mut body = vec![0; length];
                    socket.read_exact(&mut body).await.unwrap();
                    let (status, body) = if request.starts_with("PUT /proxies/Group ") {
                        assert_eq!(serde_json::from_slice::<Value>(&body).unwrap(), json!({"name":"New"}));
                        (select_status, json!({"message":"selection failed"}).to_string())
                    } else if request == "GET /connections HTTP/1.1" {
                        (200, connections.to_string())
                    } else {
                        (close_status, json!({"message":"close failed"}).to_string())
                    };
                    socket.write_all(format!("HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
                }
            });
            let socket = path.to_string_lossy().to_string();
            let http = MihomoContext::build_client(&Protocol::LocalSocket, Some(&socket)).unwrap();
            let client = Mihomo::new(MihomoContext::new(Protocol::LocalSocket, None, None, None, Some(socket), std::time::Duration::from_secs(3), http));
            Self { client, path, requests, task }
        }

        fn requests(&self) -> Vec<String> {
            self.requests.lock().unwrap().clone()
        }
    }

    #[cfg(unix)]
    impl Drop for RouteController {
        fn drop(&mut self) {
            self.task.abort();
            std::fs::remove_file(&self.path).unwrap();
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn route_switch_closes_only_connections_using_the_previous_route_in_its_group() {
        let controller = RouteController::new(204, 204);
        let route = RouteParams { group: "Group".into(), name: "New".into() };
        let cleanup = apply_route_selection(&controller.client, &route, Some("Old"), true, || Ok(())).await.unwrap();
        assert_eq!(json!(cleanup), json!({"requested":true,"completed":true,"closed":1}));
        assert_eq!(controller.requests(), [
            "PUT /proxies/Group HTTP/1.1",
            "GET /connections HTTP/1.1",
            "DELETE /connections/target-1 HTTP/1.1",
        ]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn route_switch_matches_the_previous_selected_group_inside_outer_chains() {
        let controller = RouteController::with_connections(204, 204, json!({"connections":[
            {"id":"target-1","chains":["Exit","OldGroup","Group","Outer"]},
            {"id":"other-group","chains":["Exit","OldGroup","Other","Outer"]},
            {"id":"new-nested-route","chains":["Exit","OldGroup","New","Group","Outer"]}
        ]}));
        let route = RouteParams { group: "Group".into(), name: "New".into() };
        let cleanup = apply_route_selection(&controller.client, &route, Some("OldGroup"), true, || Ok(())).await.unwrap();
        assert_eq!(json!(cleanup), json!({"requested":true,"completed":true,"closed":1}));
        assert_eq!(controller.requests(), [
            "PUT /proxies/Group HTTP/1.1",
            "GET /connections HTTP/1.1",
            "DELETE /connections/target-1 HTTP/1.1",
        ]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn route_switch_preserves_connections_when_cleanup_is_disabled_or_no_route_changed() {
        for (auto_close, previous) in [(false, Some("Old")), (true, Some("New")), (true, None)] {
            let controller = RouteController::new(204, 204);
            let route = RouteParams { group: "Group".into(), name: "New".into() };
            let cleanup = apply_route_selection(&controller.client, &route, previous, auto_close, || Ok(())).await.unwrap();
            assert_eq!(json!(cleanup), json!({"requested":false,"completed":false,"closed":0}));
            assert_eq!(controller.requests(), ["PUT /proxies/Group HTTP/1.1"]);
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failed_route_switch_never_reads_or_closes_connections() {
        let controller = RouteController::new(500, 204);
        let route = RouteParams { group: "Group".into(), name: "New".into() };
        let failure = apply_route_selection(&controller.client, &route, Some("Old"), true, || Ok(())).await.unwrap_err();
        assert_eq!(failure.code.as_deref(), Some("ROUTE_SELECT_FAILED"));
        assert_eq!(controller.requests(), ["PUT /proxies/Group HTTP/1.1"]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failed_connection_cleanup_preserves_the_applied_route_switch() {
        let controller = RouteController::new(204, 500);
        let route = RouteParams { group: "Group".into(), name: "New".into() };
        let cleanup = apply_route_selection(&controller.client, &route, Some("Old"), true, || Ok(())).await.unwrap();
        assert_eq!(json!(cleanup), json!({
            "requested":true,"completed":false,"closed":0,
            "failure":{"code":"CONNECTION_CLOSE_FAILED","detail":"Cannot close the selected connection"}
        }));
        assert_eq!(controller.requests(), [
            "PUT /proxies/Group HTTP/1.1",
            "GET /connections HTTP/1.1",
            "DELETE /connections/target-1 HTTP/1.1",
        ]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn route_switch_and_cleanup_require_owned_core_readiness() {
        let route = RouteParams { group: "Group".into(), name: "New".into() };
        for (mode, ready, code) in [
            (RunningMode::NotRunning, false, "CORE_NOT_RUNNING"),
            (RunningMode::Service, false, "CORE_NOT_READY"),
        ] {
            let controller = RouteController::new(204, 204);
            let failure = apply_route_selection(&controller.client, &route, Some("Old"), true, || {
                ownership_guard(&Request::CloseConnection("target-1".into()), mode, ready).map(|_| ())
            }).await.unwrap_err();
            assert_eq!(failure.code.as_deref(), Some(code));
            assert!(controller.requests().is_empty());
        }
        let controller = RouteController::new(204, 204);
        let checks = std::cell::Cell::new(0);
        let cleanup = apply_route_selection(&controller.client, &route, Some("Old"), true, || {
            checks.set(checks.get() + 1);
            ownership_guard(&Request::CloseConnection("target-1".into()), RunningMode::Service, checks.get() < 3).map(|_| ())
        }).await.unwrap();
        assert_eq!(cleanup.failure.unwrap().code.as_deref(), Some("CORE_NOT_READY"));
        assert!(!cleanup.completed);
        assert_eq!(cleanup.closed, 0);
        assert_eq!(controller.requests(), ["PUT /proxies/Group HTTP/1.1", "GET /connections HTTP/1.1"]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn closes_only_the_requested_connection_on_an_isolated_controller() {
        use tauri_plugin_mihomo::{Mihomo, MihomoContext, models::Protocol};
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        for status in [204, 404] {
            let path = std::env::temp_dir().join(format!("tez-close-{}.sock", nanoid::nanoid!(8)));
            let listener = tokio::net::UnixListener::bind(&path).unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut headers = Vec::new();
                let mut byte = [0];
                while !headers.ends_with(b"\r\n\r\n") {
                    assert_eq!(socket.read(&mut byte).await.unwrap(), 1);
                    headers.push(byte[0]);
                    assert!(headers.len() < 4096);
                }
                assert!(std::str::from_utf8(&headers).unwrap().starts_with("DELETE /connections/connection-1 HTTP/1.1\r\n"));
                let body = if status == 204 { "" } else { "{\"message\":\"Already ended\"}" };
                socket.write_all(format!("HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            });
            let socket = path.to_string_lossy().to_string();
            let http = MihomoContext::build_client(&Protocol::LocalSocket, Some(&socket)).unwrap();
            let client = Mihomo::new(MihomoContext::new(Protocol::LocalSocket, None, None, None, Some(socket), std::time::Duration::from_secs(3), http));
            let result = close_connection(&client, "connection-1").await;
            if status == 204 {
                assert_eq!(result.unwrap(), json!({"closed":true,"id":"connection-1"}));
            } else {
                assert_eq!(result.unwrap_err().code.as_deref(), Some("CONNECTION_CLOSE_FAILED"));
            }
            server.await.unwrap();
            std::fs::remove_file(path).unwrap();
        }
    }

    #[test]
    fn route_validation_rejects_unsafe_member_identity() {
        use std::collections::BTreeMap;

        use crate::core::proxy_view::{
            ProxyCapabilities, ProxyMemberUnresolvedReason, ProxyViewOrderSource, ProxyViewProviderState,
        };

        let route = RouteParams {
            group: "group".into(),
            name: "node".into(),
        };
        let mut view = ProxyViewV1 {
            schema_version: 1,
            order_source: ProxyViewOrderSource::Runtime,
            provider_state: ProxyViewProviderState::Ready,
            global: None,
            direct: None,
            groups: vec![ProxyGroupView {
                name: route.group.clone(),
                proxy_type: ProxyType::Selector,
                now: None,
                fixed: None,
                hidden: None,
                icon: None,
                test_url: None,
                history: vec![],
                capabilities: ProxyCapabilities {
                    udp: false,
                    xudp: false,
                    tfo: false,
                    mptcp: false,
                    smux: false,
                },
                members: vec![ProxyMemberRef::Node {
                    name: route.name.clone(),
                    record_id: "node-id".into(),
                }],
            }],
            records: BTreeMap::new(),
            standalone: vec![],
            providers: vec![],
        };
        assert!(validate_route(&view, &route).is_ok());
        view.groups[0].proxy_type = ProxyType::LoadBalance;
        assert!(validate_route(&view, &route).is_err());
        view.groups[0].proxy_type = ProxyType::Selector;
        for reason in [
            ProxyMemberUnresolvedReason::Ambiguous,
            ProxyMemberUnresolvedReason::ProviderUnavailable,
        ] {
            view.groups[0].members = vec![ProxyMemberRef::Unresolved {
                name: route.name.clone(),
                reason,
            }];
            assert!(validate_route(&view, &route).is_err());
        }
        view.groups[0].members.clear();
        assert!(validate_route(&view, &route).is_err());
        view.groups.clear();
        assert!(validate_route(&view, &route).is_err());
    }
}
