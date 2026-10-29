use std::{
    collections::{BTreeMap, HashSet},
    io,
    path::PathBuf,
    sync::Arc,
    time::Duration,
};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use tauri_plugin_mihomo::{Mihomo, MihomoContext, models::Protocol};
use tokio::io::AsyncReadExt as _;

use crate::{
    config::IProfiles,
    core::proxy_view::{ProxyViewBuilder, ProxyViewInput},
};

const MAX_PROFILE_BYTES: u64 = 4 * 1024 * 1024;
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(5);

/// Attaches to existing files and a local controller without owning their lifecycle.
#[derive(Clone)]
pub struct NativeData {
    data_dir: PathBuf,
    socket_path: PathBuf,
    mihomo: Arc<Mihomo>,
    discover_service: bool,
    observe_system: bool,
}

impl NativeData {
    pub fn new(data_dir: PathBuf, socket_path: PathBuf) -> Result<Self> {
        let mihomo = Arc::new(local_client(&socket_path)?);
        Ok(Self {
            data_dir,
            socket_path,
            mihomo,
            discover_service: false,
            observe_system: false,
        })
    }

    pub fn new_attach(data_dir: PathBuf, socket_path: Option<PathBuf>) -> Result<Self> {
        let discover_service = socket_path.is_none();
        let socket_path = socket_path
            .map(Ok)
            .unwrap_or_else(crate::utils::dirs::sidecar_ipc_path)?;
        let mut data = Self::new(data_dir, socket_path)?;
        data.discover_service = discover_service;
        data.observe_system = true;
        Ok(data)
    }

    pub(crate) async fn controller(&self) -> Result<(PathBuf, Arc<Mihomo>, &'static str)> {
        #[cfg(unix)]
        if self.discover_service {
            // Unix credentials only canonicalize this root; Windows credentials can create a token.
            if let Ok(credentials) = crate::core::owner_identity::current_owner_credentials_for_root(&self.data_dir)
                && let Ok(Ok(response)) = tokio::time::timeout(
                    Duration::from_secs(1),
                    clash_verge_service_ipc::get_status(&credentials),
                )
                .await
                && service_core_is_active(response.code, response.data.as_ref())
            {
                let path = PathBuf::from(clash_verge_service_ipc::mihomo_ipc_path(&credentials.identity));
                let client = local_client(&path)?;
                return Ok((path, Arc::new(client), "service"));
            }
        }
        Ok((self.socket_path.clone(), self.mihomo.clone(), "sidecar"))
    }

    pub async fn snapshot(&self) -> Value {
        // Independent deadlines preserve readable profiles when the controller stalls.
        let (profiles, core, network) = tokio::join!(
            tokio::time::timeout(SNAPSHOT_TIMEOUT, self.profiles()),
            tokio::time::timeout(SNAPSHOT_TIMEOUT, self.proxy_view()),
            async {
                let controller = self.controller().await.ok();
                crate::native_network::read(controller.as_ref().map(|(_, client, _)| client.as_ref()), self.observe_system).await
            },
        );
        let profiles = profiles.unwrap_or_else(|_| profile_state("error", "Profile read deadline exceeded"));
        let (proxy_view, core) =
            core.unwrap_or_else(|_| core_failure("error", "controller_timeout", "Controller read deadline exceeded"));
        json!({"profiles": profiles, "proxyView": proxy_view, "core": core, "network": network})
    }

    pub(crate) async fn activity_query(&self, query: crate::native_activity::ActivityQuery) -> Value {
        tokio::time::timeout(Duration::from_secs(6), async {
            match self.controller().await {
                Ok((socket, client, source)) => crate::native_activity::read(&socket, &client, source, &query).await,
                _ => crate::native_activity::unavailable("controller_discovery", "Cannot find the local controller"),
            }
        })
        .await
        .unwrap_or_else(|_| {
            crate::native_activity::unavailable("controller_timeout", "Local activity read deadline exceeded")
        })
    }

