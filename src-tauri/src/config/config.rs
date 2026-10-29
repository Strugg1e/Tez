use super::{IClashTemp, IProfiles, IVerge, MixedPort};
use crate::core::notify::NoticeStatus;
use crate::{
    config::{PrfItem, profiles_append_item_to_safe, runtime::IRuntime},
    constants::{files, timing},
    core::{
        CoreManager,
        handle::{self, Handle},
        listener::MIXED_PORT_KEY,
        runtime_bundle::resolve_provider_path_conflicts,
        tray,
        validate::CoreConfigValidator,
    },
    enhance,
    process::AsyncHandler,
    utils::{dirs, help},
};
use anyhow::{Result, anyhow};
use backon::{ExponentialBuilder, Retryable as _};
use clash_verge_draft::Draft;
use clash_verge_logging::{Type, logging, logging_error};
use serde_yaml_ng::{Mapping, Value};
use smartstring::alias::String;
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};
use tokio::sync::{Mutex, MutexGuard, OnceCell};
use tokio::time::sleep;

pub(crate) struct Config {
    clash_config: Draft<IClashTemp>,
    verge_config: Draft<IVerge>,
    profiles_config: Draft<IProfiles>,
    runtime_config: Draft<IRuntime>,
}

static CONFIG_WRITE_LOCK: Mutex<()> = Mutex::const_new(());

