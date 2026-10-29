use crate::{
    cmd::{self, CmdResult, CommandFailure},
    config::{Config, IVerge},
    core::{CoreManager, handle::Handle, manager::RunningMode},
};
use serde::Deserialize;
use serde_json::{Value, json};

pub const COMMANDS: &[&str] = &[
    "native_get_settings",
    "native_patch_settings",
    "native_set_mode",
    "native_get_dns",
    "native_save_dns",
    "native_set_dns_override",
    "native_import_subscription",
    "native_create_local_profile",
    "native_subscription_details",
    "native_patch_subscription",
    "native_update_subscription",
    "native_activate_profile",
    "native_delete_profile",
    "native_reorder_profile",
    "native_test_latency",
    "native_get_logs",
    "native_list_local_backups",
    "native_create_local_backup",
    "native_delete_local_backup",
    "native_import_local_backup", "native_export_local_backup", "native_restore_local_backup",
    "native_get_webdav_config", "native_save_webdav_config", "native_list_webdav_backups",
    "native_create_webdav_backup", "native_delete_webdav_backup", "native_restore_webdav_backup",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields, tag = "kind", rename_all = "snake_case")]
pub(crate) enum Request {
    GetSettings,
    PatchSettings {
        values: serde_json::Map<String, Value>,
    },
    SetMode {
        mode: String,
    },
    GetDns,
    SaveDns {
        content: String,
    },
    SetDnsOverride {
        uid: String,
        enabled: bool,
        confirmation: Option<String>,
    },
    ImportSubscription {
        url: String,
        name: String,
        interval: u64,
        auto_update: bool,
        with_proxy: bool,
    },
    CreateLocalProfile {
        name: String,
        content: String,
    },
    SubscriptionDetails {
        uid: String,
    },
    PatchSubscription {
        uid: String,
        name: String,
        url: Option<String>,
        interval: u64,
        auto_update: bool,
        with_proxy: bool,
    },
    UpdateSubscription {
        uid: String,
    },
    ActivateProfile {
        uid: String,
    },
    DeleteProfile {
        uid: String,
    },
    ReorderProfile {
        uid: String,
        over: String,
    },
    TestLatency {
        names: Vec<String>,
        url: String,
        timeout: u32,
    },
    GetLogs {
        limit: usize,
        level: String,
        query: String,
    },
    ListLocalBackups,
    CreateLocalBackup,
    DeleteLocalBackup { filename: String },
    ImportLocalBackup { source: String },
    ExportLocalBackup { filename: String, destination: String },
    RestoreLocalBackup { filename: String },
    GetWebdavConfig,
    SaveWebdavConfig { url: String, username: String, password: Option<String> },
    ListWebdavBackups,
    CreateWebdavBackup,
    DeleteWebdavBackup { filename: String },
    RestoreWebdavBackup { filename: String },
}

const SETTINGS: &[&str] = &[
    "enable_system_proxy",
    "enable_tun_mode",
    "enable_proxy_guard",
    "proxy_auto_config",
    "verge_mixed_port",
    "verge_port",
    "verge_http_enabled",
    "verge_socks_port",
    "verge_socks_enabled",
    "system_proxy_bypass",
    "proxy_guard_duration",
    "default_latency_test",
    "default_latency_timeout",
    "app_log_level",
    "proxy_host", "enable_bypass_check", "use_default_bypass", "pac_file_content", "auto_close_connection",
];

fn invalid(message: impl std::fmt::Display) -> CommandFailure {
    CommandFailure::coded("INVALID_PARAMS", message)
}

fn valid_backup_filename(name: &str) -> bool {
    crate::native_backup::valid_filename(name)
}

