use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read as _, Write as _},
    os::{
        fd::{AsRawFd as _, FromRawFd as _},
        unix::fs::{MetadataExt as _, OpenOptionsExt as _},
    },
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context as _, Result, ensure};
use serde::Deserialize;
use serde_json::json;

const MAX_BYTES: u64 = 4096;
const DIRECTORY_PREFIX: &str = "tez-native-recovery-";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RetryRequest {
    version: u8,
    sequence: u64,
    token: String,
    command: String,
}

pub(crate) struct RecoveryChannel {
    directory: File,
    token: String,
    last_sequence: u64,
    pending_response: Option<(u64, bool)>,
}

impl RecoveryChannel {
    pub(crate) fn from_env() -> Result<Option<Self>> {
        match (
            std::env::var_os("TEZ_NATIVE_RECOVERY_DIR"),
            std::env::var_os("TEZ_NATIVE_RECOVERY_TOKEN"),
        ) {
            (None, None) => Ok(None),
            (Some(root), Some(token)) => Ok(Some(Self::initialize(
                PathBuf::from(root),
                token
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("invalid recovery token"))?,
            )?)),
            _ => anyhow::bail!("incomplete recovery environment"),
        }
    }

    fn initialize(root: PathBuf, token: String) -> Result<Self> {
        ensure!(
            token.len() == 64
                && token
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            "invalid recovery token"
        );
        ensure!(
            root.parent() == Some(Path::new("/private/tmp"))
                && Path::new("/private/tmp").canonicalize()? == Path::new("/private/tmp"),
            "invalid recovery directory parent"
        );
        let suffix = root
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix(DIRECTORY_PREFIX))
            .context("invalid recovery directory identity")?;
        ensure!(
            suffix.len() == 36
                && suffix.bytes().enumerate().all(|(index, byte)| {
                    if [8, 13, 18, 23].contains(&index) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_hexdigit()
                    }
                }),
            "invalid recovery directory identity"
        );
        ensure!(root.canonicalize()? == root, "recovery directory traverses symlinks");
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&root)?;
        let metadata = directory.metadata()?;
        ensure!(
            metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o7777 == 0o700,
            "recovery directory ownership or permissions are invalid"
        );
        let path_metadata = fs::symlink_metadata(root)?;
        ensure!(
            path_metadata.is_dir() && metadata.dev() == path_metadata.dev() && metadata.ino() == path_metadata.ino(),
            "recovery directory changed during validation"
        );
        let mut channel = Self {
            directory,
            token,
            last_sequence: 0,
            pending_response: None,
        };
        for name in ["ready.json", "request.json", "response.json"] {
            ensure!(
                channel.open_control(name)?.is_none(),
                "recovery directory contains stale control files"
            );
        }
        channel.write_json("ready.json", json!({"version":1,"token":channel.token}))?;
        Ok(channel)
    }

    fn open_control(&self, name: &str) -> Result<Option<File>> {
        let name = CString::new(name)?;
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                return Ok(None);
            }
            return Err(error).context("cannot inspect recovery control file");
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file()
                && metadata.nlink() == 1
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.mode() & 0o7777 == 0o600
                && metadata.len() <= MAX_BYTES,
            "invalid recovery control file"
        );
        Ok(Some(file))
    }

    fn write_json(&mut self, name: &str, value: serde_json::Value) -> Result<()> {
        // Resolve every control path relative to the validated, held directory descriptor.
        let _ = self.open_control(name)?;
        let bytes = serde_json::to_vec(&value)?;
        ensure!(bytes.len() <= MAX_BYTES as usize, "recovery response exceeds limit");
        let temporary = CString::new(format!(".reply-{}.tmp", nanoid::nanoid!()))?;
        let target = CString::new(name)?;
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        ensure!(fd >= 0, "cannot create recovery response");
        let mut file = unsafe { File::from_raw_fd(fd) };
        let written = (|| -> Result<()> {
            ensure!(
                unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } == 0,
                "cannot secure recovery response"
            );
            file.write_all(&bytes)?;
            file.sync_all()?;
            ensure!(
                unsafe {
                    libc::renameat(
                        self.directory.as_raw_fd(),
                        temporary.as_ptr(),
                        self.directory.as_raw_fd(),
                        target.as_ptr(),
                    )
                } == 0,
                "cannot publish recovery response"
            );
            self.directory.sync_all()?;
            Ok(())
        })();
        if written.is_err() {
            unsafe { libc::unlinkat(self.directory.as_raw_fd(), temporary.as_ptr(), 0) };
        }
        written
    }

    fn next_sequence(&self) -> Result<Option<u64>> {
        let Some(file) = self.open_control("request.json")? else {
            return Ok(None);
        };
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= MAX_BYTES as usize, "recovery request exceeds limit");
        let request: RetryRequest = serde_json::from_slice(&bytes).context("invalid recovery request")?;
        ensure!(
            request.version == 1
                && request.sequence > 0
                && request.token == self.token
                && request.command == "retry-shutdown",
            "unsupported recovery request"
        );
        Ok((request.sequence > self.last_sequence).then_some(request.sequence))
    }

    fn poll_with(&mut self, cleanup: impl FnOnce() -> Result<()>) -> Result<Option<bool>> {
        let (sequence, safe) = if let Some(response) = self.pending_response {
            response
        } else {
            let Some(sequence) = self.next_sequence()? else {
                return Ok(None);
            };
            self.last_sequence = sequence;
            let safe =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(cleanup)).is_ok_and(|result| result.is_ok());
            self.pending_response = Some((sequence, safe));
            (sequence, safe)
        };
        self.write_json(
            "response.json",
            json!({"version":1,"sequence":sequence,"safeToExit":safe,"token":self.token}),
        )?;
        self.pending_response = None;
        Ok(Some(safe))
    }

    pub(crate) fn wait_and_retry(&mut self, mut cleanup: impl FnMut() -> Result<()>) -> Result<()> {
        loop {
            if matches!(self.poll_with(&mut cleanup), Ok(Some(true))) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let alphabet: &[char] = &[
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
            ];
            let id = nanoid::nanoid!(32, alphabet);
            let root = PathBuf::from(format!(
                "/private/tmp/{DIRECTORY_PREFIX}{}-{}-{}-{}-{}",
                &id[..8],
                &id[8..12],
                &id[12..16],
                &id[16..20],
                &id[20..]
            ));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            Self(root)
        }

        fn channel(&self) -> RecoveryChannel {
            RecoveryChannel::initialize(self.0.clone(), "a".repeat(64)).unwrap()
        }

        fn request(&self, sequence: u64, token: &str) {
            fs::write(
                self.0.join("request.json"),
                serde_json::to_vec(&json!({
                    "version":1,"sequence":sequence,"token":token,"command":"retry-shutdown"
                }))
                .unwrap(),
            )
            .unwrap();
            fs::set_permissions(self.0.join("request.json"), fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn retries_cleanup_only_for_new_authenticated_sequences() {
        let fixture = Fixture::new();
        let mut channel = fixture.channel();
        let ready: serde_json::Value =
            serde_json::from_slice(&fs::read(fixture.0.join("ready.json")).unwrap()).unwrap();
        assert_eq!(ready, json!({"version":1,"token":"a".repeat(64)}));
        assert_eq!(
            fs::metadata(fixture.0.join("ready.json")).unwrap().mode() & 0o777,
            0o600
        );
        fixture.request(1, &"a".repeat(64));
        assert_eq!(
            channel
                .poll_with(|| Err(anyhow::anyhow!("private cleanup detail")))
                .unwrap(),
            Some(false)
        );
        let response = fs::read_to_string(fixture.0.join("response.json")).unwrap();
        assert!(!response.contains("private cleanup detail"));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap()["safeToExit"],
            false
        );
        assert_eq!(channel.poll_with(|| panic!("must not replay cleanup")).unwrap(), None);
        fixture.request(2, &"a".repeat(64));
        assert_eq!(channel.poll_with(|| Ok(())).unwrap(), Some(true));
        let response: serde_json::Value =
            serde_json::from_slice(&fs::read(fixture.0.join("response.json")).unwrap()).unwrap();
        assert_eq!(
            response,
            json!({"version":1,"sequence":2,"safeToExit":true,"token":"a".repeat(64)})
        );
    }

    #[test]
    fn file_channel_waits_for_a_new_retry_after_cleanup_failure() {
        use std::sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        };
        use std::time::Instant;

        fn response(root: &Path, sequence: u64) -> serde_json::Value {
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                if let Ok(bytes) = fs::read(root.join("response.json"))
                    && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
                    && value["sequence"] == sequence
                {
                    return value;
                }
                assert!(Instant::now() < deadline, "recovery response deadline exceeded");
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        let fixture = Fixture::new();
        let mut channel = fixture.channel();
        let calls = Arc::new(AtomicUsize::new(0));
        let cleanup_calls = calls.clone();
        fixture.request(1, &"a".repeat(64));
        let worker = std::thread::spawn(move || {
            channel.wait_and_retry(|| {
                if cleanup_calls.fetch_add(1, Ordering::SeqCst) == 0 {
                    Err(anyhow::anyhow!("injected cleanup failure"))
                } else {
                    Ok(())
                }
            })
        });
        assert_eq!(response(&fixture.0, 1)["safeToExit"], false);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        fixture.request(2, &"a".repeat(64));
        assert_eq!(response(&fixture.0, 2)["safeToExit"], true);
        worker.join().unwrap().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn rejects_wrong_tokens_permissions_links_and_extra_fields_before_cleanup() {
        let fixture = Fixture::new();
        let mut channel = fixture.channel();
        fixture.request(1, &"b".repeat(64));
        assert!(channel.poll_with(|| panic!("wrong token")).is_err());
        fixture.request(1, &"a".repeat(64));
        fs::set_permissions(fixture.0.join("request.json"), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(channel.poll_with(|| panic!("wrong mode")).is_err());
        fs::remove_file(fixture.0.join("request.json")).unwrap();
        std::os::unix::fs::symlink("ready.json", fixture.0.join("request.json")).unwrap();
        assert!(channel.poll_with(|| panic!("symlink")).is_err());
        fs::remove_file(fixture.0.join("request.json")).unwrap();
        fs::write(
            fixture.0.join("request.json"),
            br#"{"version":1,"sequence":1,"token":"private","command":"retry-shutdown","path":"elsewhere"}"#,
        )
        .unwrap();
        fs::set_permissions(fixture.0.join("request.json"), fs::Permissions::from_mode(0o600)).unwrap();
        assert!(channel.poll_with(|| panic!("unknown field")).is_err());
        assert_eq!(channel.last_sequence, 0);
    }

    #[test]
    fn response_write_failure_retries_acknowledgment_without_repeating_cleanup() {
        let fixture = Fixture::new();
        let mut channel = fixture.channel();
        fixture.request(1, &"a".repeat(64));
        std::os::unix::fs::symlink("ready.json", fixture.0.join("response.json")).unwrap();
        assert!(channel.poll_with(|| Ok(())).is_err());
        fs::remove_file(fixture.0.join("response.json")).unwrap();
        assert_eq!(
            channel.poll_with(|| panic!("cleanup already confirmed")).unwrap(),
            Some(true)
        );
    }

    #[test]
    fn initialization_rejects_unsafe_directory_and_token() {
        let fixture = Fixture::new();
        assert!(RecoveryChannel::initialize(fixture.0.clone(), "A".repeat(64)).is_err());
        fs::set_permissions(&fixture.0, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(RecoveryChannel::initialize(fixture.0.clone(), "a".repeat(64)).is_err());
        fs::set_permissions(&fixture.0, fs::Permissions::from_mode(0o700)).unwrap();
        let _channel = fixture.channel();
        assert!(RecoveryChannel::initialize(fixture.0.clone(), "a".repeat(64)).is_err());
    }
}