impl Config {
    async fn global() -> &'static Self {
        static CONFIG: OnceCell<Config> = OnceCell::const_new();
        CONFIG
            .get_or_init(|| async {
                Self {
                    clash_config: Draft::new(IClashTemp::new().await),
                    verge_config: Draft::new(IVerge::new().await),
                    profiles_config: Draft::new(IProfiles::new().await),
                    runtime_config: Draft::new(IRuntime::default()),
                }
            })
            .await
    }

    pub async fn clash() -> Draft<IClashTemp> {
        Self::global().await.clash_config.clone()
    }

    pub async fn verge() -> Draft<IVerge> {
        Self::global().await.verge_config.clone()
    }

    pub async fn profiles() -> Draft<IProfiles> {
        Self::global().await.profiles_config.clone()
    }

    pub async fn runtime() -> Draft<IRuntime> {
        Self::global().await.runtime_config.clone()
    }

    #[cfg(all(feature = "native-host", target_os = "macos"))]
    pub(crate) async fn restore_native_runtime(yaml: &str) -> Result<()> {
        anyhow::ensure!(yaml.len() <= 4 * 1024 * 1024, "recovered runtime exceeds limit");
        let config: Mapping = serde_yaml_ng::from_str(yaml)?;
        let exists_keys = config.keys().filter_map(Value::as_str).map(String::from).collect();
        let runtime = Self::runtime().await;
        runtime.edit_draft(|draft| *draft = IRuntime { config: Some(config), exists_keys, ..Default::default() });
        runtime.apply();
        Ok(())
    }

    /// Serializes transactions sharing configuration draft layers.
    pub(crate) async fn lock_config_write() -> MutexGuard<'static, ()> {
        CONFIG_WRITE_LOCK.lock().await
    }

    pub(crate) fn try_lock_config_write() -> Result<MutexGuard<'static, ()>> {
        CONFIG_WRITE_LOCK
            .try_lock()
            .map_err(|_| anyhow!("configuration update is already running"))
    }

    pub async fn init_config_before_window() -> Result<()> {
        Self::ensure_default_profile_items().await?;

        let verge = Self::verge().await.latest_arc();
        clash_verge_i18n::sync_locale(verge.language.as_deref());

        Ok(())
    }

    pub(crate) async fn disable_tun_and_persist() -> Result<()> {
        let verge = Self::verge().await;
        verge.edit_draft(|draft| {
            draft.enable_tun_mode = Some(false);
        });
        verge.apply();
        verge.data_arc().save_file().await?;
        Handle::refresh_verge();
        let _ = tray::Tray::global().update_menu().await;
        Ok(())
    }

    pub async fn init_runtime_config() -> Result<()> {
        let fallback_applied = match Self::resolve_startup_mixed_port().await {
            Ok(applied) => applied,
            Err(error) => {
                Self::block_startup_core(&error);
                return Err(error);
            }
        };
        let validation_result = if fallback_applied {
            None
        } else {
            Self::generate_and_validate().await?
        };

        if let Some((msg_type, msg_content)) = validation_result {
            sleep(timing::STARTUP_ERROR_DELAY).await;
            handle::Handle::notice(msg_type, msg_content.as_str());
        }

        Self::runtime().await.apply();
        logging_error!(Type::Config, Self::sync_dns_override().await);

        Ok(())
    }

    async fn ensure_default_profile_items() -> Result<()> {
        let profiles = Self::profiles().await;
        if profiles.latest_arc().items.is_none() {
            logging!(
                warn,
                Type::Config,
                "Profile items 无法加载，跳过默认项初始化以保留现有配置文件"
            );
            return Ok(());
        }

        if profiles.latest_arc().get_item("Merge").is_err() {
            let merge_item = &mut PrfItem::from_merge(Some("Merge".into()));
            profiles_append_item_to_safe(&profiles, merge_item).await?;
        }
        if profiles.latest_arc().get_item("Script").is_err() {
            let script_item = &mut PrfItem::from_script(Some("Script".into()));
            profiles_append_item_to_safe(&profiles, script_item).await?;
        }
        Ok(())
    }

    async fn generate_and_validate() -> Result<Option<(NoticeStatus, String)>> {
        if let Err(err) = Self::generate().await {
            if !Self::generation_allows_fallback(&err) {
                return Err(err);
            }
            let error_msg: String = err.to_string().into();
            logging!(error, Type::Config, "生成运行时配置失败: {}", error_msg);
            CoreManager::global()
                .use_default_config(NoticeStatus::ConfigValidateBootError, &error_msg)
                .await?;
            return Ok(Some((NoticeStatus::ConfigValidateBootError, error_msg)));
        }
        logging!(debug, Type::Config, "生成运行时配置成功");

        // Run file first: startup rewrites it via use_default_config when validation fails.
        let config_result = match Self::runtime_config_yaml().await {
            Ok(yaml) => Self::write_runtime_file(&yaml).await.map(|_| yaml),
            Err(error) => Err(error),
        };

        if let Ok(yaml) = &config_result {
            logging!(debug, Type::Config, "开始验证配置");

            match CoreConfigValidator::global().validate_config_outcome_with(yaml).await {
                Ok(outcome) if outcome.is_valid() => {
                    logging!(debug, Type::Config, "配置验证成功");
                    Ok(None)
                }
                Ok(outcome) => {
                    let error_msg: String = outcome.to_string().into();
                    logging!(
                        warn,
                        Type::Config,
                        "[首次启动] 配置验证未通过，使用默认最小配置启动: {}",
                        error_msg
                    );
                    CoreManager::global()
                        .use_default_config(NoticeStatus::ConfigValidateBootError, &error_msg)
                        .await?;
                    Ok(Some((NoticeStatus::ConfigValidateBootError, error_msg)))
                }
                Err(err) => {
                    logging!(warn, Type::Config, "验证过程执行失败: {err:#}");
                    CoreManager::global()
                        .use_default_config(NoticeStatus::ConfigValidateProcessTerminated, "")
                        .await?;
                    Ok(Some((NoticeStatus::ConfigValidateProcessTerminated, String::new())))
                }
            }
        } else {
            let error_msg = config_result.err().map(|err| err.to_string()).unwrap_or_default();
            logging!(warn, Type::Config, "生成配置文件失败，使用默认配置: {error_msg}");
            CoreManager::global()
                .use_default_config(NoticeStatus::ConfigValidateError, "")
                .await?;
            Ok(Some((NoticeStatus::ConfigValidateError, String::new())))
        }
    }

    fn generation_allows_fallback(_error: &anyhow::Error) -> bool {
        #[cfg(feature = "native-host")]
        if _error.is::<crate::native_chain::ChainReapplyError>() {
            return false;
        }
        true
    }

    pub async fn generate_file() -> Result<PathBuf> {
        let yaml = Self::runtime_config_yaml().await?;
        Self::write_runtime_file(&yaml).await
    }

    pub(crate) async fn runtime_config_yaml() -> Result<std::string::String> {
        let runtime = Self::runtime().await;
        AsyncHandler::spawn_blocking(move || {
            let runtime_lastest = runtime.latest_arc();
            let runtime_data = runtime.data_arc();
            let config = runtime_lastest
                .config
                .as_ref()
                .or_else(|| runtime_data.config.as_ref())
                .ok_or_else(|| anyhow!("failed to generate runtime config, might need to restart application"))?;
            let yaml_str = serde_yaml_ng::to_string(config)?;
            Ok(format!("# Generated by Tez\n\n{}", yaml_str))
        })
        .await
        .map_err(|join| anyhow!("runtime serialization task failed: {join}"))?
    }

    pub(crate) async fn write_runtime_file(yaml: &str) -> Result<PathBuf> {
        let path = dirs::app_home_dir()?.join(files::RUNTIME_CONFIG);
        help::save_yaml_str(&path, yaml).await?;
        Ok(path)
    }

    pub async fn generate() -> Result<()> {
        let profiles = Self::profiles().await.latest_arc();
        Self::generate_with_profiles(&profiles).await
    }

    pub(crate) async fn generate_with_profiles(profiles: &IProfiles) -> Result<()> {
        let (config, exists_keys, logs, dns_override) = enhance::enhance(profiles).await?;
        let generated = IRuntime {
            config: Some(config),
            dns_override: Some(dns_override),
            exists_keys,
            chain_logs: logs,
        };
        Self::stage_generated_runtime(&Self::runtime().await, generated, profiles.current.as_deref(), &dirs::app_home_dir()?)
    }

    fn stage_generated_runtime(runtime: &Draft<IRuntime>, mut generated: IRuntime, _profile: Option<&str>, root: &Path) -> Result<()> {
        let config = generated.config.as_mut().ok_or_else(|| anyhow!("generated configuration is unavailable"))?;
        resolve_provider_path_conflicts(config, root)?;
        sanitize_tunnels_proxy(config);
        #[cfg(feature = "native-host")]
        {
            *config = crate::native_chain::reapply_active(config, _profile, root)?;
        }
        // Apply only to generated core config so the saved choice survives the next launch.
        if let Some(port) = MixedPort::session_fallback() {
            config.insert(MIXED_PORT_KEY.into(), port.into());
        }
        runtime.edit_draft(|draft| *draft = generated);
        Ok(())
    }

    pub async fn verify_config_initialization() {
        if Self::startup_core_block_reason().is_some() {
            return;
        }

        let backoff = ExponentialBuilder::default()
            .with_min_delay(std::time::Duration::from_millis(100))
            .with_max_delay(std::time::Duration::from_secs(2))
            .with_factor(2.0)
            .with_max_times(10);

        if let Err(e) = (|| async {
            if Self::runtime().await.latest_arc().config.is_some() {
                return Ok::<(), anyhow::Error>(());
            }
            Self::generate().await
        })
        .retry(backoff)
        .await
        {
            logging!(error, Type::Setup, "Config init verification failed: {e:#}");
        }
    }

    /// Commits drafts during exit/restart/shutdown so user changes are not lost.
    pub async fn apply_all_and_save_file() {
        logging!(debug, Type::Config, "save all draft data");
        let save_clash_task = AsyncHandler::spawn(|| async {
            let clash = Self::clash().await;
            clash.apply();
            logging_error!(Type::Config, clash.data_arc().save_config().await);
        });

        let save_verge_task = AsyncHandler::spawn(|| async {
            let verge = Self::verge().await;
            verge.apply();
            logging_error!(Type::Config, verge.data_arc().save_file().await);
        });

        let save_profiles_task = AsyncHandler::spawn(|| async {
            let _profile_write = super::profiles::PROFILE_WRITE_LOCK.lock().await;
            let profiles = Self::profiles().await;
            profiles.apply();
            logging_error!(Type::Config, profiles.data_arc().save_file().await);
        });

        let _ = tokio::join!(save_clash_task, save_verge_task, save_profiles_task);
        logging!(info, Type::Config, "save all draft data finished");
    }
}