fn valid_url(value: &str) -> bool {
    reqwest::Url::parse(value).is_ok_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

pub(crate) fn parse(command: &str, params: Value) -> CmdResult<Request> {
    let kind = command
        .strip_prefix("native_")
        .filter(|_| COMMANDS.contains(&command))
        .ok_or_else(|| CommandFailure::coded("NATIVE_COMMAND_UNAVAILABLE", "Unknown workspace command"))?;
    let mut fields = params.as_object().cloned().ok_or_else(|| invalid("Expected object"))?;
    if fields.contains_key("kind") {
        return Err(invalid("Unexpected kind"));
    }
    fields.insert("kind".into(), Value::String(kind.into()));
    let request: Request =
        serde_json::from_value(Value::Object(fields)).map_err(|_| invalid("Invalid workspace parameters"))?;
    match &request {
        Request::PatchSettings { values } => {
            if values.is_empty() || values.keys().any(|key| !SETTINGS.contains(&key.as_str())) {
                return Err(invalid("Unsupported or empty settings patch"));
            }
            serde_json::from_value::<IVerge>(json!(values)).map_err(|_| invalid("Invalid settings type"))?;
            for (key, value) in values {
                if value.is_null() {
                    return Err(invalid("Null settings are not accepted"));
                }
                if matches!(key.as_str(), "verge_mixed_port" | "verge_port" | "verge_socks_port")
                    && !value.as_u64().is_some_and(|port| (1..=65535).contains(&port))
                {
                    return Err(invalid("Port must be between 1 and 65535"));
                }
                if key == "default_latency_test" && !value.as_str().is_some_and(valid_url) {
                    return Err(invalid("Latency URL must be HTTP or HTTPS"));
                }
                if key == "system_proxy_bypass" && !value.as_str().is_some_and(|text| text.len() <= 16384) {
                    return Err(invalid("Proxy bypass list exceeds 16 KiB"));
                }
                if key == "proxy_guard_duration" && !value.as_u64().is_some_and(|value| (1..=86400).contains(&value)) {
                    return Err(invalid("Proxy guard duration must be 1–86400 seconds"));
                }
                if key == "default_latency_timeout" && !value.as_u64().is_some_and(|v| (100..=30000).contains(&v)) {
                    return Err(invalid("Latency timeout must be 100–30000 ms"));
                }
                if key == "app_log_level"
                    && !value
                        .as_str()
                        .is_some_and(|v| ["silent", "error", "warn", "info", "debug", "trace"].contains(&v))
                {
                    return Err(invalid("Invalid log level"));
                }
                if matches!(key.as_str(), "proxy_host" | "pac_file_content") && !value.as_str().is_some_and(|v| v.len() <= if key == "proxy_host" { 255 } else { 65536 }) {
                    return Err(invalid("Proxy text field exceeds its limit"));
                }
            }
        }
        Request::SetMode { mode } if !["rule", "global", "direct"].contains(&mode.as_str()) => {
            return Err(invalid("Invalid routing mode"));
        }
        Request::SaveDns { content } | Request::CreateLocalProfile { content, .. } => {
            if content.len() > 2 * 1024 * 1024 {
                return Err(invalid("Content exceeds 2 MiB"));
            }
            serde_yaml_ng::from_str::<serde_yaml_ng::Mapping>(content)
                .map_err(|_| invalid("Expected a YAML mapping"))?;
        }
        Request::ImportSubscription { url, interval, .. } => {
            if !valid_url(url) || !(1440..=525600).contains(interval) {
                return Err(invalid("Invalid subscription URL or update interval"));
            }
        }
        Request::ReorderProfile { uid, over } if over.is_empty() || over.len() > 128 || uid == over => {
            return Err(invalid("Invalid reorder target"));
        }
        Request::PatchSubscription { url, interval, .. } => {
            if *interval < crate::constants::profile::MIN_UPDATE_INTERVAL || *interval > 525600 {
                return Err(invalid("Update interval must be between 1440 and 525600 minutes"));
            }
            if url.as_ref().is_some_and(|url| !valid_url(url)) {
                return Err(invalid("Invalid subscription URL"));
            }
        }
        Request::TestLatency { names, url, timeout } => {
            if names.is_empty()
                || names.len() > 16
                || names.iter().any(|name| name.is_empty() || name.len() > 512)
                || !valid_url(url)
                || !(100..=30000).contains(timeout)
            {
                return Err(invalid("Invalid latency batch, URL or timeout"));
            }
        }
        Request::GetLogs { limit, query, level } => {
            if !(1..=1000).contains(limit)
                || query.len() > 256
                || !["all", "error", "warn", "info", "debug", "trace"].contains(&level.as_str())
            {
                return Err(invalid("Invalid log query"));
            }
        }
        Request::DeleteLocalBackup { filename } | Request::RestoreLocalBackup { filename }
        | Request::DeleteWebdavBackup { filename } | Request::RestoreWebdavBackup { filename }
        | Request::ExportLocalBackup { filename, .. } if !valid_backup_filename(filename) => {
            return Err(invalid("Invalid backup filename"));
        }
        Request::ImportLocalBackup { source } if !crate::native_backup::valid_file_path(source) => return Err(invalid("Invalid backup source")),
        Request::ExportLocalBackup { destination, .. } if !crate::native_backup::valid_file_path(destination) => return Err(invalid("Invalid backup destination")),
        Request::SaveWebdavConfig { url, username, password } if !valid_url(url) || url.len() > 2048 || username.trim().is_empty() || username.len() > 1024 || password.as_ref().is_some_and(|v| v.is_empty() || v.len() > 4096) => return Err(invalid("Invalid WebDAV configuration")),
        _ => {}
    }
    let uid = match &request {
        Request::SetDnsOverride { uid, .. }
        | Request::SubscriptionDetails { uid }
        | Request::PatchSubscription { uid, .. }
        | Request::UpdateSubscription { uid }
        | Request::ActivateProfile { uid }
        | Request::DeleteProfile { uid }
        | Request::ReorderProfile { uid, .. } => Some(uid),
        _ => None,
    };
    if uid.is_some_and(|uid| uid.is_empty() || uid.len() > 128) {
        return Err(invalid("Invalid profile identity"));
    }
    match &request {
        Request::ImportSubscription { name, .. }
        | Request::CreateLocalProfile { name, .. }
        | Request::PatchSubscription { name, .. }
            if name.trim().is_empty() || name.len() > 256 =>
        {
            return Err(invalid("Invalid profile name"));
        }
        _ => {}
    }
    Ok(request)
}

pub fn validate(command: &str, params: Value) -> CmdResult<()> {
    parse(command, params).map(|_| ())
}

pub fn mutates(command: &str) -> bool {
    COMMANDS.contains(&command)
        && !matches!(
            command,
            "native_get_settings"
                | "native_get_dns"
                | "native_subscription_details"
                | "native_test_latency"
                | "native_get_logs"
                | "native_list_local_backups"
                | "native_get_webdav_config"
                | "native_list_webdav_backups"
        )
}

async fn profile(uid: &str) -> CmdResult<crate::config::PrfItem> {
    Config::profiles()
        .await
        .latest_arc()
        .get_item(uid)
        .cloned()
        .map_err(|_| invalid("Profile no longer exists"))
}

fn encode(value: impl serde::Serialize) -> CmdResult<Value> {
    serde_json::to_value(value).map_err(|error| CommandFailure::coded("NATIVE_ENCODING_FAILED", error))
}

pub async fn dispatch(command: &str, params: Value) -> CmdResult<Value> {
    let request = parse(command, params)?;
    match request {
        Request::ListLocalBackups => {
            let backups = cmd::list_local_backup().await?;
            Ok(json!({"backups": backups.into_iter().filter(|item| valid_backup_filename(&item.filename)).map(|item| json!({
                "filename": item.filename, "lastModified": item.last_modified, "size": item.content_length
            })).collect::<Vec<_>>() }))
        }
        Request::CreateLocalBackup => {
            let _profile_write = crate::config::profiles::PROFILE_WRITE_LOCK.lock().await;
            let _config_write = Config::lock_config_write().await;
            let filename = crate::feat::create_local_backup_with_namer(|name| {
                format!("{}-{}.zip", name.trim_end_matches(".zip"), nanoid::nanoid!(8)).into()
            }).await.map_err(|error| CommandFailure::coded("BACKUP_CREATE_FAILED", error))?;
            Ok(json!({"filename": filename}))
        }
        Request::DeleteLocalBackup { filename } => {
            cmd::delete_local_backup(filename).await?;
            Ok(json!({"deleted": true}))
        }
        Request::ImportLocalBackup { source } => crate::native_backup::import(source).await,
        Request::ExportLocalBackup { filename, destination } => crate::native_backup::export(filename, destination).await,
        Request::RestoreLocalBackup { filename } => crate::native_backup::restore(filename).await,
        Request::GetWebdavConfig => Ok(crate::native_backup::webdav_config().await),
        Request::SaveWebdavConfig { url, username, password } => crate::native_backup::save_webdav(url, username, password).await,
        Request::ListWebdavBackups => crate::native_backup::webdav_list().await,
        Request::CreateWebdavBackup => crate::native_backup::webdav_create().await,
        Request::DeleteWebdavBackup { filename } => crate::native_backup::webdav_delete(filename).await,
        Request::RestoreWebdavBackup { filename } => crate::native_backup::webdav_restore(filename).await,
        Request::GetSettings => {
            let config = Config::verge().await.latest_arc();
            let raw = serde_json::to_value(&*config).map_err(invalid)?;
            let defaults = serde_json::to_value(IVerge::template()).map_err(invalid)?;
            let values: serde_json::Map<_, _> = SETTINGS
                .iter()
                .map(|key| ((*key).into(), raw.get(*key).filter(|value|!value.is_null()).or_else(||defaults.get(*key)).cloned().unwrap_or(Value::Null)))
                .collect();
            Ok(json!({"values": values, "mode": cmd::get_clash_mode().await?}))
        }
        Request::PatchSettings { values } => {
            cmd::patch_verge_config(serde_json::from_value(json!(values)).map_err(invalid)?).await?;
            Ok(json!({"saved": true}))
        }
        Request::SetMode { mode } => {
            cmd::patch_clash_mode(mode).await?;
            Ok(json!({"applied": true}))
        }
        Request::GetDns => {
            let profiles = Config::profiles().await.latest_arc();
            let current = profiles.current.clone();
            let verge = Config::verge().await.latest_arc();
            let enabled = current
                .as_ref()
                .map(|uid| verge.dns_settings_for(uid).enabled)
                .unwrap_or(false);
            Ok(
                json!({"content": cmd::get_dns_config_content().await?.unwrap_or_default(), "uid": current, "enabled": enabled}),
            )
        }
        Request::SaveDns { content } => {
            let mapping = serde_yaml_ng::from_str(&content).map_err(invalid)?;
            cmd::save_dns_config(crate::ipc::YamlMapping(mapping)).await?;
            Ok(json!({"saved": true, "applied": false}))
        }
        Request::SetDnsOverride {
            uid,
            enabled,
            confirmation,
        } => encode(cmd::set_dns_override(uid, enabled, confirmation).await?),
        Request::ImportSubscription {
            url,
            name,
            interval,
            auto_update,
            with_proxy,
        } => {
            let option = crate::config::PrfOption {
                update_interval: Some(interval),
                allow_auto_update: Some(auto_update),
                with_proxy: Some(with_proxy),
                ..Default::default()
            };
            let uid = cmd::import_profile_named(url, Some(option), Some(name)).await?;
            Ok(json!({"saved": true, "uid": uid}))
        }
        Request::CreateLocalProfile { name, content } => {
            cmd::create_profile(
                cmd::ProfileCreate {
                    itype: Some("local".into()),
                    name: Some(name.into()),
                    ..Default::default()
                },
                Some(content),
            )
            .await?;
            Ok(json!({"saved": true}))
        }
        Request::SubscriptionDetails { uid } => {
            let item = profile(&uid).await?;
            let option = item.option.unwrap_or_default();
            Ok(
                json!({"uid": uid, "name": item.name, "url": item.url, "interval": option.update_interval.unwrap_or(1440),
                "autoUpdate": option.allow_auto_update.unwrap_or(true), "withProxy": option.with_proxy.unwrap_or(false),
                "usage": item.extra, "nextUpdate": cmd::get_next_update_time(uid).await?}),
            )
        }
        Request::PatchSubscription {
            uid,
            name,
            url,
            interval,
            auto_update,
            with_proxy,
        } => {
            let item = profile(&uid).await?;
            if item.itype.as_deref() != Some("remote") {
                if url.is_some() {
                    return Err(invalid("Local profiles do not have a subscription URL"));
                }
                cmd::patch_profile(
                    uid,
                    cmd::ProfilePatch {
                        name: Some(name.into()),
                        ..Default::default()
                    },
                )
                .await?;
                return Ok(json!({"saved": true}));
            }
            let mut option = item.option.unwrap_or_default();
            option.update_interval = Some(interval);
            option.allow_auto_update = Some(auto_update);
            option.with_proxy = Some(with_proxy);
            cmd::patch_profile(
                uid,
                cmd::ProfilePatch {
                    name: Some(name.into()),
                    url: url.map(Into::into),
                    option: Some(option),
                    ..Default::default()
                },
            )
            .await?;
            Ok(json!({"saved": true}))
        }
        Request::UpdateSubscription { uid } => {
            cmd::update_profile(uid, None).await?;
            Ok(json!({"updated": true}))
        }
        Request::ActivateProfile { uid } => {
            let outcome = cmd::patch_profiles_config_by_profile_index(uid.into()).await?;
            if !outcome.is_valid() {
                return Err(CommandFailure::coded("PROFILE_VALIDATION_FAILED", outcome));
            }
            Ok(json!({"applied":true}))
        }
        Request::DeleteProfile { uid } => {
            cmd::delete_profile(uid).await?;
            Ok(json!({"deleted": true}))
        }
        Request::ReorderProfile { uid, over } => {
            cmd::reorder_profile(uid, over).await?;
            Ok(json!({"saved": true}))
        }
        Request::TestLatency { names, url, timeout } => {
            use futures::StreamExt as _;
            let manager = CoreManager::global();
            let generation = manager.current_core_readiness_generation();
            if matches!(*manager.get_running_mode(), RunningMode::NotRunning) || generation.is_none() {
                return Err(CommandFailure::coded("CORE_NOT_READY", "No ready owned core"));
            }
            let view = cmd::get_proxy_view().await?;
            let targets = validate_latency_names(&view, &names)?;
            if manager.current_core_readiness_generation() != generation {
                return Err(CommandFailure::coded(
                    "CORE_CHANGED",
                    "Core changed before latency test",
                ));
            }
            // The group-delay endpoint clears fixed selections; per-node probes never select routes.
            let results: Vec<_> = futures::stream::iter(targets.into_iter().map(|node| {
                let url = url.clone();
                let name = node.name.clone();
                async move {
                    let delay = match &node.source {
                        crate::core::proxy_view::ProxyNodeSource::Core { .. } => {
                            Handle::mihomo().delay_proxy_by_name(&name, &url, timeout).await
                        }
                        crate::core::proxy_view::ProxyNodeSource::Provider {
                            provider_name,
                            proxy_name,
                        } => {
                            Handle::mihomo()
                                .healthcheck_node_in_provider(provider_name, proxy_name, &url, timeout)
                                .await
                        }
                    };
                    match delay {
                        Ok(value) => json!({"name":name,"delay":value.delay}),
                        Err(_) => json!({"name":name,"delay":null,"error":"PROBE_FAILED"}),
                    }
                }
            }))
            .buffer_unordered(4)
            .collect()
            .await;
            if manager.current_core_readiness_generation() != generation {
                return Err(CommandFailure::coded(
                    "CORE_CHANGED",
                    "Core changed during latency test",
                ));
            }
            Ok(json!({"results": results}))
        }
        Request::GetLogs { limit, level, query } => {
            #[cfg(unix)]
            {
                use std::sync::LazyLock;
                static LOG_STREAM: LazyLock<tokio::sync::Mutex<(Option<u64>, crate::native_logs::NativeLogStream)>> =
                    LazyLock::new(|| tokio::sync::Mutex::new((None, crate::native_logs::NativeLogStream::new())));
                let manager = CoreManager::global();
                let generation = manager
                    .current_core_readiness_generation()
                    .ok_or_else(|| CommandFailure::coded("CORE_NOT_READY", "No ready owned core"))?;
                let mode = *manager.get_running_mode();
                if matches!(mode, RunningMode::NotRunning) {
                    return Err(CommandFailure::coded("CORE_NOT_READY", "No ready owned core"));
                }
                let data = crate::native_data::NativeData::new_attach(
                    crate::utils::dirs::app_home_dir().map_err(invalid)?,
                    None,
                )
                .map_err(invalid)?;
                let (socket, _, source) = data.controller().await.map_err(|_| {
                    CommandFailure::coded("LOG_STREAM_UNAVAILABLE", "Cannot resolve owned Core controller")
                })?;
                use std::os::unix::fs::FileTypeExt as _;
                if !tokio::fs::symlink_metadata(&socket)
                    .await
                    .is_ok_and(|metadata| metadata.file_type().is_socket())
                {
                    return Err(CommandFailure::coded(
                        "LOG_STREAM_UNAVAILABLE",
                        "Core controller socket is unavailable",
                    ));
                }
                if !matches!(
                    (mode, source),
                    (RunningMode::Service, "service") | (RunningMode::Sidecar, "sidecar")
                ) || manager.current_core_readiness_generation() != Some(generation)
                {
                    return Err(CommandFailure::coded(
                        "CORE_CHANGED",
                        "Core changed before log subscription",
                    ));
                }
                let mut state = LOG_STREAM.lock().await;
                refresh_log_stream(&mut state, generation, &socket, || manager.get_clash_logs()).await?;
                if manager.current_core_readiness_generation() != Some(generation) {
                    state.1.reset();
                    state.0 = None;
                    return Err(CommandFailure::coded("CORE_CHANGED", "Core changed while reading logs"));
                }
                return Ok(state.1.read(limit, &level, &query));
            }
            #[cfg(not(unix))]
            {
                let lines = CoreManager::global()
                    .get_clash_logs()
                    .await
                    .map_err(|error| CommandFailure::coded("LOG_READ_FAILED", error))?;
                Ok(json!({"lines": filter_logs(lines, limit, &level, &query)}))
            }
        }
    }
}

#[cfg(unix)]
async fn refresh_log_stream<F, Fut>(
    state: &mut (Option<u64>, crate::native_logs::NativeLogStream),
    generation: u64,
    socket: &std::path::Path,
    read_history: F,
) -> CmdResult<()>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<Vec<String>>>,
{
    if state.0 != Some(generation) {
        state.1.reset();
        state.0 = Some(generation);
    }
    let connected = state.1.connect(socket).await.map_err(|_| {
        CommandFailure::coded("LOG_STREAM_UNAVAILABLE", "Cannot subscribe to Core logs")
    })?;
    if connected {
        let history = match read_history().await {
            Ok(history) => history,
            Err(_) => {
                state.1.reset();
                state.0 = None;
                return Err(CommandFailure::coded("LOG_READ_FAILED", "Cannot read Core log history"));
            }
        };
        state.1.seed(history);
    }
    Ok(())
}

pub(crate) fn filter_logs(lines: Vec<String>, limit: usize, level: &str, query: &str) -> Vec<String> {
    let query = query.to_lowercase();
    // JSON can expand one byte into six escaped bytes; stay below the 8 MiB wire cap.
    let mut budget = 1024 * 1024;
    let mut selected: Vec<_> = lines
        .into_iter()
        .rev()
        .filter(|line| {
            let lower = line.to_lowercase();
            lower.contains(&query) && (level == "all" || log_level(&lower) == Some(level))
        })
        .take(limit)
        .map(|line| line.chars().take(4096).collect::<String>())
        .take_while(|line| {
            if line.len() > budget {
                return false;
            }
            budget -= line.len();
            true
        })
        .collect();
    selected.reverse();
    selected
}

fn log_level(line: &str) -> Option<&str> {
    fn normalized(value: &str) -> Option<&str> {
        match value.trim_matches(['"', '\'', '[', ']', ':']) {
            "warning" | "warn" => Some("warn"),
            "error" | "fatal" => Some("error"),
            "info" => Some("info"),
            "debug" => Some("debug"),
            "trace" => Some("trace"),
            _ => None,
        }
    }
    let header = line.split(" msg=").next().unwrap_or(line);
    if let Some(level) = header.split_whitespace().find_map(|token| token.strip_prefix("level=")) {
        return normalized(level);
    }
    header
        .split_whitespace()
        .find_map(|token| {
            if token.starts_with('[') {
                normalized(token)
            } else {
                None
            }
        })
        .or_else(|| line.split_whitespace().next().and_then(normalized))
}

fn validate_latency_names<'a>(
    view: &'a crate::core::proxy_view::ProxyViewV1,
    names: &[String],
) -> CmdResult<Vec<&'a crate::core::proxy_view::ProxyNodeView>> {
    let mut seen = std::collections::HashSet::new();
    let mut targets = Vec::new();
    for name in names {
        let matching: Vec<_> = view.records.values().filter(|node| &node.name == name).collect();
        // Match the view's resolver: a core name wins; provider-only names must be unique.
        let node = matching
            .iter()
            .copied()
            .find(|node| matches!(node.source, crate::core::proxy_view::ProxyNodeSource::Core { .. }))
            .or_else(|| {
                if matching.len() == 1 {
                    matching.first().copied()
                } else {
                    None
                }
            });
        if !seen.insert(name)
            || node.is_none()
            || view
                .groups
                .iter()
                .chain(view.global.iter())
                .any(|group| &group.name == name)
            || node.is_some_and(|node| {
                matches!(
                    node.proxy_type,
                    tauri_plugin_mihomo::models::ProxyType::Direct | tauri_plugin_mihomo::models::ProxyType::Reject
                )
            })
        {
            return Err(CommandFailure::coded(
                "INVALID_LATENCY_TARGET",
                "Latency target is missing, ambiguous or not a proxy node",
            ));
        }
        targets.push(node.expect("validated target"));
    }
    Ok(targets)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[tokio::test]
    async fn workspace_logs_reconnect_reseeds_history_and_retains_new_stream_lines() -> anyhow::Result<()> {
        use futures::{SinkExt as _, StreamExt as _};
        use std::time::Duration;
        use tokio::net::UnixListener;
        use tokio_tungstenite::tungstenite::Message;

        let path = std::env::temp_dir().join(format!("tez-log-history-{}.sock", nanoid::nanoid!()));
        let listener = UnixListener::bind(&path)?;
        let (history_ready, wait_for_stream) = tokio::sync::oneshot::channel();
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            let (first, _) = listener.accept().await?;
            let mut first = tokio_tungstenite::accept_async(first).await?;
            for index in 0..1001 {
                first.send(Message::Text(
                    json!({"type":"info","payload":format!("old-stream-{index}")}).to_string().into(),
                )).await?;
            }
            first.close(None).await?;
            let (second, _) = listener.accept().await?;
            let mut second = tokio_tungstenite::accept_async(second).await?;
            second.send(Message::Text(
                json!({"type":"info","payload":"during-history-read"}).to_string().into(),
            )).await?;
            second.send(Message::Ping(vec![1].into())).await?;
            // A pong proves the client consumed the preceding text before history returns.
            while let Some(message) = second.next().await {
                if matches!(message?, Message::Pong(_)) {
                    let _ = history_ready.send(());
                    break;
                }
            }
            let _ = wait.await;
            anyhow::Ok(())
        });
        let mut state = (None, crate::native_logs::NativeLogStream::new());
        refresh_log_stream(&mut state, 7, &path, || async { Ok(vec!["[info] old-history".into()]) })
            .await.map_err(|error| anyhow::anyhow!("{error:?}"))?;
        for _ in 0..200 {
            if state.1.read(1000, "all", "")["streaming"] == false {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let old = state.1.read(1000, "all", "");
        assert_eq!(old["streaming"], false);
        assert_eq!(old["lines"].as_array().unwrap().len(), 1000);
        assert!(old["lines"][999].as_str().unwrap().ends_with("[info] old-stream-1000"));
        assert_eq!(old["truncated"], true);

        refresh_log_stream(&mut state, 7, &path, || async {
            tokio::time::timeout(Duration::from_secs(3), wait_for_stream).await??;
            Ok(vec!["[info] newly-read-history".into()])
        }).await.map_err(|error| anyhow::anyhow!("{error:?}"))?;
        refresh_log_stream(&mut state, 7, &path, || async {
            anyhow::bail!("an active stream must not refetch history")
        }).await.map_err(|error| anyhow::anyhow!("{error:?}"))?;
        let result = state.1.read(1000, "all", "");
        let lines = result["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], "[info] newly-read-history");
        assert!(lines[1].as_str().unwrap().ends_with("[info] during-history-read"));
        assert_eq!(result["gap"], true);
        assert_eq!(result["truncated"], false);
        assert_eq!(result["streaming"], true);
        state.1.reset();
        let _ = release.send(());
        server.await??;
        std::fs::remove_file(path)?;
        Ok(())
    }

    #[test]
    fn local_backup_commands_reject_traversal_and_are_classified() {
        for filename in ["../config.zip", "/tmp/a.zip", "a/b.zip", "a\\b.zip", "a.txt", "", ".zip\n"] {
            assert!(validate("native_delete_local_backup", json!({"filename":filename})).is_err());
        }
        assert!(validate("native_delete_local_backup", json!({"filename":"backup.zip"})).is_ok());
        assert!(!mutates("native_list_local_backups"));
        assert!(mutates("native_create_local_backup"));
        assert!(mutates("native_delete_local_backup"));
        for command in ["native_restore_local_backup", "native_delete_webdav_backup", "native_restore_webdav_backup"] {
            assert!(validate(command, json!({"filename":"../outside.zip"})).is_err());
        }
        assert!(validate("native_import_local_backup", json!({"source":"relative.zip"})).is_err());
        assert!(validate("native_export_local_backup", json!({"filename":"backup.zip", "destination":"relative.zip"})).is_err());
        assert!(validate("native_save_webdav_config", json!({"url":"https://user:secret@example.test/dav", "username":"a", "password":"b"})).is_err());
        assert!(!mutates("native_get_webdav_config"));
        assert!(!mutates("native_list_webdav_backups"));
    }
    #[test]
    fn workspace_rejects_arbitrary_commands_paths_and_unsafe_inputs() {
        for (command, params) in [
            ("native_patch_settings", json!({"values":{"startup_script":"bad"}})),
            ("native_patch_settings", json!({"values":{"verge_mixed_port":0}})),
            ("native_patch_settings", json!({"values":{"enable_system_proxy":null}})),
            (
                "native_import_subscription",
                json!({"url":"file:///private/secret","name":"test"}),
            ),
            ("native_set_mode", json!({"mode":"bad"})),
            (
                "native_test_latency",
                json!({"names":[],"url":"https://example.test","timeout":1000}),
            ),
            (
                "native_get_logs",
                json!({"limit":100,"level":"all","query":"","path":"/private/secret"}),
            ),
        ] {
            assert!(validate(command, params).is_err(), "{command}");
        }
    }
    #[test]
    fn workspace_classification_and_log_bounds_are_explicit() {
        assert!(!mutates("native_test_latency"));
        assert!(mutates("native_activate_profile"));
        assert!(
            validate(
                "native_test_latency",
                json!({"names":["a/b"],"url":"https://example.test","timeout":1000})
            )
            .is_ok()
        );
        assert_eq!(
            filter_logs(
                vec!["info first".into(), "warn second".into(), "warn third".into()],
                1,
                "warn",
                ""
            ),
            ["warn third"]
        );
        assert_eq!(
            filter_logs(
                vec![
                    "time=now level=info msg=warn.example.test".into(),
                    "time=now level=warning msg=slow".into()
                ],
                5,
                "warn",
                ""
            ),
            ["time=now level=warning msg=slow"]
        );
    }
    #[test]
    fn workspace_subscription_options_and_serialized_log_budget_are_bounded() {
        let params = json!({"url":"https://example.test/sub", "name":"Test", "interval":1440, "auto_update":false, "with_proxy":true});
        assert!(validate("native_import_subscription", params.clone()).is_ok());
        let mut bad = params;
        bad["interval"] = json!(1);
        assert!(validate("native_import_subscription", bad).is_err());
        assert!(validate("native_reorder_profile", json!({"uid":"same","over":"same"})).is_err());
        let lines = filter_logs(vec!["\u{0}".repeat(5000); 1000], 1000, "all", "");
        assert!(serde_json::to_vec(&json!({"lines": lines})).unwrap().len() < 8 * 1024 * 1024);
        assert!(
            validate(
                "native_patch_settings",
                json!({"values":{"verge_mixed_port":7897,"default_latency_timeout":5000}})
            )
            .is_ok()
        );
        assert!(
            validate(
                "native_patch_settings",
                json!({"values":{"default_latency_timeout":32768}})
            )
            .is_err()
        );
    }
    #[test]
    fn workspace_latency_requires_existing_unique_node_identities() {
        use crate::core::proxy_view::{ProxyViewBuilder, ProxyViewInput};
        let proxies = serde_json::from_value(json!({"proxies":{
            "Tokyo":{"name":"Tokyo","type":"Shadowsocks","udp":true,"history":[]},
            "DIRECT":{"name":"DIRECT","type":"Direct","udp":true,"history":[]}
        }}))
        .unwrap();
        let view = ProxyViewBuilder::build(ProxyViewInput {
            runtime_group_order: vec![],
            group_scopes: Default::default(),
            proxies,
            providers: None,
        });
        assert!(validate_latency_names(&view, &["Tokyo".into()]).is_ok());
        for names in [
            vec!["missing".into()],
            vec!["DIRECT".into()],
            vec!["Tokyo".into(), "Tokyo".into()],
        ] {
            assert!(validate_latency_names(&view, &names).is_err());
        }
    }
}
