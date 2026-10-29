use crate::OwnerCredentials;
use anyhow::{Context as _, Result, ensure};
use sha2::{Digest as _, Sha256};
use std::{
    fs,
    io::{Read as _, Write as _},
    os::unix::fs::{DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _},
    path::Path,
    process::Stdio,
    time::Duration,
};

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedOwnerCore {
    pub path: String,
    pub sha256: String,
    pub version: String,
}

/// Copies signed native Mach-O bytes only. Never executes the selected program or elevates.
pub async fn prepare_owner_core(
    credentials: &OwnerCredentials,
    source: &Path,
    version: &str,
) -> Result<PreparedOwnerCore> {
    ensure!(
        !version.is_empty()
            && version.len() <= 64
            && version
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b".-_".contains(&byte)),
        "Invalid version"
    );
    ensure!(
        source.is_absolute() && source.canonicalize()? == source,
        "Core source must be a canonical ordinary file"
    );
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(platform_lib::O_NOFOLLOW)
        .open(source)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.len() <= 64 * 1024 * 1024,
        "Core source exceeds limits"
    );
    let mut bytes = Vec::new();
    file.take(64 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() >= 32 && bytes.len() <= 64 * 1024 * 1024 && bytes[0..4] == [0xcf, 0xfa, 0xed, 0xfe],
        "Expected a 64-bit Mach-O core"
    );
    let cpu = u32::from_le_bytes(bytes[4..8].try_into()?);
    let expected = if cfg!(target_arch = "aarch64") {
        0x0100000c
    } else {
        0x01000007
    };
    ensure!(cpu == expected, "Core architecture does not match this client");
    let digest: String = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let root = Path::new(&credentials.app_data_dir);
    ensure!(root.canonicalize()? == root, "Core staging root must be canonical");
    let directory = root.join("native-upgrades");
    match fs::DirBuilder::new().mode(0o700).create(&directory) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(&directory)?;
    ensure!(
        metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && metadata.uid() == unsafe { platform_lib::geteuid() }
            && metadata.mode() & 0o777 == 0o700,
        "Unsafe core staging directory"
    );
    let target = directory.join(format!("tez-{digest}"));
    let replace = match fs::symlink_metadata(&target) {
        Ok(metadata) => {
            ensure!(
                metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { platform_lib::geteuid() }
                    && metadata.nlink() == 1
                    && metadata.mode() & 0o077 == 0,
                "Unsafe staged core"
            );
            crate::management::sha256_file(&target)? != digest
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(error) => return Err(error.into()),
    };
    if replace {
        let sequence = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        let temporary = directory.join(format!(".core-{}-{sequence}", std::process::id()));
        let written = (|| -> Result<()> {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(platform_lib::O_NOFOLLOW)
                .open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, &target)?;
            fs::File::open(&directory)?.sync_all()?;
            Ok(())
        })();
        if written.is_err() {
            let _ = fs::remove_file(temporary);
        }
        written?;
    }
    let metadata = fs::symlink_metadata(&target)?;
    ensure!(
        metadata.is_file()
            && !metadata.file_type().is_symlink()
            && metadata.uid() == unsafe { platform_lib::geteuid() }
            && metadata.nlink() == 1
            && metadata.mode() & 0o077 == 0
            && crate::management::sha256_file(&target)? == digest,
        "Unsafe staged core"
    );
    let mut command = tokio::process::Command::new("/usr/bin/codesign");
    command
        .args(["--verify", "--strict"])
        .arg(&target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let status = tokio::time::timeout(Duration::from_secs(5), command.status())
        .await
        .context("Signature check timed out")??;
    ensure!(status.success(), "Core signature validation failed");
    fs::set_permissions(&target, fs::Permissions::from_mode(0o700))?;
    Ok(PreparedOwnerCore {
        path: target.to_string_lossy().into_owned(),
        sha256: digest,
        version: version.into(),
    })
}
