use super::trusted_core_location::require_trusted_core_location;
use anyhow::{Context as _, Result, ensure};
use std::{
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub(super) struct SessionCoreCopy {
    pub original_core: String,
    pub original_ipc: String,
    directory: PathBuf,
}

impl SessionCoreCopy {
    pub async fn prepare(config: &crate::ClashConfig) -> Result<Self> {
        let source = std::fs::canonicalize(&config.core_config.core_path)?;
        require_trusted_core_location(&source)?;
        let root = crate::service_paths()?.core_dir();
        super::platform_security::ensure_private_service_directory(&root)?;
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let directory = root.join(format!("session-{nonce:x}"));
        std::fs::create_dir(&directory)?;
        let prepared = Self {
            original_core: config.core_config.core_path.clone(),
            original_ipc: config.core_config.core_ipc_path.clone(),
            directory,
        };
        super::platform_security::ensure_private_service_directory(&prepared.directory)?;
        let target = prepared.executable();
        let digest = crate::management::sha256_file(&source)?;
        ensure!(
            std::fs::metadata(&source)?.len() <= 64 * 1024 * 1024,
            "Core exceeds copy limit"
        );
        std::fs::copy(&source, &target)?;
        ensure!(
            crate::management::sha256_file(&target)? == digest,
            "Core copy differs from source"
        );
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700))?;
        for arguments in [
            vec!["--force", "--sign", "-", "--identifier", "app.tez.session.core"],
            vec!["--verify", "--strict"],
        ] {
            let mut command = tokio::process::Command::new("/usr/bin/codesign");
            command.args(arguments).arg(&target).kill_on_drop(true);
            let output = tokio::time::timeout(Duration::from_secs(10), command.output())
                .await
                .context("Core signing exceeded its deadline")??;
            ensure!(output.status.success(), "Session core signature was not confirmed");
        }
        require_trusted_core_location(&target)?;
        ensure!(
            crate::management::sha256_file(&source)? == digest,
            "Original core changed while copying"
        );
        Ok(prepared)
    }

    pub fn executable(&self) -> PathBuf {
        self.directory.join("TezCore")
    }
    pub fn ipc_path(&self) -> String {
        // Socket access is granted to the owner; the executable directory stays root-owned.
        PathBuf::from(&self.original_ipc)
            .with_file_name("control.sock")
            .to_string_lossy()
            .into_owned()
    }
}

impl Drop for SessionCoreCopy {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

pub(super) fn cleanup_orphans() -> Result<()> {
    let root = crate::service_paths()?.core_dir();
    if !root.exists() {
        return Ok(());
    }
    super::platform_security::ensure_private_service_directory(&root)?;
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(suffix) = name.to_str().and_then(|name| name.strip_prefix("session-")) else {
            continue;
        };
        if !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_hexdigit()) && entry.file_type()?.is_dir() {
            std::fs::remove_dir_all(entry.path())?;
        }
    }
    Ok(())
}
