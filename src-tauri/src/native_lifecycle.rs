use std::{path::Path, time::Duration};

use anyhow::{Result, ensure};
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoreProcess {
    pub pid: u32,
    pub uid: i64,
    pub executable: String,
    pub started_at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Inspection {
    pub state: &'static str,
    pub source: &'static str,
    pub can_start: bool,
    pub reason: &'static str,
    pub core_pid: Option<u32>,
    pub service_generation: Option<u64>,
    pub service_started_at: Option<u64>,
    pub service_protocol: Option<String>,
    pub service_control_available: bool,
    pub processes: Vec<CoreProcess>,
}

#[derive(Clone, Copy, Debug)]
struct ServiceObservation {
    active: bool,
    generation: Option<u64>,
    pid: Option<u32>,
    desired_running: bool,
}

fn classify(service: Option<ServiceObservation>, processes: Option<Vec<CoreProcess>>) -> Inspection {
    let complete = processes.is_some();
    let processes = processes.unwrap_or_default();
    let mut result = Inspection {
        state: "unknown",
        source: "unknown",
        can_start: false,
        reason: "service-unavailable",
        core_pid: None,
        service_generation: None,
        service_started_at: None,
        service_protocol: None,
        service_control_available: false,
        processes,
    };
    if !complete {
        result.reason = "process-discovery-failed";
        return result;
    }
    if let Some(service) = service {
        result.core_pid = service.pid;
        result.service_generation = service.generation;
        result.source = "service";
        if service.active || service.pid.is_some() || service.generation.is_some() || service.desired_running {
            if service.active
                && service.pid.is_some()
                && service.generation.is_some()
                && result.processes.iter().any(|process| Some(process.pid) == service.pid)
            {
                result.state = "runningReadOnly";
                result.reason = "service-session-unavailable";
            } else {
                result.state = "recovering";
                result.reason = "service-transition-unresolved";
            }
            if result.processes.iter().any(|process| Some(process.pid) != service.pid) {
                result.state = "conflict";
                result.reason = "multiple-core-processes";
            }
            return result;
        }
        if result.processes.is_empty() {
            result.state = "stopped";
            result.reason = "idle-service";
            result.can_start = true;
            return result;
        }
    }
    if !result.processes.is_empty() {
        result.state = if result.processes.len() == 1 {
            "runningReadOnly"
        } else {
            "conflict"
        };
        result.source = "process";
        result.reason = if result.processes.len() == 1 {
            "external-core"
        } else {
            "multiple-core-processes"
        };
        result.core_pid = (result.processes.len() == 1).then(|| result.processes[0].pid);
    }
    result
}

fn parse_processes(output: &str) -> Result<Vec<CoreProcess>> {
    let mut result = Vec::new();
    for line in output.lines().filter(|line| !line.trim().is_empty()) {
        let mut fields = line.split_whitespace();
        let pid: u32 = fields.next().ok_or_else(|| anyhow::anyhow!("Missing PID"))?.parse()?;
        // macOS ps renders special UIDs such as nobody as signed values (-2).
        let uid: i64 = fields.next().ok_or_else(|| anyhow::anyhow!("Missing UID"))?.parse()?;
        ensure!(
            (i64::from(i32::MIN)..=i64::from(u32::MAX)).contains(&uid),
            "Invalid process UID"
        );
        let started: Vec<_> = fields.by_ref().take(5).collect();
        ensure!(started.len() == 5, "Incomplete process identity");
        let executable = fields.collect::<Vec<_>>().join(" ");
        ensure!(!executable.is_empty(), "Missing executable");
        let path = Path::new(&executable);
        let approved_name = path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
            name.strip_prefix("tez-").is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
                && clash_verge_service_ipc::service_paths().is_ok_and(|paths| path.parent() == Some(paths.core_dir().as_path()))
        });
        if !approved_name
            && !clash_verge_service_ipc::is_session_core_path(path)
            && !matches!(
                Path::new(&executable).file_name().and_then(|name| name.to_str()),
                Some("mihomo" | "mihomo-alpha" | "verge-mihomo" | "verge-mihomo-alpha")
            )
        {
            continue;
        }
        result.push(CoreProcess {
            pid,
            uid,
            executable,
            started_at: started.join(" "),
        });
        ensure!(result.len() <= 64, "Too many core processes");
    }
    Ok(result)
}

