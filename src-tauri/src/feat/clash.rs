use crate::core::notify::NoticeStatus;
use crate::core::notify::{Refresh, announce};
use crate::{
    config::{Config, IClashTemp, MixedPort, runtime::IRuntime},
    core::{CoreManager, handle, tray},
    feat::clean_async,
    process::AsyncHandler,
    utils,
};
use bytes::BytesMut;
use clash_verge_draft::{Draft, DraftTransaction};
use clash_verge_logging::{Type, logging};
use serde_yaml_ng::{Mapping, Value};
use smartstring::alias::String;
use std::sync::{Arc, LazyLock};
use tauri_plugin_mihomo::Mihomo;

#[allow(clippy::expect_used)]
static TLS_CONFIG: LazyLock<Arc<rustls::ClientConfig>> = LazyLock::new(|| {
    let root_store = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .expect("Failed to set TLS versions")
        .with_root_certificates(root_store)
        .with_no_client_auth();
    Arc::new(config)
});

pub async fn restart_clash_core() {
    match CoreManager::global().restart_core().await {
        Ok(_) => {
            announce(Refresh::Clash);
        }
        Err(err) => {
            handle::Handle::notice(NoticeStatus::SetConfigError, format!("{err:#}"));
            logging!(error, Type::Core, "restart core failed: {err:#}");
        }
    }
}

pub async fn restart_app() {
    logging!(debug, Type::System, "启动重启应用流程");
    handle::Handle::global().set_is_exiting();

    Config::apply_all_and_save_file().await;

    let cleanup_result = clean_async().await;

    logging!(
        info,
        Type::System,
        "资源清理完成，退出代码: {}",
        if cleanup_result.all_success { 0 } else { 1 }
    );

    if !cleanup_result.core_stopped {
        handle::Handle::global().clear_is_exiting();
        // A failed stop may still have marked the core stopped, and exit cleanup skipped the DNS restore.
        // A core that kept running keeps its DNS, whatever an unapplied config draft says.
        #[cfg(target_os = "macos")]
        {
            let manager = CoreManager::global();
            let _lifecycle = manager.lifecycle_lock.lock().await;
            if matches!(
                *manager.get_running_mode(),
                crate::core::manager::RunningMode::NotRunning
            ) {
                crate::utils::resolve::dns::sync_public_dns().await;
            }
        }
        handle::Handle::notice(
            NoticeStatus::AppRestartCoreStopFailed,
            cleanup_result.stop_error.unwrap_or_default(),
        );
        return;
    }

    utils::server::shutdown_embedded_server();
    let app_handle = handle::Handle::app_handle();
    app_handle.restart();
}

fn after_change_clash_mode() {
    AsyncHandler::spawn(move || async {
        if let Err(err) = handle::Handle::mihomo().close_all_connections().await {
            logging!(
                error,
                Type::Core,
                "Failed to close all connections after changing clash mode: {err}"
            );
        }
    });
}

/// Propagates mihomo PATCH failures so the frontend can roll back its optimistic mode.
pub async fn change_clash_mode(mode: String) -> Result<(), String> {
    let config_write = Config::try_lock_config_write().map_err(|err| String::from(err.to_string()))?;
    let _update = CoreManager::global()
        .claim_config_update(&config_write)
        .map_err(|err| String::from(err.to_string()))?;
    let clash = Config::clash().await;
    let runtime = Config::runtime().await;
    apply_clash_mode(mode.as_str(), handle::Handle::mihomo(), &clash, &runtime).await?;

    let clash_data = clash.data_arc();
    if clash_data.save_config().await.is_ok() {
        announce(Refresh::Clash);
        tray::Tray::global().update_menu_and_icon().await;
    }

    let is_auto_close_connection = Config::verge().await.data_arc().auto_close_connection.unwrap_or(false);
    if is_auto_close_connection {
        after_change_clash_mode();
    }

    Ok(())
}