    async fn profiles(&self) -> Value {
        let path = self.data_dir.join("profiles.yaml");
        let metadata = match tokio::fs::metadata(&path).await {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return profile_state("missing", "Profile metadata is not available");
            }
            Err(_) => return profile_state("error", "Cannot read profile metadata"),
        };
        if !metadata.is_file() || metadata.len() > MAX_PROFILE_BYTES {
            return profile_state("error", "Profile metadata is not a supported file");
        }
        let file = match tokio::fs::File::open(path).await {
            Ok(file) => file,
            Err(_) => return profile_state("error", "Cannot read profile metadata"),
        };
        let mut bytes = Vec::new();
        if file.take(MAX_PROFILE_BYTES + 1).read_to_end(&mut bytes).await.is_err() {
            return profile_state("error", "Cannot read profile metadata");
        }
        if bytes.len() as u64 > MAX_PROFILE_BYTES {
            return profile_state("error", "Profile metadata exceeds the size limit");
        }
        let profiles: IProfiles = match serde_yaml_ng::from_slice(&bytes) {
            Ok(profiles) => profiles,
            Err(_) => return profile_state("error", "Profile metadata is invalid"),
        };
        let mut seen = HashSet::new();
        let mut items = Vec::new();
        for item in profiles.items.unwrap_or_default() {
            let Some(uid) = item.uid.filter(|uid| !uid.trim().is_empty()) else {
                return profile_state("error", "Profile metadata contains invalid identities");
            };
            if !seen.insert(uid.clone()) {
                return profile_state("error", "Profile metadata contains invalid identities");
            }
            items.push(json!({
                "uid": uid,
                "name": item.name.unwrap_or_default(),
                "type": item.itype.unwrap_or_default(),
                "updated": item.updated,
            }));
        }
        json!({"state": "ready", "current": profiles.current, "items": items, "message": null})
    }

    async fn proxy_view(&self) -> (Value, Value) {
        let (socket_path, mihomo, mode) = match self.controller().await {
            Ok(controller) => controller,
            Err(_) => return core_failure("error", "controller_client", "Cannot construct local controller client"),
        };
        let metadata = match tokio::fs::symlink_metadata(&socket_path).await {
            Ok(metadata) => metadata,
            Err(error) => return socket_failure(&error),
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileTypeExt as _;
            if !metadata.file_type().is_socket() {
                return core_failure("unavailable", "socket_type", "Local controller path is not a socket");
            }
            if let Err(error) = tokio::net::UnixStream::connect(&socket_path).await {
                return socket_failure(&error);
            }
        }
        #[cfg(not(unix))]
        {
            let _ = metadata;
            return core_failure(
                "unavailable",
                "platform",
                "Local controller is not supported on this platform",
            );
        }
        let (proxies, providers) = tokio::join!(mihomo.get_proxies(), mihomo.get_proxy_providers());
        match proxies {
            Ok(proxies) => {
                let view = ProxyViewBuilder::build(ProxyViewInput {
                    runtime_group_order: Vec::new(),
                    group_scopes: BTreeMap::new(),
                    proxies,
                    providers: providers.ok(),
                });
                match serde_json::to_value(view) {
                    Ok(view) => (view, json!({"state": "ready", "message": null, "source": mode})),
                    Err(_) => (
                        Value::Null,
                        json!({"state": "error", "message": "Cannot encode controller snapshot"}),
                    ),
                }
            }
            Err(_) => core_failure("error", "controller_request", "Cannot read local controller"),
        }
    }
}

fn profile_state(state: &str, message: &str) -> Value {
    json!({"state": state, "current": null, "items": [], "message": message})
}

fn local_client(socket_path: &std::path::Path) -> Result<Mihomo> {
    let socket = socket_path
        .to_str()
        .ok_or_else(|| anyhow!("Invalid local socket path"))?;
    let protocol = Protocol::LocalSocket;
    let client = MihomoContext::build_client(&protocol, Some(socket))
        .map_err(|_| anyhow!("Cannot construct local controller client"))?;
    Ok(Mihomo::new(MihomoContext::new(
        protocol,
        None,
        None,
        None,
        Some(socket.to_owned()),
        SNAPSHOT_TIMEOUT,
        client,
    )))
}

fn service_core_is_active(code: u16, status: Option<&clash_verge_service_ipc::ServiceStatusSnapshot>) -> bool {
    code == 0 && status.is_some_and(|status| status.is_active && status.core_pid.is_some())
}

fn socket_failure(error: &io::Error) -> (Value, Value) {
    let (code, message) = match error.kind() {
        io::ErrorKind::NotFound => ("socket_missing", "Local controller socket is missing"),
        io::ErrorKind::PermissionDenied => ("socket_permission", "Local controller socket access was denied"),
        io::ErrorKind::ConnectionRefused => ("socket_refused", "Local controller socket has no listener"),
        _ => ("socket_unreachable", "Local controller socket is unreachable"),
    };
    core_failure("unavailable", code, message)
}