fn sanitize_tunnels_proxy(config: &mut Mapping) {
    if !config
        .get("tunnels")
        .and_then(|v| v.as_sequence())
        .is_some_and(|t| tunnels_need_validation(t))
    {
        return;
    }

    let mut valid: HashSet<String> = HashSet::with_capacity(64);
    collect_names(config, "proxies", &mut valid);
    collect_names(config, "proxy-groups", &mut valid);

    valid.insert("DIRECT".into());
    valid.insert("REJECT".into());

    let Some(tunnels) = config.get_mut("tunnels").and_then(|v| v.as_sequence_mut()) else {
        return;
    };

    for item in tunnels {
        let Some(tunnel) = item.as_mapping_mut() else { continue };

        let Some(proxy_name) = tunnel.get("proxy").and_then(|v| v.as_str()) else {
            continue;
        };

        if proxy_name == "DIRECT" || proxy_name == "REJECT" {
            continue;
        }

        if !valid.contains(proxy_name) {
            tunnel.remove("proxy");
        }
    }
}

fn tunnels_need_validation(tunnels: &[Value]) -> bool {
    tunnels.iter().any(|item| {
        item.as_mapping()
            .and_then(|t| t.get("proxy"))
            .and_then(|p| p.as_str())
            .is_some_and(|name| name != "DIRECT" && name != "REJECT")
    })
}