async fn processes() -> Result<Vec<CoreProcess>> {
    let mut command = tokio::process::Command::new("/bin/ps");
    command.args(["-axo", "pid=,uid=,lstart=,comm="]).kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(2), command.output()).await??;
    ensure!(
        output.status.success() && output.stdout.len() <= 2 * 1024 * 1024,
        "Process discovery failed"
    );
    let processes = parse_processes(std::str::from_utf8(&output.stdout)?)?;
    #[cfg(feature = "native-lifecycle-acceptance")]
    let processes = processes
        .into_iter()
        .filter(|process| {
            clash_verge_service_ipc::service_paths()
                .is_ok_and(|paths| Path::new(&process.executable).parent() == Some(paths.core_dir().as_path()))
                || clash_verge_service_ipc::is_session_core_path(Path::new(&process.executable))
        })
        .collect();
    Ok(processes)
}

pub(crate) async fn inspect() -> Inspection {
    let service = async {
        let root = crate::utils::dirs::app_home_dir().ok()?;
        let credentials = crate::core::owner_identity::current_owner_credentials_for_root(&root).ok()?;
        let response = tokio::time::timeout(
            Duration::from_secs(3),
            clash_verge_service_ipc::get_status(&credentials),
        )
        .await
        .ok()?
        .ok()?;
        if response.code != 0 {
            return None;
        }
        let status = response.data?;
        Some((
            ServiceObservation {
                active: status.is_active,
                generation: status.active_generation,
                pid: status.core_pid,
                desired_running: status.desired_core_should_be_running,
            },
            status.core_started_at,
        ))
    };
    let protocol = async {
        let response = tokio::time::timeout(Duration::from_secs(3), clash_verge_service_ipc::get_version()).await.ok()?.ok()?;
        (response.code == 0).then_some(response.data).flatten()
    };
    let (service, processes, protocol) = tokio::join!(service, processes(), protocol);
    let started_at = service.as_ref().and_then(|(_, started)| *started);
    let mut inspection = classify(service.map(|(observation, _)| observation), processes.ok());
    if inspection.source == "service" {
        inspection.service_started_at = started_at;
    }
    if let Some(protocol) = protocol {
        inspection.service_protocol = Some(protocol.protocol.header_value());
        inspection.service_control_available = protocol.supports_tez_lifecycle();
        if inspection.source == "service" && !inspection.service_control_available {
            inspection.can_start = false;
            inspection.reason = "service-upgrade-required";
        } else if inspection.reason == "service-unavailable" {
            inspection.reason = "service-status-unavailable";
        }
    }
    inspection
}

pub(crate) async fn inspect_managed() -> Inspection {
    let mut inspection = inspect().await;
    let generation = crate::core::service::active_service_session().ok().map(|proof| proof.generation);
    mark_managed_ownership(&mut inspection, generation);
    inspection
}

fn mark_managed_ownership(inspection: &mut Inspection, generation: Option<u64>) {
    if generation.is_none() || generation != inspection.service_generation || inspection.source != "service" {
        return;
    }
    match inspection.state {
        "runningReadOnly" => { inspection.state = "running"; inspection.reason = "owned-service"; }
        "recovering" => { inspection.state = "recoveringOwned"; inspection.reason = "owned-service-recovering"; }
        _ => {}
    }
}

pub(crate) async fn require_start_admission() -> Result<()> {
    let inspection = inspect().await;
    ensure!(
        inspection.can_start,
        "Core start admission refused: {}",
        inspection.reason
    );
    Ok(())
}

pub(crate) fn attach_to_snapshot(snapshot: &mut Value, inspection: &Inspection) {
    if let Some(core) = snapshot.get_mut("core").and_then(Value::as_object_mut) {
        core.insert(
            "lifecycle".into(),
            serde_json::to_value(inspection).expect("Serializable core inspection"),
        );
    }
}

pub fn run_automatic() -> Result<()> {
    crate::native_host::require_inherited_pipes()?;
    #[cfg(feature = "native-lifecycle-acceptance")]
    validate_acceptance_home()?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    let inspection = runtime.block_on(inspect());
    let restored = if inspection.state == "runningReadOnly" {
        runtime.block_on(crate::native_ownership::recover())
    } else {
        None
    };
    drop(runtime);
    #[cfg(feature = "native-lifecycle-acceptance")]
    ensure!(restored.is_some(), "Acceptance package only resumes its preseeded, isolated service core");
    if let Some(proof) = restored {
        match crate::native_managed::run_restored(proof) {
            Err(error) if crate::native_managed::activation_exit_code(&error).is_some() => {
                let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
                let mut current = runtime.block_on(inspect());
                if crate::native_managed::activation_exit_code(&error) == Some(73) {
                    current.reason = "client-already-running";
                }
                return crate::native_host::run_inspection_attach(current, true);
            }
            result => return result,
        }
    }
    automatic_with(
        inspection,
        crate::native_managed::run_stdio,
        || {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
            Ok(runtime.block_on(inspect()))
        },
        |inspection| crate::native_host::run_inspection_attach(inspection, true),
    )
}

