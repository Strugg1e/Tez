use crate::{
    cmd::{self, CmdResult, coded_error},
    config::profiles::PROFILE_WRITE_LOCK,
    core::validate::ValidationOutcome,
};
use serde_json::{Value, json};

const MAX_CONTENT_BYTES: usize = 4 * 1024 * 1024;

// The managed host establishes exclusive backend ownership before calling this adapter.
pub(crate) async fn read(uid: String) -> CmdResult<Value> {
    let _profile_write = PROFILE_WRITE_LOCK.lock().await;
    let content = cmd::profile::read_profile_file_bounded(uid.clone(), Some(MAX_CONTENT_BYTES)).await?;
    check_content_size(&content)?;
    let revision = cmd::save_profile::profile_revision(&content);
    Ok(json!({"uid": uid, "content": content, "revision": revision}))
}

pub(crate) async fn save(uid: String, content: String, expected_revision: String) -> CmdResult<Value> {
    check_write_params(&content, &expected_revision)?;
    let outcome = cmd::save_profile::save_profile_file_with_revision(
        uid.clone(),
        Some(content.clone()),
        Some(&expected_revision),
    )
    .await?;
    Ok(save_result(&uid, &content, outcome))
}

pub(crate) fn check_write_params(content: &str, expected_revision: &str) -> CmdResult<()> {
    check_content_size(content)?;
    check_revision(expected_revision)
}

fn check_revision(revision: &str) -> CmdResult<()> {
    if revision.len() != 64
        || !revision
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(coded_error(
            "PROFILE_REVISION_INVALID",
            "Expected revision must be a lowercase SHA256 digest",
        ));
    }
    Ok(())
}

fn check_content_size(content: &str) -> CmdResult<()> {
    if content.len() > MAX_CONTENT_BYTES {
        return Err(coded_error(
            "PROFILE_CONTENT_TOO_LARGE",
            "Profile content exceeds the 4 MiB limit",
        ));
    }
    Ok(())
}

fn save_result(uid: &str, content: &str, outcome: ValidationOutcome) -> Value {
    let saved = outcome.is_valid();
    let revision = saved.then(|| cmd::save_profile::profile_revision(content));
    json!({"uid": uid, "saved": saved, "revision": revision, "validation": outcome})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::validate::ValidationSkipReason;

    #[test]
    fn only_valid_outcomes_report_a_saved_revision() {
        for outcome in [
            ValidationOutcome::invalid_from_message("invalid fixture"),
            ValidationOutcome::Busy,
            ValidationOutcome::Skipped {
                reason: ValidationSkipReason::Exiting,
            },
        ] {
            let result = save_result("fixture", "rules: []", outcome.clone());
            assert_eq!(result["saved"], false);
            assert_eq!(result["revision"], Value::Null);
            assert_eq!(result["validation"], json!(outcome));
        }
        let result = save_result("fixture", "rules: []", ValidationOutcome::Valid);
        assert_eq!(result["saved"], true);
        assert_eq!(result["revision"], cmd::save_profile::profile_revision("rules: []"));
    }

    #[test]
    fn content_limit_counts_bytes_and_accepts_the_boundary() {
        assert!(check_content_size(&"a".repeat(MAX_CONTENT_BYTES)).is_ok());
        let failure = check_content_size(&"a".repeat(MAX_CONTENT_BYTES + 1)).err();
        assert_eq!(
            failure.and_then(|failure| failure.code).as_deref(),
            Some("PROFILE_CONTENT_TOO_LARGE")
        );
    }

    #[test]
    fn revision_requires_a_complete_lowercase_sha256_digest() {
        assert!(check_revision(&cmd::save_profile::profile_revision("fixture")).is_ok());
        for revision in ["".to_owned(), "0".repeat(63), "A".repeat(64), "g".repeat(64)] {
            assert_eq!(
                check_revision(&revision)
                    .err()
                    .and_then(|failure| failure.code)
                    .as_deref(),
                Some("PROFILE_REVISION_INVALID")
            );
        }
    }
}