fn core_failure(state: &str, code: &str, message: &str) -> (Value, Value) {
    (Value::Null, json!({"state": state, "code": code, "message": message}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "tez-native-data-{}-{}",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn reader(&self) -> NativeData {
            NativeData::new(self.0.clone(), self.0.join("missing.sock")).unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[tokio::test]
    async fn projects_existing_schema_without_secrets_or_writes() {
        let fixture = Fixture::new();
        let path = fixture.0.join("profiles.yaml");
        let source = b"current: selected\nitems:\n  - uid: selected\n    name: Example\n    type: remote\n    updated: 1700000000\n    url: https://secret.invalid/token\n    option:\n      script: private-script\n";
        std::fs::write(&path, source).unwrap();
        let snapshot = fixture.reader().snapshot().await;
        assert_eq!(
            snapshot["profiles"],
            json!({
                "state": "ready", "current": "selected", "message": null,
                "items": [{"uid": "selected", "name": "Example", "type": "remote", "updated": 1700000000}]
            })
        );
        assert_eq!(snapshot["core"]["state"], "unavailable");
        assert!(snapshot["proxyView"].is_null());
        assert!(!snapshot.to_string().contains("secret.invalid"));
        assert!(!snapshot.to_string().contains("private-script"));
        assert_eq!(std::fs::read(path).unwrap(), source);
        assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn missing_and_invalid_metadata_are_sanitized() {
        let fixture = Fixture::new();
        let reader = fixture.reader();
        assert_eq!(reader.snapshot().await["profiles"]["state"], "missing");
        assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 0);
        std::fs::write(fixture.0.join("profiles.yaml"), "items: [private-token").unwrap();
        let snapshot = reader.snapshot().await;
        assert_eq!(snapshot["profiles"]["state"], "error");
        assert!(!snapshot.to_string().contains("private-token"));
    }

    #[tokio::test]
    async fn construction_does_not_create_missing_directories() {
        let fixture = Fixture::new();
        let path = fixture.0.join("absent");
        let reader = NativeData::new(path.clone(), path.join("controller.sock")).unwrap();
        assert_eq!(reader.snapshot().await["profiles"]["state"], "missing");
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn explicit_socket_override_never_discovers_a_service() {
        let fixture = Fixture::new();
        let socket = fixture.0.join("explicit.sock");
        let reader = NativeData::new_attach(fixture.0.clone(), Some(socket.clone())).unwrap();
        assert!(!reader.discover_service);
        assert_eq!(reader.controller().await.unwrap().0, socket);
        assert_eq!(reader.snapshot().await["core"]["code"], "socket_missing");
        assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 0);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stale_and_non_socket_paths_have_sanitized_diagnostics() {
        let fixture = Fixture::new();
        let socket = fixture.0.join("controller.sock");
        drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
        let reader = NativeData::new(fixture.0.clone(), socket.clone()).unwrap();
        let snapshot = reader.snapshot().await;
        assert_eq!(snapshot["core"]["code"], "socket_refused");
        assert!(!snapshot.to_string().contains(&fixture.0.to_string_lossy().to_string()));
        std::fs::remove_file(&socket).unwrap();
        std::fs::write(&socket, "private-controller-data").unwrap();
        assert_eq!(reader.snapshot().await["core"]["code"], "socket_type");
        std::fs::remove_file(&socket).unwrap();
        std::os::unix::fs::symlink(fixture.0.join("absent"), &socket).unwrap();
        assert_eq!(reader.snapshot().await["core"]["code"], "socket_type");
    }

    #[test]
    fn service_endpoint_requires_success_active_owner_and_live_core() {
        let mut status: clash_verge_service_ipc::ServiceStatusSnapshot = serde_json::from_value(json!({
            "is_active": true, "active_generation": 1, "service_state": "Running",
            "core_pid": 42, "core_started_at": null, "last_core_exit_reason": null,
            "restart_count": 0, "last_recovery_at": null,
            "desired_core_should_be_running": true, "desired_generation": 1, "desired_updated_at": 0
        }))
        .unwrap();
        assert!(service_core_is_active(0, Some(&status)));
        assert!(!service_core_is_active(1, Some(&status)));
        assert!(!service_core_is_active(0, None));
        status.is_active = false;
        assert!(!service_core_is_active(0, Some(&status)));
        status.is_active = true;
        status.core_pid = None;
        assert!(!service_core_is_active(0, Some(&status)));
    }

    #[tokio::test]
    async fn oversized_metadata_is_rejected() {
        let fixture = Fixture::new();
        let file = std::fs::File::create(fixture.0.join("profiles.yaml")).unwrap();
        file.set_len(MAX_PROFILE_BYTES + 1).unwrap();
        assert_eq!(fixture.reader().snapshot().await["profiles"]["state"], "error");
    }

    #[tokio::test]
    async fn invalid_profile_identities_do_not_return_partial_ready_data() {
        let fixture = Fixture::new();
        let path = fixture.0.join("profiles.yaml");
        for source in [
            "items:\n  - uid: valid\n  - name: Missing identity\n",
            "items:\n  - uid: ''\n",
            "items:\n  - uid: duplicate\n  - uid: duplicate\n",
        ] {
            std::fs::write(&path, source).unwrap();
            let snapshot = fixture.reader().snapshot().await;
            assert_eq!(snapshot["profiles"]["state"], "error");
            assert_eq!(snapshot["profiles"]["items"], json!([]));
            assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
        }
    }
}