#[cfg(feature = "native-lifecycle-acceptance")]
fn validate_acceptance_home() -> Result<()> {
    let home = std::path::PathBuf::from(std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("Acceptance HOME required"))?);
    let root = home.parent().ok_or_else(|| anyhow::anyhow!("Acceptance root required"))?;
    ensure!(home.file_name().is_some_and(|name| name == "home")
        && root.parent() == Some(Path::new("/private/tmp"))
        && root.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with("tez-package-acceptance-"))
        && home.canonicalize()? == home
        && crate::utils::dirs::app_home_dir()? == home.join("Library/Application Support/app.tez.client.dev"), "Refusing nonisolated acceptance HOME");
    Ok(())
}

fn automatic_with(
    inspection: Inspection,
    manage: impl FnOnce() -> Result<()>,
    reinspect: impl FnOnce() -> Result<Inspection>,
    observe: impl FnOnce(Inspection) -> Result<()>,
) -> Result<()> {
    if !inspection.can_start {
        return observe(inspection);
    }
    // The managed backend repeats all admission checks under its instance lock.
    match manage() {
        Ok(()) => Ok(()),
        Err(error) if crate::native_managed::activation_exit_code(&error).is_some() => {
            // These typed refusals precede all commands and network effects.
            let mut current = reinspect()?;
            if current.can_start {
                current.can_start = false;
                current.reason = if crate::native_managed::activation_exit_code(&error) == Some(73) {
                    "client-already-running"
                } else {
                    "managed-start-unavailable"
                };
            }
            observe(current)
        }
        Err(error) => Err(error),
    }
}

