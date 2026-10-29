use crate::{
    cmd::{CmdResult, CommandFailure},
    config::Config,
    core::{CoreManager, manager::RunningMode},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use serde_yaml_ng::{Mapping, Value as Yaml};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

pub const COMMANDS: &[&str] = &[
    "native_get_proxy_chains",
    "native_save_proxy_chain",
    "native_delete_proxy_chain",
    "native_activate_proxy_chain",
    "native_deactivate_proxy_chain",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Chain {
    pub id: String,
    pub name: String,
    pub group: String,
    pub nodes: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Active {
    pub id: String,
    pub profile: String,
    pub chain: Chain,
    pub previous: Option<String>,
}
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Store {
    pub chains: Vec<Chain>,
    pub active: Option<Active>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Save {
    chain: Chain,
}
fn error(code: &str, message: &str) -> CommandFailure {
    CommandFailure::coded(code, message)
}

#[derive(Debug)]
pub(crate) struct ChainReapplyError(String);

impl std::fmt::Display for ChainReapplyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "CHAIN_REAPPLY_FAILED: {}. Disable or repair the saved proxy chain before rebuilding this configuration", self.0)
    }
}
impl std::error::Error for ChainReapplyError {}

pub(crate) fn validate(command: &str, params: Value) -> CmdResult<()> {
    match command {
        "native_get_proxy_chains" | "native_deactivate_proxy_chain"
            if params.as_object().is_some_and(serde_json::Map::is_empty) =>
        {
            Ok(())
        }
        "native_save_proxy_chain" => {
            let save: Save =
                serde_json::from_value(params).map_err(|_| error("INVALID_PARAMS", "Expected a proxy chain"))?;
            let chain = save.chain;
            if chain.id.is_empty()
                || chain.id.len() > 128
                || chain.name.trim().is_empty()
                || chain.name.len() > 256
                || chain.group.is_empty()
                || chain.group.len() > 512
                || !(2..=16).contains(&chain.nodes.len())
                || chain.nodes.iter().any(|name| name.is_empty() || name.len() > 512)
                || chain.nodes.iter().collect::<HashSet<_>>().len() != chain.nodes.len()
            {
                return Err(error(
                    "INVALID_CHAIN",
                    "A chain needs a name, a group and 2–16 distinct nodes",
                ));
            }
            Ok(())
        }
        "native_delete_proxy_chain" | "native_activate_proxy_chain" => {
            let id: Id = serde_json::from_value(params).map_err(|_| error("INVALID_PARAMS", "Expected chain ID"))?;
            if id.id.is_empty() || id.id.len() > 128 {
                return Err(error("INVALID_PARAMS", "Invalid chain ID"));
            }
            Ok(())
        }
        _ => Err(error("INVALID_PARAMS", "Invalid chain command")),
    }
}

impl Store {
    pub(crate) fn decode(bytes: &[u8]) -> CmdResult<Self> {
        if bytes.len() > 512 * 1024 {
            return Err(error("CHAIN_STORAGE_FAILED", "Cannot read saved proxy chains"));
        }
        let store: Self = serde_json::from_slice(bytes)
            .map_err(|_| error("CHAIN_STORAGE_FAILED", "Cannot read saved proxy chains"))?;
        if store.chains.len() > 64
            || store.chains.iter().map(|c| &c.id).collect::<HashSet<_>>().len() != store.chains.len()
        {
            return Err(error("CHAIN_STORAGE_FAILED", "Invalid chain collection"));
        }
        for chain in store.chains.iter().chain(store.active.iter().map(|a| &a.chain)) {
            validate("native_save_proxy_chain", json!({"chain":chain}))?;
        }
        Ok(store)
    }

    pub(crate) fn load(root: &Path) -> CmdResult<Self> {
        let path = root.join("tez-proxy-chains.json");
        match std::fs::read(path) {
            Ok(bytes) => Self::decode(&bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            _ => Err(error("CHAIN_STORAGE_FAILED", "Cannot read saved proxy chains")),
        }
    }
    pub(crate) fn save(&self, root: &Path) -> CmdResult<()> {
        use std::io::Write as _;
        let path = root.join(format!(".tez-chains-{}", nanoid::nanoid!(8)));
        let result = (|| -> anyhow::Result<()> {
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt as _;
                options.mode(0o600);
            }
            let mut file = options.open(&path)?;
            file.write_all(&serde_json::to_vec_pretty(self)?)?;
            file.sync_all()?;
            std::fs::rename(&path, root.join("tez-proxy-chains.json"))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(path);
        }
        result.map_err(|_| error("CHAIN_STORAGE_FAILED", "Cannot save proxy chains"))
    }
    pub(crate) fn edit(&mut self, root: &Path, command: &str, params: Value, applied: bool) -> CmdResult<Value> {
        validate(command, params.clone())?;
        if command == "native_save_proxy_chain" {
            let chain = serde_json::from_value::<Save>(params).unwrap().chain;
            if self.active.as_ref().is_some_and(|a| a.id == chain.id) && applied {
                return Err(error("CHAIN_ACTIVE", "Disable the active chain before editing it"));
            }
            if let Some(existing) = self.chains.iter_mut().find(|c| c.id == chain.id) {
                *existing = chain;
            } else {
                if self.chains.len() >= 64 {
                    return Err(error("CHAIN_LIMIT", "At most 64 saved chains are supported"));
                }
                self.chains.push(chain);
            }
        } else {
            let id = serde_json::from_value::<Id>(params).unwrap().id;
            if self.active.as_ref().is_some_and(|a| a.id == id) {
                if applied {
                    return Err(error("CHAIN_ACTIVE", "Disable the active chain before deleting it"));
                }
                self.active = None;
            }
            self.chains.retain(|c| c.id != id);
        }
        self.save(root)?;
        Ok(json!({"saved":true}))
    }
}

pub(crate) fn available(config: &Mapping) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut duplicates = HashSet::new();
    let mut names = Vec::new();
    for proxy in config.get("proxies").and_then(Yaml::as_sequence).into_iter().flatten() {
        if let Some(name) = proxy.get("name").and_then(Yaml::as_str) {
            if seen.insert(name.to_owned()) {
                names.push(name.to_owned());
            } else {
                duplicates.insert(name.to_owned());
            }
        }
    }
    names.retain(|n| !duplicates.contains(n));
    names
}
pub(crate) fn links_match(config: &Mapping, chain: &Chain) -> bool {
    let Some(proxies) = config.get("proxies").and_then(Yaml::as_sequence) else {
        return false;
    };
    chain.nodes.iter().enumerate().all(|(index, name)| {
        let mut matches = proxies
            .iter()
            .filter(|p| p.get("name").and_then(Yaml::as_str) == Some(name));
        let Some(proxy) = matches.next() else { return false };
        if matches.next().is_some() {
            return false;
        }
        proxy.get("dialer-proxy").and_then(Yaml::as_str) == index.checked_sub(1).map(|i| chain.nodes[i].as_str())
    })
}
pub(crate) fn change_links(config: &Mapping, chain: &Chain, enable: bool) -> CmdResult<Mapping> {
    let names = available(config);
    if !chain.nodes.iter().all(|n| names.contains(n)) {
        return Err(error(
            "CHAIN_NODE_UNAVAILABLE",
            "Chain nodes need unique inline definitions in the current configuration",
        ));
    }
    if enable
        && config
            .get("proxies")
            .and_then(Yaml::as_sequence)
            .into_iter()
            .flatten()
            .any(|p| p.get("dialer-proxy").is_some())
    {
        return Err(error(
            "CHAIN_CONFLICT",
            "The configuration already contains dialer-proxy links; they were not changed",
        ));
    }
    if !enable && !links_match(config, chain) {
        return Err(error(
            "CHAIN_CHANGED",
            "The runtime chain changed; it was not overwritten",
        ));
    }
    let mut next = config.clone();
    for proxy in next
        .get_mut("proxies")
        .and_then(Yaml::as_sequence_mut)
        .into_iter()
        .flatten()
    {
        let Some(name) = proxy.get("name").and_then(Yaml::as_str) else {
            continue;
        };
        let Some(index) = chain.nodes.iter().position(|n| n == name) else {
            continue;
        };
        let mapping = proxy.as_mapping_mut().unwrap();
        mapping.remove("dialer-proxy");
        if enable && index > 0 {
            mapping.insert("dialer-proxy".into(), chain.nodes[index - 1].clone().into());
        }
    }
    Ok(next)
}

pub(crate) fn reapply_active(config: &Mapping, profile: Option<&str>, root: &Path) -> anyhow::Result<Mapping> {
    let store = Store::load(root).map_err(|failure| ChainReapplyError(failure.to_string()))?;
    let Some(active) = store.active.filter(|active| profile == Some(active.profile.as_str())) else {
        return Ok(config.clone());
    };
    let reject = |reason: &str| ChainReapplyError(format!("Cannot retain proxy chain '{}': {reason}", active.chain.name));
    let mut groups = config.get("proxy-groups").and_then(Yaml::as_sequence)
        .into_iter().flatten().filter(|group| group.get("name").and_then(Yaml::as_str) == Some(active.chain.group.as_str()));
    if let Some(group) = groups.next() {
        if groups.next().is_some()
            || !matches!(group.get("type").and_then(Yaml::as_str), Some("select" | "url-test" | "fallback"))
        {
            return Err(reject("its strategy group is unavailable or ambiguous").into());
        }
        let exit = active.chain.nodes.last().unwrap();
        let explicit = group.get("proxies").and_then(Yaml::as_sequence)
            .is_some_and(|members| members.iter().any(|member| member.as_str() == Some(exit.as_str())));
        let includes_inline = ["include-all", "include-all-proxies"].iter()
            .any(|field| group.get(*field).and_then(Yaml::as_bool) == Some(true));
        if !explicit && !includes_inline {
            return Err(reject("its exit node is no longer a member of the strategy group").into());
        }
        let has = |field| group.get(field).and_then(Yaml::as_str).is_some_and(|value| !value.is_empty());
        // Mihomo uses regexp2 filters; do not guess filtered membership with another regex engine.
        if (!explicit && includes_inline && has("filter")) || has("exclude-filter") || has("exclude-type") {
            return Err(reject("filtered strategy-group membership cannot be verified during rebuilding; use an unfiltered dedicated strategy group or disable the chain first").into());
        }
    } else if active.chain.group != "GLOBAL" {
        return Err(reject("its strategy group no longer exists").into());
    }
    if links_match(config, &active.chain) {
        return Ok(config.clone());
    }
    change_links(config, &active.chain, true).map_err(|failure| reject(&failure.detail).into())
}

async fn runtime_config() -> CmdResult<Mapping> {
    Config::runtime()
        .await
        .data_arc()
        .config
        .clone()
        .ok_or_else(|| error("CORE_NOT_READY", "Runtime configuration is not available"))
}
async fn apply_links(chain: &Chain, enable: bool) -> CmdResult<()> {
    let _config_write = Config::lock_config_write().await;
    let mut mutation = Ok(());
    let outcome = CoreManager::global()
        .update_runtime_config(|runtime| {
            match runtime
                .config
                .as_ref()
                .ok_or_else(|| error("CORE_NOT_READY", "No runtime configuration"))
                .and_then(|c| change_links(c, chain, enable))
            {
                Ok(next) => runtime.config = Some(next),
                Err(e) => mutation = Err(e),
            }
        })
        .await
        .map_err(|_| error("CHAIN_APPLY_FAILED", "Cannot apply proxy chain configuration"))?;
    mutation?;
    if !outcome.is_valid() {
        return Err(error("CHAIN_VALIDATION_FAILED", "Proxy chain validation did not pass"));
    }
    Ok(())
}

pub async fn dispatch(command: &str, params: Value) -> CmdResult<Value> {
    validate(command, params.clone())?;
    let root: PathBuf = crate::utils::dirs::app_home_dir()
        .map_err(|_| error("CHAIN_STORAGE_FAILED", "Application directory is unavailable"))?;
    let mut store = Store::load(&root)?;
    let profile = Config::profiles()
        .await
        .data_arc()
        .current
        .clone()
        .map(|v| v.to_string());
    let config = runtime_config().await.ok();
    let applied = store.active.as_ref().is_some_and(|a| {
        profile.as_deref() == Some(a.profile.as_str()) && config.as_ref().is_some_and(|c| links_match(c, &a.chain))
    });
    if command == "native_get_proxy_chains" {
        let groups = crate::cmd::get_proxy_view()
            .await
            .ok()
            .map(|view| {
                view.groups
                    .iter()
                    .chain(view.global.iter())
                    .filter(|g| {
                        matches!(
                            g.proxy_type,
                            tauri_plugin_mihomo::models::ProxyType::Selector
                                | tauri_plugin_mihomo::models::ProxyType::URLTest
                                | tauri_plugin_mihomo::models::ProxyType::Fallback
                        )
                    })
                    .map(|g| g.name.to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        return Ok(
            json!({"chains":store.chains,"activeId":store.active.as_ref().map(|a|&a.id),"applied":applied,"available":config.as_ref().map(available).unwrap_or_default(),"groups":groups}),
        );
    }
    if matches!(command, "native_save_proxy_chain" | "native_delete_proxy_chain") {
        return store.edit(&root, command, params, applied);
    }
    if matches!(*CoreManager::global().get_running_mode(), RunningMode::NotRunning)
        || CoreManager::global().current_core_readiness_generation().is_none()
    {
        return Err(error("CORE_NOT_READY", "An owned ready core is required"));
    }
    let mut selection_restored = true;
    if command == "native_activate_proxy_chain" {
        if applied {
            return Err(error("CHAIN_ACTIVE", "Disable the active chain first"));
        }
        let id = serde_json::from_value::<Id>(params).unwrap().id;
        let chain = store
            .chains
            .iter()
            .find(|c| c.id == id)
            .cloned()
            .ok_or_else(|| error("CHAIN_MISSING", "Saved proxy chain no longer exists"))?;
        let profile = profile.ok_or_else(|| {
            error(
                "CHAIN_PROFILE_REQUIRED",
                "Select a configuration before applying a chain",
            )
        })?;
        change_links(&runtime_config().await?, &chain, true)?;
        let view = crate::cmd::get_proxy_view().await?;
        let group = crate::native_control::validate_route(
            &view,
            &crate::native_control::RouteParams {
                group: chain.group.clone(),
                name: chain.nodes.last().unwrap().clone(),
            },
        )?;
        let previous = group.now.as_ref().map(ToString::to_string);
        apply_links(&chain, true).await?;
        if crate::native_control::dispatch(
            "native_select_route",
            json!({"group":chain.group,"name":chain.nodes.last()}),
        )
        .await
        .is_err()
        {
            let reverted = apply_links(&chain, false).await.is_ok();
            return Err(error(
                if reverted {
                    "CHAIN_SELECT_FAILED"
                } else {
                    "CHAIN_ROLLBACK_FAILED"
                },
                if reverted {
                    "Selection failed; chain configuration was reverted"
                } else {
                    "Selection failed and chain rollback is unconfirmed"
                },
            ));
        }
        store.active = Some(Active {
            id: chain.id.clone(),
            profile,
            chain,
            previous,
        });
    } else {
        let active = store
            .active
            .clone()
            .ok_or_else(|| error("CHAIN_MISSING", "No managed chain is active"))?;
        if !applied {
            return Err(error(
                "CHAIN_CHANGED",
                "Configuration changed; the saved chain was not applied or removed",
            ));
        }
        apply_links(&active.chain, false).await?;
        if let Some(previous) = active.previous {
            let selected = crate::cmd::get_proxy_view()
                .await
                .ok()
                .and_then(|view| {
                    view.groups
                        .into_iter()
                        .chain(view.global)
                        .find(|g| g.name.as_str() == active.chain.group)
                        .and_then(|g| g.now)
                })
                .map(|n| n.to_string());
            if selected.as_ref() == active.chain.nodes.last() {
                selection_restored = crate::native_control::dispatch(
                    "native_select_route",
                    json!({"group":active.chain.group,"name":previous}),
                )
                .await
                .is_ok();
            }
        }
        store.active = None;
    }
    let persisted = store.save(&root).is_ok();
    Ok(json!({"applied":true,"persisted":persisted,"selectionRestored":selection_restored}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn chain() -> Chain {
        Chain {
            id: "test".into(),
            name: "Two hops".into(),
            group: "Fixture".into(),
            nodes: vec!["A".into(), "B".into()],
        }
    }
    #[test]
    fn order_changes_only_selected_nodes_and_disable_restores_links() {
        let config: Mapping = serde_yaml_ng::from_str(
            "proxies:\n- {name: A, type: socks5}\n- {name: B, type: socks5}\n- {name: Other, type: socks5}\n",
        )
        .unwrap();
        let changed = change_links(&config, &chain(), true).unwrap();
        assert!(links_match(&changed, &chain()));
        assert_eq!(changed.get("proxies").unwrap()[1]["dialer-proxy"].as_str(), Some("A"));
        assert_eq!(change_links(&changed, &chain(), false).unwrap(), config);
        assert!(change_links(&changed, &chain(), true).is_err());
        let mut missing = chain();
        missing.nodes.push("Missing".into());
        assert!(change_links(&config, &missing, true).is_err());
        let mut duplicate = chain();
        duplicate.nodes = vec!["A".into(), "A".into()];
        assert!(validate("native_save_proxy_chain", json!({"chain":duplicate})).is_err());
    }
    #[test]
    fn drafts_persist_without_network_and_round_trip_deletion() {
        let root = std::env::temp_dir().join(format!("tez-chain-{}", nanoid::nanoid!(8)));
        std::fs::create_dir(&root).unwrap();
        let mut store = Store::default();
        store
            .edit(&root, "native_save_proxy_chain", json!({"chain":chain()}), false)
            .unwrap();
        assert_eq!(Store::load(&root).unwrap().chains[0].nodes, ["A", "B"]);
        store
            .edit(&root, "native_delete_proxy_chain", json!({"id":"test"}), false)
            .unwrap();
        assert!(Store::load(&root).unwrap().chains.is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }
}
