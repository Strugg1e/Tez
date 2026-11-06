//! Session-only transport changes. Source profiles, DNS and routing stay untouched.
#[cfg(any(feature = "standalone", feature = "client"))]
use anyhow::{Context as _, Result, ensure};
use serde::{Deserialize, Serialize};
#[cfg(any(feature = "standalone", feature = "client"))]
use serde_yaml_ng::{Mapping, Value};

pub const PROVIDER_FINGERPRINT_EXPRESSION: &str = "(select((.type == \"trojan\" or .type == \"anytls\" or ((.type == \"vmess\" or .type == \"vless\") and .tls == true)) and (has(\"client-fingerprint\") == false)) | .[\"client-fingerprint\"] = \"chrome\") // .";

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransportReport {
    pub nodes: Vec<TransportNode>,
    pub dynamic_providers: usize,
    pub dns: DnsInspection,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportNode {
    pub name: String,
    pub protocol: String,
    pub status: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DnsInspection {
    pub enabled: bool,
    pub encrypted_resolvers: usize,
    pub other_resolvers: usize,
    pub follows_rules: bool,
    pub node_resolver_configured: bool,
}

#[cfg(any(feature = "standalone", feature = "client"))]
fn string(map: &Mapping, key: &str) -> String {
    map.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

#[cfg(any(feature = "standalone", feature = "client"))]
fn node_status(map: &Mapping) -> &'static str {
    let protocol = string(map, "type");
    if !matches!(protocol.as_str(), "trojan" | "anytls")
        && !(matches!(protocol.as_str(), "vmess" | "vless") && map.get("tls").and_then(Value::as_bool) == Some(true))
    {
        return "unsupported";
    }
    if map.contains_key("client-fingerprint") {
        "existing"
    } else {
        "eligible"
    }
}

#[cfg(any(feature = "standalone", feature = "client"))]
fn inspect_resolver(value: &Value, dns: &mut DnsInspection) {
    if let Some(values) = value.as_sequence() {
        for value in values {
            inspect_resolver(value, dns);
        }
    } else if value.as_str().is_some_and(|text| {
        ["https://", "tls://", "quic://", "h3://"]
            .iter()
            .any(|prefix| text.starts_with(prefix))
    }) {
        dns.encrypted_resolvers += 1;
    } else {
        dns.other_resolvers += 1;
    }
}

#[cfg(any(feature = "standalone", feature = "client"))]
pub fn inspect_transport(yaml: &str) -> Result<TransportReport> {
    let mut value: Value = serde_yaml_ng::from_str(yaml).context("Invalid runtime YAML")?;
    value.apply_merge().context("Invalid runtime YAML merge")?;
    let root = value.as_mapping().context("Runtime YAML must be a mapping")?;
    let mut nodes: Vec<_> = root
        .get("proxies")
        .and_then(Value::as_sequence)
        .into_iter()
        .flatten()
        .filter_map(Value::as_mapping)
        .map(|node| TransportNode {
            name: string(node, "name"),
            protocol: string(node, "type"),
            status: node_status(node).into(),
        })
        .collect();
    let providers = root.get("proxy-providers").and_then(Value::as_mapping);
    let mut dynamic_providers = 0;
    for provider in providers
        .into_iter()
        .flat_map(Mapping::values)
        .filter_map(Value::as_mapping)
    {
        let overrides = provider.get("override").and_then(Value::as_mapping);
        if string(provider, "type") == "inline" && overrides.and_then(|value| value.get("override-expr")).is_none() {
            for node in provider
                .get("payload")
                .and_then(Value::as_sequence)
                .into_iter()
                .flatten()
                .filter_map(Value::as_mapping)
            {
                let mut status = node_status(node);
                if status == "eligible" && overrides.is_some_and(|value| value.contains_key("client-fingerprint")) {
                    status = "existing";
                }
                nodes.push(TransportNode {
                    name: string(node, "name"),
                    protocol: string(node, "type"),
                    status: status.into(),
                });
            }
        } else {
            dynamic_providers += 1;
        }
    }
    let mut dns = DnsInspection::default();
    if let Some(config) = root.get("dns").and_then(Value::as_mapping) {
        dns.enabled = config.get("enable").and_then(Value::as_bool) == Some(true);
        dns.follows_rules = config.get("respect-rules").and_then(Value::as_bool) == Some(true);
        dns.node_resolver_configured = config
            .get("proxy-server-nameserver")
            .and_then(Value::as_sequence)
            .is_some_and(|values| !values.is_empty())
            || config.get("proxy-server-nameserver-policy").and_then(Value::as_mapping).is_some_and(|values| !values.is_empty());
        for key in [
            "nameserver",
            "fallback",
            "default-nameserver",
            "proxy-server-nameserver",
            "direct-nameserver",
        ] {
            if let Some(value) = config.get(key) {
                inspect_resolver(value, &mut dns);
            }
        }
        for key in ["nameserver-policy", "proxy-server-nameserver-policy"] {
            for value in config
                .get(key)
                .and_then(Value::as_mapping)
                .into_iter()
                .flat_map(Mapping::values)
            {
                inspect_resolver(value, &mut dns);
            }
        }
    }
    Ok(TransportReport {
        nodes,
        dynamic_providers,
        dns,
    })
}

#[cfg(any(feature = "standalone", feature = "client"))]
pub fn render_transport(yaml: &str) -> Result<String> {
    let mut value: Value = serde_yaml_ng::from_str(yaml).context("Invalid runtime YAML")?;
    value.apply_merge().context("Invalid runtime YAML merge")?;
    let root = value.as_mapping_mut().context("Runtime YAML must be a mapping")?;
    if let Some(nodes) = root.get_mut("proxies").and_then(Value::as_sequence_mut) {
        for node in nodes.iter_mut().filter_map(Value::as_mapping_mut) {
            if node_status(node) == "eligible" {
                node.insert("client-fingerprint".into(), "chrome".into());
            }
        }
    }
    if let Some(providers) = root.get_mut("proxy-providers").and_then(Value::as_mapping_mut) {
        for provider in providers.values_mut().filter_map(Value::as_mapping_mut) {
            let overrides = provider
                .entry(Value::from("override"))
                .or_insert_with(|| Value::Mapping(Mapping::new()));
            let overrides = overrides
                .as_mapping_mut()
                .context("Provider override must be a mapping")?;
            let expressions = overrides
                .entry(Value::from("override-expr"))
                .or_insert_with(|| Value::Sequence(vec![]));
            let expressions = expressions
                .as_sequence_mut()
                .context("Provider override-expr must be a sequence")?;
            ensure!(
                !expressions
                    .iter()
                    .any(|value| value.as_str() == Some(PROVIDER_FINGERPRINT_EXPRESSION)),
                "Transport overlay was already applied"
            );
            expressions.push(PROVIDER_FINGERPRINT_EXPRESSION.into());
        }
    }
    serde_yaml_ng::to_string(&root).context("Could not encode session transport configuration")
}

#[cfg(all(test, any(feature = "standalone", feature = "client")))]
mod tests {
    use super::*;

    #[test]
    fn inherited_tls_settings_are_preserved_and_recognized() -> Result<()> {
        let source = "proxies:\n- {name: inherited, <<: {type: trojan, client-fingerprint: firefox}}\n- {name: eligible, <<: {type: vless, tls: true}}\n";
        let report = inspect_transport(source)?;
        assert_eq!(report.nodes[0].status, "existing");
        assert_eq!(report.nodes[1].status, "eligible");
        let rendered: Value = serde_yaml_ng::from_str(&render_transport(source)?)?;
        assert_eq!(rendered["proxies"][0]["client-fingerprint"].as_str(), Some("firefox"));
        assert_eq!(rendered["proxies"][1]["client-fingerprint"].as_str(), Some("chrome"));
        Ok(())
    }
    const SOURCE: &str = "proxies:\n- {name: tls, type: vless, tls: true, server: example.com, port: 443}\n- {name: plain, type: vless, tls: false}\n- {name: preset, type: trojan, client-fingerprint: firefox}\n- {name: ss, type: ss}\nproxy-providers:\n  subscription:\n    type: http\n    url: https://example.com/private\n    override: {udp: true}\ndns:\n  enable: true\n  respect-rules: true\n  nameserver: [https://example.com/dns-query]\n  default-nameserver: [1.1.1.1]\nrules: [MATCH,DIRECT]\n";

    #[test]
    fn transport_changes_only_compatible_unset_fingerprints() -> Result<()> {
        let original: Mapping = serde_yaml_ng::from_str(SOURCE)?;
        let rendered: Mapping = serde_yaml_ng::from_str(&render_transport(SOURCE)?)?;
        assert_eq!(original.get("dns"), rendered.get("dns"));
        assert_eq!(original.get("rules"), rendered.get("rules"));
        let before = original["proxies"].as_sequence().unwrap();
        let after = rendered["proxies"].as_sequence().unwrap();
        assert_eq!(after[0]["client-fingerprint"].as_str(), Some("chrome"));
        assert_eq!(&before[1..], &after[1..]);
        assert_eq!(after[2]["client-fingerprint"].as_str(), Some("firefox"));
        assert!(
            rendered["proxy-providers"]["subscription"]["override"]["udp"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            rendered["proxy-providers"]["subscription"]["url"],
            original["proxy-providers"]["subscription"]["url"]
        );
        let report = inspect_transport(SOURCE)?;
        assert_eq!(
            report.nodes.iter().map(|node| node.status.as_str()).collect::<Vec<_>>(),
            ["eligible", "unsupported", "existing", "unsupported"]
        );
        assert_eq!(report.dynamic_providers, 1);
        assert_eq!((report.dns.encrypted_resolvers, report.dns.other_resolvers), (1, 1));
        assert!(report.dns.enabled && report.dns.follows_rules);
        Ok(())
    }

    #[test]
    fn inline_provider_coverage_and_dns_policies_are_reported_without_credentials() -> Result<()> {
        let source = "proxy-providers:\n  known:\n    type: inline\n    payload:\n    - {name: one, type: trojan, password: private-password, server: private-server}\n    - {name: two, type: ss}\n  dynamic:\n    type: http\n    url: https://private-subscription\ndns:\n  enable: true\n  nameserver-policy:\n    example.com: [tls://1.1.1.1, 8.8.8.8]\n  proxy-server-nameserver-policy:\n    example.net: https://1.1.1.1/dns-query\n";
        let report = inspect_transport(source)?;
        assert_eq!(report.nodes.len(), 2);
        assert_eq!(report.dynamic_providers, 1);
        assert_eq!((report.dns.encrypted_resolvers, report.dns.other_resolvers), (2, 1));
        assert!(report.dns.node_resolver_configured);
        let json = serde_json::to_string(&report)?;
        assert!(!json.contains("private-"));
        Ok(())
    }

    #[test]
    fn explicit_fingerprints_and_unrelated_configuration_are_preserved() -> Result<()> {
        let source = "proxies:\n- {name: none, type: trojan, client-fingerprint: none, skip-cert-verify: false}\n- {name: empty, type: trojan, client-fingerprint: ''}\n- {name: null, type: trojan, client-fingerprint: null}\n- {name: tls, type: anytls}\n- {name: reality, type: vless, tls: true, reality-opts: {public-key: fixture}}\n- {name: quic, type: hysteria2}\ntun: {enable: true}\ndns: {enable: false}\nrules: ['MATCH,DIRECT']\n";
        let original: Mapping = serde_yaml_ng::from_str(source)?;
        let mut enhanced: Mapping = serde_yaml_ng::from_str(&render_transport(source)?)?;
        for index in [3, 4] {
            enhanced["proxies"].as_sequence_mut().unwrap()[index]
                .as_mapping_mut()
                .unwrap()
                .remove("client-fingerprint");
        }
        assert_eq!(original, enhanced);
        Ok(())
    }

    #[test]
    fn provider_overrides_are_appended_after_existing_expressions() -> Result<()> {
        let source = "proxy-providers: {one: {type: http, override: {override-expr: ['.udp = true']}}}";
        let rendered: Mapping = serde_yaml_ng::from_str(&render_transport(source)?)?;
        let expressions = rendered["proxy-providers"]["one"]["override"]["override-expr"]
            .as_sequence()
            .unwrap();
        assert_eq!(expressions[0].as_str(), Some(".udp = true"));
        assert_eq!(expressions[1].as_str(), Some(PROVIDER_FINGERPRINT_EXPRESSION));
        assert!(render_transport(&serde_yaml_ng::to_string(&rendered)?).is_err());
        assert!(render_transport("proxy-providers: {one: {override: {override-expr: invalid}}}").is_err());
        Ok(())
    }
}
