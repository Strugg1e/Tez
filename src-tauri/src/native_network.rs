use std::time::Duration;

use serde_json::{Value, json};
use tauri_plugin_mihomo::Mihomo;

fn switch(enabled: Option<bool>) -> Value {
    json!({"state": if enabled.is_some() { "ready" } else { "unavailable" }, "enabled": enabled})
}

fn runtime_status(config: Option<&Value>) -> (Value, Value) {
    let tun = switch(
        config
            .and_then(|value| value.pointer("/tun/enable"))
            .and_then(Value::as_bool),
    );
    let mode = config
        .and_then(|value| value["mode"].as_str())
        .filter(|mode| ["rule", "global", "direct"].contains(mode));
    (
        tun,
        json!({"state": if mode.is_some() { "ready" } else { "unavailable" }, "value": mode}),
    )
}

async fn read_config(client: &Mihomo) -> anyhow::Result<Value> {
    let mut response = client
        .load_ctx()
        .build_request(reqwest::Method::GET, "/configs")?
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(
            bytes.len() + chunk.len() <= 256 * 1024,
            "Runtime configuration exceeds read limit"
        );
        bytes.extend_from_slice(&chunk);
    }
    Ok(serde_json::from_slice(&bytes)?)
}

async fn system_status(observe_system: bool) -> (Value, Value) {
    if !observe_system {
        return (switch(None), switch(None));
    }
    let read = tokio::task::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let snapshot = sysproxy::Sysproxy::snapshot().ok()?;
            Some((
                snapshot.http.switched_on || snapshot.https.switched_on || snapshot.socks.switched_on,
                snapshot.auto_switched_on,
            ))
        }
        #[cfg(not(target_os = "macos"))]
        {
            Some((
                sysproxy::Sysproxy::get_system_proxy().ok()?.enable,
                sysproxy::Autoproxy::get_auto_proxy().ok()?.enable,
            ))
        }
    });
    match tokio::time::timeout(Duration::from_secs(2), read).await {
        Ok(Ok(Some((system, pac)))) => (switch(Some(system)), switch(Some(pac))),
        _ => (switch(None), switch(None)),
    }
}

pub(crate) async fn read(client: Option<&Mihomo>, observe_system: bool) -> Value {
    let (config, (system, pac)) = tokio::join!(
        async {
            match client {
                Some(client) => tokio::time::timeout(Duration::from_secs(3), read_config(client))
                    .await
                    .ok()?
                    .ok(),
                None => None,
            }
        },
        system_status(observe_system)
    );
    let (tun, mode) = runtime_status(config.as_ref());
    json!({"systemProxy": system, "pac": pac, "tun": tun, "mode": mode})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_modes_are_observed_independently_without_config_fallback() {
        for mode in ["rule", "global", "direct"] {
            for enabled in [true, false] {
                let (tun, routing) =
                    runtime_status(Some(&json!({"mode":mode,"tun":{"enable":enabled},"secret":"private"})));
                assert_eq!(tun, switch(Some(enabled)));
                assert_eq!(routing["value"], mode);
                assert!(!routing.to_string().contains("private"));
            }
        }
        let (tun, mode) = runtime_status(Some(&json!({"mode":"unexpected"})));
        assert!(tun["enabled"].is_null() && mode["value"].is_null());
        assert_eq!(tun["state"], "unavailable");
    }

    #[tokio::test]
    async fn isolation_never_borrows_the_host_system_proxy() {
        let value = read(None, false).await;
        for key in ["systemProxy", "pac", "tun", "mode"] {
            assert_eq!(value[key]["state"], "unavailable");
        }
        assert!(value["systemProxy"]["enabled"].is_null());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reads_runtime_config_get_only_and_omits_private_fields() {
        use tauri_plugin_mihomo::{MihomoContext, models::Protocol};
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let path = std::env::temp_dir().join(format!("tez-status-{}.sock", nanoid::nanoid!(8)));
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut headers = Vec::new();
            let mut byte = [0];
            while !headers.ends_with(b"\r\n\r\n") {
                assert_eq!(socket.read(&mut byte).await.unwrap(), 1);
                headers.push(byte[0]);
            }
            assert!(
                std::str::from_utf8(&headers)
                    .unwrap()
                    .starts_with("GET /configs HTTP/1.1\r\n")
            );
            let body = json!({"mode":"global","tun":{"enable":true},"secret":"private-token"}).to_string();
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        let socket = path.to_string_lossy().to_string();
        let http = MihomoContext::build_client(&Protocol::LocalSocket, Some(&socket)).unwrap();
        let client = Mihomo::new(MihomoContext::new(
            Protocol::LocalSocket,
            None,
            None,
            None,
            Some(socket),
            Duration::from_secs(3),
            http,
        ));
        let status = read(Some(&client), false).await;
        assert_eq!(status["mode"]["value"], "global");
        assert_eq!(status["tun"]["enabled"], true);
        assert!(status["systemProxy"]["enabled"].is_null());
        assert!(!status.to_string().contains("private-token"));
        server.await.unwrap();
        std::fs::remove_file(path).unwrap();
    }
}
