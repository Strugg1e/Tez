use crate::{
    cmd::{CmdResult, CommandFailure},
    config::Config,
};
use serde::Deserialize;
use serde_json::{Value, json};

pub const COMMANDS: &[&str] = &["native_get_proxy_config", "native_patch_proxy_config"];
pub const CORE_FIELDS: &[&str] = &["tun", "allow-lan", "ipv6", "unified-delay", "log-level"];
pub const TUN_FIELDS: &[&str] = &[
    "stack",
    "device",
    "auto-route",
    "auto-detect-interface",
    "strict-route",
    "dns-hijack",
    "dns-mode",
    "mtu",
    "route-exclude-address",
];

fn invalid() -> CommandFailure {
    CommandFailure::coded(
        "INVALID_PROXY_CONFIG",
        "Unsupported proxy configuration or invalid field value",
    )
}

pub(crate) fn validate_values(values: &serde_json::Map<String, Value>) -> CmdResult<()> {
    if values.is_empty() || values.keys().any(|key| !CORE_FIELDS.contains(&key.as_str())) {
        return Err(invalid());
    }
    for (key, value) in values {
        match key.as_str() {
            "allow-lan" | "ipv6" | "unified-delay" if value.is_boolean() => {}
            "log-level"
                if value
                    .as_str()
                    .is_some_and(|v| ["silent", "error", "warning", "info", "debug", "trace"].contains(&v)) => {}
            "tun" => {
                let tun = value.as_object().ok_or_else(invalid)?;
                if tun.is_empty() || tun.keys().any(|key| !TUN_FIELDS.contains(&key.as_str())) {
                    return Err(invalid());
                }
                for (key, value) in tun {
                    let valid = match key.as_str() {
                        "stack" => value
                            .as_str()
                            .is_some_and(|v| ["system", "gvisor", "mixed", "mips"].contains(&v)),
                        "dns-mode" => value
                            .as_str()
                            .is_some_and(|v| ["", "disabled", "native", "hijack"].contains(&v)),
                        "device" => value.as_str().is_some_and(|v| {
                            !v.is_empty()
                                && v.len() <= 64
                                && v.bytes()
                                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
                        }),
                        "mtu" => value.as_u64().is_some_and(|v| (1..=65535).contains(&v)),
                        "auto-route" | "auto-detect-interface" | "strict-route" => value.is_boolean(),
                        "dns-hijack" => value.as_array().is_some_and(|v| {
                            v.len() <= 64
                                && v.iter().all(|v| {
                                    v.as_str().is_some_and(|s| {
                                        !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control)
                                    })
                                })
                        }),
                        "route-exclude-address" => value
                            .as_array()
                            .is_some_and(|v| v.len() <= 256 && v.iter().all(|v| v.as_str().is_some_and(valid_cidr))),
                        _ => false,
                    };
                    if !valid {
                        return Err(invalid());
                    }
                }
            }
            _ => return Err(invalid()),
        }
    }
    Ok(())
}

fn valid_cidr(value: &str) -> bool {
    let Some((address, prefix)) = value.split_once('/') else {
        return false;
    };
    let Ok(address) = address.parse::<std::net::IpAddr>() else {
        return false;
    };
    prefix
        .parse::<u8>()
        .is_ok_and(|prefix| prefix <= if address.is_ipv4() { 32 } else { 128 })
}