pub fn run_inspection() -> Result<()> {
    crate::native_host::require_inherited_pipes()?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    crate::native_host::run_inspection_attach(runtime.block_on(inspect()), false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_control_requires_the_current_service_session() {
        let mut inspection = classify(Some(ServiceObservation {
            active: true, generation: Some(42), pid: Some(123), desired_running: true,
        }), Some(vec![process(123)]));
        mark_managed_ownership(&mut inspection, Some(41));
        assert_eq!(inspection.state, "runningReadOnly");
        mark_managed_ownership(&mut inspection, Some(42));
        assert_eq!(inspection.state, "running");
        assert_eq!(inspection.reason, "owned-service");
        let mut idle = classify(Some(idle()), Some(vec![]));
        mark_managed_ownership(&mut idle, None);
        assert_eq!(idle.state, "stopped");
    }

    #[test]
    fn upgraded_content_addressed_core_is_discovered_in_approved_directory() -> Result<()> {
        let name = format!("tez-{}", "a".repeat(64));
        let path = clash_verge_service_ipc::service_paths()?.core_dir().join(&name);
        let processes = parse_processes(&format!("123 501 Wed Oct 28 17:33:02 2026 {}\n", path.display()))?;
        assert_eq!(processes.len(), 1);
        assert_eq!(processes[0].pid, 123);
        assert!(parse_processes(&format!("123 501 Wed Oct 28 17:33:02 2026 /private/tmp/{name}\n"))?.is_empty());
        Ok(())
    }

    fn idle() -> ServiceObservation {
        ServiceObservation {
            active: false,
            generation: None,
            pid: None,
            desired_running: false,
        }
    }
    fn process(pid: u32) -> CoreProcess {
        CoreProcess {
            pid,
            uid: 501,
            executable: "/Applications/Tez.app/Contents/Helpers/verge-mihomo".into(),
            started_at: "Wed Oct 28 17:33:02 2026".into(),
        }
    }
    #[test]
    fn only_a_confirmed_idle_service_and_empty_process_list_allow_start() {
        assert!(classify(Some(idle()), Some(vec![])).can_start);
        for service in [
            None,
            Some(ServiceObservation {
                active: true,
                generation: Some(42),
                pid: Some(123),
                desired_running: true,
            }),
            Some(ServiceObservation {
                desired_running: true,
                ..idle()
            }),
            Some(ServiceObservation {
                generation: Some(42),
                ..idle()
            }),
        ] {
            assert!(!classify(service, Some(vec![])).can_start);
        }
        assert!(!classify(Some(idle()), None).can_start);
        assert!(!classify(Some(idle()), Some(vec![process(123)])).can_start);
    }
    #[test]
    fn an_existing_service_core_is_observed_not_replaced() {
        let current = ServiceObservation {
            active: true,
            generation: Some(42),
            pid: Some(123),
            desired_running: true,
        };
        let inspection = classify(Some(current), Some(vec![process(123)]));
        assert_eq!(inspection.state, "runningReadOnly");
        assert_eq!(inspection.reason, "service-session-unavailable");
        assert!(!inspection.can_start);
        assert_eq!(
            classify(Some(current), Some(vec![process(123), process(456)])).state,
            "conflict"
        );
    }
    #[test]
    fn process_discovery_does_not_match_substrings_or_command_arguments() {
        let output = "123 501 Wed Oct 28 17:33:02 2026 /Applications/Tez Client.app/Contents/Helpers/verge-mihomo\n124 501 Wed Oct 28 17:33:02 2026 /usr/bin/mihomo-monitor\n125 501 Wed Oct 28 17:33:02 2026 /usr/bin/grep\n";
        let parsed = parse_processes(output).unwrap();
        assert_eq!(
            parsed,
            vec![CoreProcess {
                executable: "/Applications/Tez Client.app/Contents/Helpers/verge-mihomo".into(),
                ..process(123)
            }]
        );
        assert!(parse_processes("broken process output").is_err());
    }

    #[test]
    fn process_discovery_accepts_macos_signed_special_uids() {
        let output = "80816 -2 Wed Oct 28 18:20:01 2026 /usr/libexec/mdworker_shared\n123 0 Wed Oct 28 17:33:02 2026 /Library/Application Support/service/cores/verge-mihomo\n";
        let parsed = parse_processes(output).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].pid, 123);
        assert_eq!(parsed[0].uid, 0);
        let special = parse_processes("123 -2 Wed Oct 28 17:33:02 2026 /usr/local/bin/mihomo\n").unwrap();
        assert_eq!(special[0].uid, -2);
    }

    #[test]
    fn active_service_without_its_process_stays_unresolved() {
        let inspection = classify(
            Some(ServiceObservation {
                active: true,
                generation: Some(42),
                pid: Some(123),
                desired_running: true,
            }),
            Some(vec![]),
        );
        assert_eq!(inspection.state, "recovering");
        assert!(!inspection.can_start);
    }
    #[test]
    fn inspection_exposes_no_session_token_or_mutation_capability() {
        let value = serde_json::to_string(&classify(Some(idle()), Some(vec![]))).unwrap();
        assert!(!value.contains("token"));
        assert!(!value.contains("native_core_stop"));
    }

    #[test]
    fn automatic_discovery_never_initializes_management_for_observed_cores() {
        for inspection in [
            classify(None, None),
            classify(None, Some(vec![process(123)])),
            classify(Some(idle()), Some(vec![process(123), process(456)])),
        ] {
            automatic_with(
                inspection,
                || panic!("must not initialize management"),
                || panic!("must not repeat discovery"),
                |observed| {
                    assert!(!observed.can_start);
                    Ok(())
                },
            )
            .unwrap();
        }
    }

    #[test]
    fn automatic_management_errors_after_admission_do_not_fall_back_or_retry() {
        let error = automatic_with(
            classify(Some(idle()), Some(vec![])),
            || anyhow::bail!("cleanup unresolved"),
            || panic!("must not retry"),
            |_| panic!("must not hide cleanup failure"),
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "cleanup unresolved");
    }

    #[test]
    fn refused_admission_reinspects_and_observes_without_replacing_a_new_owner() {
        let active = classify(
            Some(ServiceObservation {
                active: true,
                generation: Some(43),
                pid: Some(456),
                desired_running: true,
            }),
            Some(vec![process(456)]),
        );
        automatic_with(
            classify(Some(idle()), Some(vec![])),
            || Err(anyhow::anyhow!(crate::native_managed::ActivationRefused::Preflight)),
            || Ok(active),
            |inspection| {
                assert_eq!(inspection.core_pid, Some(456));
                assert_eq!(inspection.service_generation, Some(43));
                assert!(!inspection.can_start);
                Ok(())
            },
        )
        .unwrap();
        automatic_with(
            classify(Some(idle()), Some(vec![])),
            || {
                Err(anyhow::anyhow!(
                    crate::native_managed::ActivationRefused::InstanceUnavailable
                ))
            },
            || Ok(classify(Some(idle()), Some(vec![]))),
            |inspection| {
                assert_eq!(inspection.reason, "client-already-running");
                assert!(!inspection.can_start);
                Ok(())
            },
        )
        .unwrap();
    }
}
