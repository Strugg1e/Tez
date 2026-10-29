use crate::{OwnerCredentials, OwnerSessionProof};
use anyhow::{Context as _, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read as _, Write as _},
    path::PathBuf,
};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    version: u8,
    channel: String,
    root: String,
    owner: String,
    generation: Option<u64>,
    token: String,
}

fn valid_token(token: &str) -> bool {
    token.len() == 64
        && token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn directory(credentials: &OwnerCredentials, create: bool) -> Result<Option<PathBuf>> {
    let root = PathBuf::from(&credentials.app_data_dir);
    ensure!(
        root.is_absolute() && root.canonicalize()? == root,
        "Session root must be canonical"
    );
    let directory = root.join("native-session");
    if create {
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt as _;
            builder.mode(0o700);
        }
        match builder.create(&directory) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    let metadata = match fs::symlink_metadata(&directory) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "Invalid session directory"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        ensure!(
            metadata.uid() == unsafe { platform_lib::geteuid() } && metadata.mode() & 0o777 == 0o700,
            "Unsafe session directory permissions"
        );
    }
    Ok(Some(directory))
}

fn checked_file(directory: &std::path::Path, name: &str) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(platform_lib::O_NOFOLLOW);
    }
    let file = options.open(directory.join(name))?;
    let metadata = file.metadata()?;
    ensure!(metadata.is_file() && metadata.len() <= 4096, "Invalid session receipt");
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        ensure!(
            metadata.uid() == unsafe { platform_lib::geteuid() }
                && metadata.mode() & 0o777 == 0o600
                && metadata.nlink() == 1,
            "Unsafe session receipt permissions"
        );
    }
    Ok(file)
}

/// Save before a start/claim request with generation=None, then confirm its returned generation.
pub fn save_owner_session(credentials: &OwnerCredentials, token: &str, generation: Option<u64>) -> Result<()> {
    ensure!(valid_token(token), "Invalid session token");
    let directory = directory(credentials, true)?.context("Session directory unavailable")?;
    let receipt = Receipt {
        version: 1,
        channel: crate::CHANNEL_IDENTITY.id.into(),
        root: credentials.app_data_dir.clone(),
        owner: crate::owner_key(&credentials.identity),
        generation,
        token: token.into(),
    };
    write_private(&directory, "owner.json", &receipt)
}

fn write_private(directory: &std::path::Path, name: &str, value: &impl Serialize) -> Result<()> {
    let sequence = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let temporary = directory.join(format!(".{name}-{}-{sequence}", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600).custom_flags(platform_lib::O_NOFOLLOW);
    }
    let result = (|| -> Result<()> {
        let mut file = options.open(&temporary)?;
        file.write_all(&serde_json::to_vec(value)?)?;
        file.sync_all()?;
        fs::rename(&temporary, directory.join(name))?;
        File::open(&directory)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

/// Reading never creates or repairs files. The service must still authenticate the returned proof.
pub fn load_owner_session(
    credentials: &OwnerCredentials,
    observed_generation: u64,
) -> Result<Option<OwnerSessionProof>> {
    let Some(directory) = directory(credentials, false)? else {
        return Ok(None);
    };
    let file = match checked_file(&directory, "owner.json") {
        Ok(file) => file,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take(4097).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 4096, "Session receipt exceeds limit");
    let receipt: Receipt = serde_json::from_slice(&bytes)?;
    ensure!(
        receipt.version == 1
            && receipt.channel == crate::CHANNEL_IDENTITY.id
            && receipt.root == credentials.app_data_dir
            && receipt.owner == crate::owner_key(&credentials.identity)
            && valid_token(&receipt.token),
        "Session receipt identity mismatch"
    );
    if receipt
        .generation
        .is_some_and(|generation| generation != observed_generation)
    {
        return Ok(None);
    }
    Ok(Some(OwnerSessionProof {
        generation: observed_generation,
        token: receipt.token,
    }))
}

pub fn forget_owner_session(credentials: &OwnerCredentials) -> Result<()> {
    forget(credentials, "owner.json")
}

pub fn forget_owner_core(credentials: &OwnerCredentials) -> Result<()> {
    forget(credentials, "core.json")
}

fn forget(credentials: &OwnerCredentials, name: &str) -> Result<()> {
    let Some(directory) = directory(credentials, false)? else {
        return Ok(());
    };
    match checked_file(&directory, name) {
        Ok(_) => fs::remove_file(directory.join(name))?,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) => {}
        Err(error) => return Err(error),
    }
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CoreChoice {
    root: String,
    owner: String,
    channel: String,
    digest: String,
}

pub fn save_owner_core(credentials: &OwnerCredentials, core_path: &str, digest: &str) -> Result<()> {
    ensure!(
        valid_token(digest)
            && std::path::Path::new(core_path)
                .file_name()
                .and_then(|name| name.to_str())
                == Some(format!("tez-{digest}").as_str()),
        "Only content-addressed core versions can be selected"
    );
    let directory = directory(credentials, true)?.context("Session directory unavailable")?;
    write_private(
        &directory,
        "core.json",
        &CoreChoice {
            root: credentials.app_data_dir.clone(),
            owner: crate::owner_key(&credentials.identity),
            channel: crate::CHANNEL_IDENTITY.id.into(),
            digest: digest.into(),
        },
    )
}

pub fn load_owner_core(credentials: &OwnerCredentials) -> Result<Option<PathBuf>> {
    let Some(directory) = directory(credentials, false)? else {
        return Ok(None);
    };
    let file = match checked_file(&directory, "core.json") {
        Ok(file) => file,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take(4097).read_to_end(&mut bytes)?;
    let choice: CoreChoice = serde_json::from_slice(&bytes)?;
    ensure!(
        choice.root == credentials.app_data_dir
            && choice.owner == crate::owner_key(&credentials.identity)
            && choice.channel == crate::CHANNEL_IDENTITY.id
            && valid_token(&choice.digest),
        "Core selection identity mismatch"
    );
    Ok(Some(
        crate::service_paths()?
            .core_dir()
            .join(format!("tez-{}", choice.digest)),
    ))
}
