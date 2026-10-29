mod channel;
mod core;
#[cfg(any(feature = "client", feature = "standalone"))]
pub mod execution;
#[cfg(any(feature = "client", feature = "standalone"))]
pub mod management;

#[cfg(feature = "client")]
mod client;

pub use channel::{
    CHANNEL_IDENTITY, ChannelIdentity, MACOS_APP_BUNDLE_ID, MACOS_SERVICE_ID, SERVICE_DISPLAY_NAME, SERVICE_SLUG,
    WINDOWS_SERVICE_NAME,
};
pub use core::structure::{
    ClaimCoreRequest, CoreIdentity, CoreSessionSnapshot, CoreUpgradeOutcome, UpgradeCoreRequest, parse_mihomo_version,
};
pub use core::{
    AuthenticatedRequest, AuthenticatedSessionRequest, ClashConfig, CoreAvailability, CoreConfig, CoreInspection,
    CoreRequirement, InstallationStatus, IpcCommand, MacosProxyConfig, OWNER_TOKEN_FILE_NAME, OwnerCredentials,
    OwnerIdentity, OwnerSessionHandle, OwnerSessionProof, ProtocolInfo, ProtocolVersion, ProxyApplyOutcome,
    RemoteProvider, RuntimeAsset, RuntimeBundle, RuntimeFileOutcome, RuntimeFileRequest, SERVICE_PROTOCOL_HEADER,
    SESSION_TOKEN_HEX_LEN, ServiceErrorCode, ServiceLifecycleState, ServiceStatusSnapshot, StageRejection,
    StageRuntimeOutcome, StartClashRequest, StartClashResult, WriterConfig, mihomo_ipc_path, owner_key,
};
pub use core::{CORE_DISPLACED_EXTENSION, CORE_STAGING_EXTENSION, OwnerPaths, ServicePaths, service_paths};

#[cfg(feature = "standalone")]
pub use core::{
    ActiveOwnerState, DesiredState, REPAIR_IN_PROGRESS_EXIT_CODE, ServiceOwnerGuard, ServiceRepairGate,
    acquire_service_owner, acquire_service_repair_gate, cleanup_stale_owner_state, flush_service_log,
    init_service_logging, load_active_owner, load_owner_desired_state, prepare_core_install_directory,
    prepare_service_install_directory, reconcile_service_startup, repair_active_owner_state,
    require_trusted_core_source, restore_desired_state, run_ipc_server, run_ipc_supervisor_until_shutdown,
    service_lifecycle_state, set_service_lifecycle_state, stop_ipc_server,
};

#[cfg(feature = "test")]
pub use core::test_owner_credentials;
#[cfg(all(feature = "test", unix))]
pub use core::test_owner_credentials_for_uid;
#[cfg(all(feature = "standalone", feature = "test"))]
pub use core::{CoreWatchdogTestConfig, set_core_watchdog_config_for_tests};

#[cfg(feature = "client")]
pub use client::*;

#[cfg(all(target_os = "macos", not(feature = "test"), not(feature = "development-channel")))]
pub static IPC_PATH: &str = "/var/run/tez-service/service.sock";
#[cfg(all(target_os = "macos", not(feature = "test"), feature = "development-channel", not(feature = "acceptance-channel")))]
pub static IPC_PATH: &str = "/var/run/tez-service-dev/service.sock";
#[cfg(all(target_os = "macos", not(feature = "test"), feature = "acceptance-channel"))]
pub static IPC_PATH: &str = "/var/run/tez-acceptance-service/service.sock";
#[cfg(all(
    unix,
    not(target_os = "macos"),
    not(feature = "test"),
    not(feature = "development-channel")
))]
pub static IPC_PATH: &str = "/run/tez-service/service.sock";
#[cfg(all(
    unix,
    not(target_os = "macos"),
    not(feature = "test"),
    feature = "development-channel"
))]
pub static IPC_PATH: &str = "/run/tez-service-dev/service.sock";
#[cfg(all(windows, not(feature = "test"), not(feature = "development-channel")))]
pub static IPC_PATH: &str = r"\\.\pipe\tez-service";
#[cfg(all(windows, not(feature = "test"), feature = "development-channel"))]
pub static IPC_PATH: &str = r"\\.\pipe\tez-service-dev";

#[cfg(all(feature = "test", unix))]
pub static IPC_PATH: &str = "/tmp/tez-service-ipc-test/service.sock";
#[cfg(all(feature = "test", windows))]
pub static IPC_PATH: &str = r"\\.\pipe\tez-service-test";

#[cfg(any(feature = "standalone", feature = "client"))]
pub static IPC_AUTH_EXPECT: &str =
    r#"A thing of beauty is a joy for ever. Its loveliness increases; it will never pass into nothingness."#;

pub static VERSION: &str = env!("CARGO_PKG_VERSION");
#[cfg(any(feature="standalone",feature="client"))]
pub fn identity_info() -> serde_json::Value {
    serde_json::json!({"channel":CHANNEL_IDENTITY.id,"serviceID":MACOS_SERVICE_ID,"serviceName":SERVICE_SLUG,
        "ipcPath":control_ipc_path(),"testFeature":cfg!(feature="test")})
}
#[cfg(any(feature="standalone",feature="client"))]
pub fn print_identity_if_requested() -> bool {
    if std::env::args_os().skip(1).collect::<Vec<_>>() != [std::ffi::OsString::from("--identity")] {return false;}
    println!("{}",identity_info());true
}
pub const PROTOCOL_EPOCH: u16 = 2;
pub const PROTOCOL_REVISION: u16 = 6;
pub const MIN_SUPPORTED_CLIENT_REVISION: u16 = 5;
pub const MIN_REQUIRED_SERVICE_REVISION: u16 = 5;
/// Revision that introduced `/clash/stage-runtime`.
/// This is a capability gate, not the minimum compatible service revision.
pub const MIN_SERVICE_REVISION_FOR_RUNTIME_STAGING: u16 = 2;
/// Capability revision for `/clash/runtime-file`.
pub const MIN_SERVICE_REVISION_FOR_RUNTIME_FILE_READ: u16 = 3;

/// Test-only endpoint override. Production builds never read this environment variable.
pub fn control_ipc_path() -> &'static str {
    #[cfg(all(feature = "test", unix))]
    if let Some(root) = isolated_test_root() {
        static PATH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
        return PATH.get_or_init(|| root.join("ipc/service.sock").to_string_lossy().into_owned());
    }
    IPC_PATH
}

#[cfg(all(feature = "test", unix))]
pub fn isolated_test_root() -> Option<std::path::PathBuf> {
    let root = std::path::PathBuf::from(std::env::var_os("TEZ_SERVICE_TEST_ROOT")?);
    let valid = root.parent() == Some(std::path::Path::new("/private/tmp"))
        && root
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix("tez-service-acceptance-"))
            .is_some_and(|suffix| {
                suffix.len() >= 12
                    && suffix.len() <= 48
                    && suffix.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            });
    assert!(valid, "Refusing invalid isolated service root");
    Some(root)
}