fn collect_names(config: &Mapping, list_key: &str, out: &mut HashSet<String>) {
    let Some(Value::Sequence(seq)) = config.get(list_key) else {
        return;
    };

    for item in seq {
        let Value::Mapping(map) = item else {
            continue;
        };
        if let Some(Value::String(n)) = map.get("name")
            && !n.is_empty()
        {
            out.insert(n.into());
        }
    }
}

#[cfg(all(test, feature = "native-host"))]
mod native_chain_generation_tests {
    use super::*;
    use crate::native_chain::{Active, Chain, Store, links_match};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("tez-chain-generation-{}", nanoid::nanoid!(8)));
            std::fs::create_dir(&root).unwrap();
            let chain = Self::chain();
            Store {
                chains: vec![chain.clone()],
                active: Some(Active { id: chain.id.clone(), profile: "fixture".into(), chain, previous: Some("A".into()) }),
            }.save(&root).unwrap();
            Self(root)
        }

        fn chain() -> Chain {
            Chain { id: "fixture-chain".into(), name: "Two hops".into(), group: "Fixture".into(), nodes: vec!["A".into(), "B".into()] }
        }

        fn generated() -> Mapping {
            serde_yaml_ng::from_str("mode: rule\nproxies:\n- {name: A, type: socks5}\n- {name: B, type: socks5}\nproxy-groups:\n- {name: Fixture, type: select, proxies: [A, B]}\n").unwrap()
        }

        fn rebuild(&self, config: Mapping, profile: &str) -> Result<Mapping> {
            let runtime = Draft::new(IRuntime::default());
            Config::stage_generated_runtime(&runtime, IRuntime { config: Some(config), ..Default::default() }, Some(profile), &self.0)?;
            Ok(runtime.latest_arc().config.clone().unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { std::fs::remove_dir_all(&self.0).unwrap(); }
    }

    #[test]
    fn native_subscription_generation_retains_active_chain() {
        let fixture = Fixture::new();
        let next = fixture.rebuild(Fixture::generated(), "fixture").unwrap();
        assert!(links_match(&next, &Fixture::chain()), "subscription regeneration must retain both hops");
    }

    #[test]
    fn native_proxy_settings_generation_retains_active_chain() {
        let fixture = Fixture::new();
        let mut generated = Fixture::generated();
        generated.insert("allow-lan".into(), true.into());
        generated.insert("tun".into(), serde_yaml_ng::from_str::<Value>("{enable: false, mtu: 1400}").unwrap());
        let next = fixture.rebuild(generated, "fixture").unwrap();
        assert!(links_match(&next, &Fixture::chain()), "settings regeneration must retain both hops");
        assert_eq!(next["allow-lan"].as_bool(), Some(true));
        assert_eq!(next["tun"]["mtu"].as_u64(), Some(1400));
    }

    #[test]
    fn native_chain_generation_rejects_missing_node_or_group_without_publishing() {
        let fixture = Fixture::new();
        let original = crate::native_chain::change_links(&Fixture::generated(), &Fixture::chain(), true).unwrap();
        let runtime = Draft::new(IRuntime { config: Some(original.clone()), ..Default::default() });
        for section in ["proxies", "proxy-groups"] {
            let mut generated = Fixture::generated();
            generated.remove(section);
            let result = Config::stage_generated_runtime(&runtime, IRuntime { config: Some(generated), ..Default::default() }, Some("fixture"), &fixture.0);
            let error = result.expect_err(&format!("removing {section} must reject the rebuild instead of dropping the chain"));
            assert!(error.to_string().contains("CHAIN_REAPPLY_FAILED"));
            assert!(!Config::generation_allows_fallback(&error), "an invalid active chain must not start a single-hop default configuration");
            assert_eq!(runtime.data_arc().config.as_ref(), Some(&original));
            assert_eq!(runtime.latest_arc().config.as_ref(), Some(&original));
        }
        assert!(Config::generation_allows_fallback(&anyhow!("unrelated generation error")));
    }

    #[test]
    fn native_chain_generation_does_not_cross_profiles() {
        let fixture = Fixture::new();
        let next = fixture.rebuild(Fixture::generated(), "other").unwrap();
        assert!(!links_match(&next, &Fixture::chain()));
    }

    #[test]
    fn native_chain_generation_rejects_changed_group_or_conflicting_nodes() {
        let fixture = Fixture::new();
        for group in ["{name: Fixture, type: load-balance, proxies: [A, B]}", "{name: Fixture, type: select, proxies: [A]}"] {
            let mut generated = Fixture::generated();
            generated.insert("proxy-groups".into(), Value::Sequence(vec![serde_yaml_ng::from_str(group).unwrap()]));
            assert!(fixture.rebuild(generated, "fixture").is_err());
        }
        let mut generated = Fixture::generated();
        generated.get_mut("proxies").unwrap().as_sequence_mut().unwrap()
            .push(serde_yaml_ng::from_str("{name: A, type: socks5}").unwrap());
        assert!(fixture.rebuild(generated, "fixture").is_err());
        let mut generated = Fixture::generated();
        generated.get_mut("proxies").unwrap().as_sequence_mut().unwrap()[1]
            .as_mapping_mut().unwrap().insert("dialer-proxy".into(), "Other".into());
        assert!(fixture.rebuild(generated, "fixture").is_err());
    }

    #[test]
    fn native_chain_generation_supports_existing_links_and_include_all_groups() {
        let fixture = Fixture::new();
        let generated = crate::native_chain::change_links(&Fixture::generated(), &Fixture::chain(), true).unwrap();
        assert!(links_match(&fixture.rebuild(generated, "fixture").unwrap(), &Fixture::chain()));
        let mut generated = Fixture::generated();
        generated.insert("proxy-groups".into(), serde_yaml_ng::from_str("[{name: Fixture, type: select, include-all-proxies: true}]").unwrap());
        assert!(links_match(&fixture.rebuild(generated, "fixture").unwrap(), &Fixture::chain()));
        let mut store = Store::load(&fixture.0).unwrap();
        store.active.as_mut().unwrap().chain.group = "GLOBAL".into();
        store.save(&fixture.0).unwrap();
        let mut generated = Fixture::generated();
        generated.remove("proxy-groups");
        assert!(links_match(&fixture.rebuild(generated, "fixture").unwrap(), &Fixture::chain()));
    }

    #[test]
    fn native_chain_generation_rejects_unverified_filtered_membership() {
        let fixture = Fixture::new();
        for group in [
            "{name: Fixture, type: select, include-all-proxies: true, filter: '^A$'}",
            "{name: Fixture, type: select, proxies: [A, B], exclude-filter: '^B$'}",
            "{name: Fixture, type: select, proxies: [A, B], exclude-type: socks5}",
        ] {
            let mut generated = Fixture::generated();
            generated.insert("proxy-groups".into(), Value::Sequence(vec![serde_yaml_ng::from_str(group).unwrap()]));
            let error = fixture.rebuild(generated.clone(), "fixture").unwrap_err();
            assert!(error.to_string().contains("filtered strategy-group membership cannot be verified"));
            assert!(!Config::generation_allows_fallback(&error));
            assert!(fixture.rebuild(generated, "other").is_ok(), "inactive chains must not restrict another profile's groups");
        }
    }
}