pub(crate) fn parse(command: &str, params: Value) -> CmdResult<Option<serde_json::Map<String, Value>>> {
    if command == "native_get_proxy_config" && params.as_object().is_some_and(serde_json::Map::is_empty) {
        return Ok(None);
    }
    if command != "native_patch_proxy_config" {
        return Err(invalid());
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Patch {
        values: serde_json::Map<String, Value>,
    }
    let patch: Patch = serde_json::from_value(params).map_err(|_| invalid())?;
    validate_values(&patch.values)?;
    Ok(Some(patch.values))
}

pub(crate) fn project(config: &serde_yaml_ng::Mapping) -> Value {
    let raw = serde_json::to_value(config).unwrap_or(Value::Null);
    let mut values = serde_json::Map::new();
    for key in CORE_FIELDS {
        if let Some(value) = raw.get(*key) {
            if *key == "tun" {
                let tun: serde_json::Map<_, _> = TUN_FIELDS
                    .iter()
                    .filter_map(|key| value.get(*key).map(|v| ((*key).into(), v.clone())))
                    .collect();
                values.insert((*key).into(), json!(tun));
            } else {
                values.insert((*key).into(), value.clone());
            }
        }
    }
    json!({"values":values})
}

pub(crate) fn yaml_mapping(values: serde_json::Map<String, Value>) -> CmdResult<serde_yaml_ng::Mapping> {
    // JSON serialization preserves scalar numbers with serde_json's arbitrary_precision feature.
    serde_yaml_ng::from_slice(&serde_json::to_vec(&values).map_err(invalid_error)?).map_err(invalid_error)
}

pub(crate) fn preserve_tun_fields(
    base: &serde_yaml_ng::Mapping,
    mut patch: serde_yaml_ng::Mapping,
) -> serde_yaml_ng::Mapping {
    if let Some(fields) = patch.get("tun").and_then(serde_yaml_ng::Value::as_mapping) {
        let mut tun = base
            .get("tun")
            .and_then(serde_yaml_ng::Value::as_mapping)
            .cloned()
            .unwrap_or_default();
        tun.extend(fields.clone());
        patch.insert("tun".into(), tun.into());
    }
    patch
}

pub async fn dispatch(command: &str, params: Value) -> CmdResult<Value> {
    match parse(command, params)? {
        None => Ok(project(&Config::clash().await.data_arc().0)),
        Some(values) => {
            let mapping = preserve_tun_fields(&Config::clash().await.data_arc().0, yaml_mapping(values)?);
            crate::cmd::patch_clash_config(crate::ipc::YamlMapping(mapping)).await?;
            Ok(json!({"saved":true,"applied":true}))
        }
    }
}
fn invalid_error(_: impl std::fmt::Display) -> CommandFailure {
    invalid()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn numeric_proxy_values_remain_yaml_scalars() {
        let mapping = yaml_mapping(serde_json::from_value(json!({"tun":{"mtu":1400}})).unwrap()).unwrap();
        assert_eq!(mapping.get("tun").unwrap()["mtu"].as_u64(), Some(1400));
        let base = serde_yaml_ng::from_str(
            "tun:\n  enable: true\n  stack: system\n  mtu: 1500\n  route-address: [10.0.0.0/8]\n",
        )
        .unwrap();
        let merged = preserve_tun_fields(&base, mapping);
        assert_eq!(merged["tun"]["enable"].as_bool(), Some(true));
        assert_eq!(merged["tun"]["stack"].as_str(), Some("system"));
        assert_eq!(merged["tun"]["mtu"].as_u64(), Some(1400));
        assert_eq!(merged["tun"]["route-address"][0].as_str(), Some("10.0.0.0/8"));
    }
    #[test]
    fn proxy_parameters_cover_mac_tun_fields_without_allowing_enable_or_unknown_keys() {
        let values = json!({"tun":{"stack":"mixed","device":"utun1024","mtu":1500,"auto-route":true,"auto-detect-interface":true,"strict-route":false,"dns-hijack":["any:53"],"dns-mode":"hijack","route-exclude-address":["10.0.0.0/8","::1/128"]},"ipv6":true});
        assert!(parse("native_patch_proxy_config", json!({"values":values})).is_ok());
        for tun in [
            json!({"enable":true}),
            json!({"mtu":0}),
            json!({"stack":"unknown"}),
            json!({"route-exclude-address":["10.0.0.0/33"]}),
            json!({"device":"../test"}),
        ] {
            assert!(parse("native_patch_proxy_config", json!({"values":{"tun":tun}})).is_err());
        }
        let config = serde_yaml_ng::from_str::<serde_yaml_ng::Mapping>(
            "secret: private\ntun:\n  enable: true\n  mtu: 1400\n  private: hidden\n",
        )
        .unwrap();
        let output = project(&config);
        assert_eq!(output["values"]["tun"]["mtu"], 1400);
        assert!(!output.to_string().contains("private"));
    }
}