async fn apply_clash_mode(
    mode: &str,
    client: &Mihomo,
    clash: &Draft<IClashTemp>,
    runtime: &Draft<IRuntime>,
) -> Result<(), String> {
    let transaction = DraftTransaction::begin(vec![clash, runtime]).map_err(|err| String::from(err.to_string()))?;
    let mut mapping = Mapping::new();
    mapping.insert(Value::from("mode"), Value::from(mode));
    let json_value = serde_json::json!({
        "mode": mode
    });
    if let Err(err) = client.patch_base_config(&json_value).await {
        logging!(error, Type::Core, "change clash mode failed: {err}");
        return Err(err.to_string().into());
    }

    clash.edit_draft(|d| d.patch_config(&mapping));
    runtime.edit_draft(|draft| {
        if let Some(config) = draft.config.as_mut() {
            config.insert("mode".into(), mode.into());
        }
    });
    transaction.commit();
    Ok(())
}

/// Test delay to a URL through proxy.
/// HTTPS: measures TLS handshake time. HTTP: measures HEAD round-trip time.
#[tracing::instrument(skip_all, level = "trace", fields(url = %url))]
pub async fn test_delay(url: String) -> anyhow::Result<u32> {
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    use tokio::net::TcpStream;
    use tokio::time::Instant;

    let parsed = tauri::Url::parse(&url)?;
    let is_https = parsed.scheme() == "https";
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("Invalid URL: no host"))?
        .to_string();
    let port = parsed.port().unwrap_or(if is_https { 443 } else { 80 });

    let verge = Config::verge().await.latest_arc();
    let proxy_enabled = verge.enable_system_proxy.unwrap_or(false) || verge.enable_tun_mode.unwrap_or(false);
    let proxy_port = if proxy_enabled {
        Some(MixedPort::desired().await)
    } else {
        None
    };

    tokio::time::timeout(Duration::from_secs(10), async {
        let start = Instant::now();
        let mut buf = BytesMut::with_capacity(1024);

        if is_https {
            let stream = match proxy_port {
                Some(pp) => {
                    let mut s = TcpStream::connect(format!("127.0.0.1:{pp}")).await?;
                    s.write_all(format!("CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n").as_bytes())
                        .await?;
                    s.read_buf(&mut buf).await?;
                    if !buf.windows(3).any(|w| w == b"200") {
                        return Err(anyhow::anyhow!("Proxy CONNECT failed"));
                    }
                    s
                }
                None => TcpStream::connect(format!("{host}:{port}")).await?,
            };
            let connector = tokio_rustls::TlsConnector::from(Arc::clone(&TLS_CONFIG));
            let server_name = rustls::pki_types::ServerName::try_from(host.as_str())
                .map_err(|_| anyhow::anyhow!("Invalid DNS name: {host}"))?
                .to_owned();
            connector.connect(server_name, stream).await?;
        } else {
            let (mut stream, req) = match proxy_port {
                Some(pp) => (
                    TcpStream::connect(format!("127.0.0.1:{pp}")).await?,
                    format!("HEAD {url} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
                ),
                None => (
                    TcpStream::connect(format!("{host}:{port}")).await?,
                    format!("HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
                ),
            };
            stream.write_all(req.as_bytes()).await?;
            let _ = stream.read(&mut buf).await?;
        }

        Ok((start.elapsed().as_millis() as u32).max(1))
    })
    .await
    .unwrap_or(Ok(10000u32))
}

#[cfg(all(test, unix, feature = "native-host"))]
mod mode_tests {
    use super::*;
    use crate::native_chain::{Chain, change_links};
    use tauri_plugin_mihomo::{MihomoContext, models::Protocol};
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    async fn controller(
        path: &std::path::Path,
        status: u16,
        requests: usize,
    ) -> (Mihomo, tokio::task::JoinHandle<Vec<Mapping>>) {
        let listener = tokio::net::UnixListener::bind(path).unwrap();
        let server = tokio::spawn(async move {
            let mut reloads = Vec::new();
            for _ in 0..requests {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut headers = Vec::new();
                let mut byte = [0];
                while !headers.ends_with(b"\r\n\r\n") {
                    assert_eq!(socket.read(&mut byte).await.unwrap(), 1);
                    headers.push(byte[0]);
                    assert!(headers.len() < 4096);
                }
                let headers = std::str::from_utf8(&headers).unwrap();
                let length = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .unwrap();
                let mut body = vec![0; length];
                socket.read_exact(&mut body).await.unwrap();
                let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
                if headers.starts_with("PATCH /configs HTTP/1.1\r\n") {
                    assert!(matches!(body["mode"].as_str(), Some("global" | "direct")));
                } else {
                    assert!(headers.starts_with("PUT /configs?force=true HTTP/1.1\r\n"));
                    let yaml = std::fs::read_to_string(body["path"].as_str().unwrap()).unwrap();
                    reloads.push(serde_yaml_ng::from_str(&yaml).unwrap());
                }
                let body = if status == 204 {
                    ""
                } else {
                    "{\"message\":\"Rejected mode\"}"
                };
                socket
                    .write_all(
                        format!(
                            "HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
            }
            reloads
        });
        let socket = path.to_string_lossy().to_string();
        let http = MihomoContext::build_client(&Protocol::LocalSocket, Some(&socket)).unwrap();
        let client = Mihomo::new(MihomoContext::new(
            Protocol::LocalSocket,
            None,
            None,
            None,
            Some(socket),
            std::time::Duration::from_secs(3),
            http,
        ));
        (client, server)
    }

    fn fixture() -> (Draft<IClashTemp>, Draft<IRuntime>, Chain) {
        let config: Mapping =
            serde_yaml_ng::from_str("mode: rule\nproxies:\n- {name: A, type: socks5}\n- {name: B, type: socks5}\n")
                .unwrap();
        let clash = Draft::new(IClashTemp(config.clone()));
        let runtime = Draft::new(IRuntime {
            config: Some(config),
            ..Default::default()
        });
        let chain = Chain {
            id: "test".into(),
            name: "Two hops".into(),
            group: "Fixture".into(),
            nodes: vec!["A".into(), "B".into()],
        };
        (clash, runtime, chain)
    }

    #[tokio::test]
    async fn patched_mode_survives_native_chain_enable_and_disable() {
        for mode in ["global", "direct"] {
            let path = std::env::temp_dir().join(format!("tez-mode-{}.sock", nanoid::nanoid!(8)));
            let yaml = path.with_extension("yaml");
            let (client, server) = controller(&path, 204, 3).await;
            let (clash, runtime, chain) = fixture();
            apply_clash_mode(mode, &client, &clash, &runtime).await.unwrap();
            for enable in [true, false] {
                runtime.edit_draft(|draft| {
                    draft.config = Some(change_links(draft.config.as_ref().unwrap(), &chain, enable).unwrap());
                });
                runtime.apply();
                std::fs::write(
                    &yaml,
                    serde_yaml_ng::to_string(runtime.data_arc().config.as_ref().unwrap()).unwrap(),
                )
                .unwrap();
                client.reload_config(true, yaml.to_str().unwrap()).await.unwrap();
            }
            let reloads = server.await.unwrap();
            std::fs::remove_file(path).unwrap();
            std::fs::remove_file(yaml).unwrap();
            assert_eq!(clash.data_arc().0["mode"].as_str(), Some(mode));
            assert_eq!(
                reloads
                    .iter()
                    .map(|config| config["mode"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                [mode, mode]
            );
            assert_eq!(reloads[0]["proxies"][1]["dialer-proxy"].as_str(), Some("A"));
            assert!(reloads[1]["proxies"][1].get("dialer-proxy").is_none());
        }
    }

    #[tokio::test]
    async fn rejected_mode_patch_does_not_publish_configuration() {
        let path = std::env::temp_dir().join(format!("tez-mode-{}.sock", nanoid::nanoid!(8)));
        let (client, server) = controller(&path, 500, 1).await;
        let (clash, runtime, _) = fixture();
        let original_clash = clash.data_arc();
        let original_runtime = runtime.data_arc();
        assert!(apply_clash_mode("global", &client, &clash, &runtime).await.is_err());
        server.await.unwrap();
        std::fs::remove_file(path).unwrap();
        assert!(Arc::ptr_eq(&original_clash, &clash.data_arc()));
        assert!(Arc::ptr_eq(&original_runtime, &runtime.data_arc()));
        assert!(Arc::ptr_eq(&original_clash, &clash.latest_arc()));
        assert!(Arc::ptr_eq(&original_runtime, &runtime.latest_arc()));
    }
}
