use serde::Deserialize;
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
    validate_route(&view, &route)?;
    if manager.current_core_readiness_generation() != generation
        || matches!(*manager.get_running_mode(), RunningMode::NotRunning)
    {
        return Err(CommandFailure::coded(
            "CORE_NOT_READY",
            "Owned core changed while reading proxy groups",
        ));
    }
    // A background profile activation must not overwrite this newer runtime choice.
    crate::config::profiles::supersede_selected_activation();
    Handle::mihomo()
        .select_node_for_group(&route.group, &route.name)
        .await
        .map_err(|error| CommandFailure::coded("ROUTE_SELECT_FAILED", format_args!("{error:#}")))?;
    Handle::refresh_clash();
    Ok(finish_selection(&route.name, || async {
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
    .await)
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
        Request::Start if running => Ok(false),
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
        crate::core::timer::Timer::global().init().await
            .map_err(|_| CommandFailure::coded("SUBSCRIPTION_TIMER_FAILED", "Core is running, but subscription scheduling failed"))?;
    }
    state
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
