use std::{collections::HashSet, path::Path, time::Duration};

use serde::{Deserialize, de::DeserializeOwned};
use serde_json::{Value, json};
use tauri_plugin_mihomo::{
    Mihomo,
    models::{Connections, RuleProviders, Rules},
};

const READ_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_CONNECTIONS: usize = 128;
const MAX_RULES: usize = 256;
const MAX_PROVIDERS: usize = 64;
const MAX_TEXT_CHARS: usize = 512;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Section {
    Connections,
    Rules,
    Providers,
}

impl Section {
    fn limit(self) -> usize {
        match self {
            Self::Connections => MAX_CONNECTIONS,
            Self::Rules => MAX_RULES,
            Self::Providers => MAX_PROVIDERS,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ActivityQuery {
    section: Option<Section>,
    #[serde(default)]
    query: String,
    #[serde(default)]
    offset: usize,
    limit: Option<usize>,
}

pub(crate) fn parse_query(params: Value) -> crate::cmd::CmdResult<ActivityQuery> {
    let invalid = || crate::cmd::CommandFailure::coded("INVALID_PARAMS", "Unsupported activity query");
    let query: ActivityQuery = serde_json::from_value(params).map_err(|_| invalid())?;
    if query.query.len() > 256 || query.offset > 1_000_000 {
        return Err(invalid());
    }
    match query.section {
        Some(section) if query.limit.is_some_and(|limit| limit == 0 || limit > section.limit()) => Err(invalid()),
        None if !query.query.is_empty() || query.offset != 0 || query.limit.is_some() => Err(invalid()),
        _ => Ok(query),
    }
}

impl ActivityQuery {
    fn for_section(&self, section: Section) -> (String, usize, usize) {
        if self.section == Some(section) {
            (
                self.query.to_lowercase(),
                self.offset,
                self.limit.unwrap_or(section.limit()),
            )
        } else {
            (String::new(), 0, section.limit())
        }
    }
}

fn page(items: impl Iterator<Item = Value>, total: usize, section: Section, query: &ActivityQuery) -> Value {
    let (search, offset, limit) = query.for_section(section);
    let fields: &[&str] = match section {
        Section::Connections => &["host", "destination", "network", "type", "application", "process", "rule", "rulePayload", "outbound"],
        Section::Rules => &["type", "payload", "proxy"],
        Section::Providers => &["name", "behavior", "format", "type", "vehicleType"],
    };
    let mut matched = 0;
    let mut rows = Vec::new();
    for item in items {
        let matches = search.is_empty()
            || fields.iter().any(|field| {
                item[*field]
                    .as_str()
                    .is_some_and(|value| value.to_lowercase().contains(&search))
            })
            || (section == Section::Connections && item["chains"].as_array().is_some_and(|chains| {
                chains.iter().any(|value| value.as_str().is_some_and(|value| value.to_lowercase().contains(&search)))
            }));
        if matches {
            if matched >= offset && rows.len() < limit {
                rows.push(item);
            }
            matched += 1;
        }
    }
    let end = offset.saturating_add(rows.len());
    let next = if end < matched { Some(end) } else { None };
    json!({"state":"ready","items":rows,"total":total,"matched":matched,"offset":offset,
        "nextOffset":next,"truncated":offset > 0 || end < matched,"code":null,"message":null})
}

#[derive(Clone, Copy)]
struct ReadFailure {
    code: &'static str,
    message: &'static str,
}

impl ReadFailure {
    const REQUEST: Self = Self {
        code: "controller_request",
        message: "Cannot read local controller activity",
    };
    const PAYLOAD: Self = Self {
        code: "controller_payload",
        message: "Local controller returned invalid activity data",
    };
    const SIZE: Self = Self {
        code: "response_too_large",
        message: "Local controller activity exceeds the response size limit",
    };
    const TIMEOUT: Self = Self {
        code: "controller_timeout",
        message: "Local controller activity read deadline exceeded",
    };
}

fn text(value: &str, limit: usize) -> String {
    value.chars().filter(|ch| !ch.is_control()).take(limit).collect()
}

fn short(value: &str) -> String {
    text(value, MAX_TEXT_CHARS)
}

fn basename(value: &str) -> String {
    short(value.rsplit(['/', '\\']).next().unwrap_or_default())
}

fn identity(value: &str, prefix: &str, index: usize, seen: &mut HashSet<String>) -> String {
    let base = text(value, MAX_TEXT_CHARS - 32);
    let mut id = if base.is_empty() {
        format!("{prefix}-{index}")
    } else {
        base.clone()
    };
    let mut collision = 0;
    while !seen.insert(id.clone()) {
        collision += 1;
        id = format!("{base}-{index}-{collision}");
    }
    id
}

fn failed_section(state: &str, error: ReadFailure, connections: bool) -> Value {
    let mut value = json!({"state":state,"items":[],"total":0,"matched":0,"offset":0,"nextOffset":null,"truncated":false,
        "code":error.code,"message":error.message});
    if connections {
        value["uploadTotal"] = Value::Null;
        value["downloadTotal"] = Value::Null;
        value["memory"] = Value::Null;
    }
    value
}

pub(crate) fn unavailable(code: &'static str, message: &'static str) -> Value {
    let error = ReadFailure { code, message };
    json!({"schemaVersion":1,"source":null,
        "connections":failed_section("unavailable",error,true),
        "rules":failed_section("unavailable",error,false),
        "providers":failed_section("unavailable",error,false)})
}

async fn socket_available(path: &Path) -> Result<(), ReadFailure> {
    let metadata = tokio::fs::symlink_metadata(path)
        .await
        .map_err(|_| ReadFailure::REQUEST)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt as _;
        if !metadata.file_type().is_socket() {
            return Err(ReadFailure::REQUEST);
        }
        tokio::net::UnixStream::connect(path)
            .await
            .map_err(|_| ReadFailure::REQUEST)?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        Err(ReadFailure::REQUEST)
    }
}

// The existing typed getters buffer an unbounded JSON body. Use their same local
// context and models, but stop reading before an oversized response reaches IPC.
async fn read_json<T: DeserializeOwned>(client: &Mihomo, endpoint: &str, key: &str) -> Result<T, ReadFailure> {
    let read = async {
        let request = client
            .load_ctx()
            .build_request(reqwest::Method::GET, endpoint)
            .map_err(|_| ReadFailure::REQUEST)?;
        let mut response = request.send().await.map_err(|_| ReadFailure::REQUEST)?;
        if !response.status().is_success() {
            return Err(ReadFailure::REQUEST);
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
        {
            return Err(ReadFailure::SIZE);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| ReadFailure::REQUEST)? {
            if chunk.len() > MAX_RESPONSE_BYTES.saturating_sub(bytes.len()) {
                return Err(ReadFailure::SIZE);
            }
            bytes.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| ReadFailure::PAYLOAD)?;
        let valid = match key {
            "connections" => value["connections"].is_array() || value["connections"].is_null(),
            "rules" => value["rules"].is_array(),
            "providers" => value["providers"].is_object(),
            _ => false,
        };
        if !value.is_object() || !value.as_object().is_some_and(|object| object.contains_key(key)) || !valid {
            return Err(ReadFailure::PAYLOAD);
        }
        if key == "connections" && (!value["uploadTotal"].is_u64() || !value["downloadTotal"].is_u64()) {
            return Err(ReadFailure::PAYLOAD);
        }
        serde_json::from_value(value).map_err(|_| ReadFailure::PAYLOAD)
    };
    tokio::time::timeout(READ_TIMEOUT, read)
        .await
        .unwrap_or(Err(ReadFailure::TIMEOUT))
}

fn project_connections(data: Connections, query: &ActivityQuery) -> Value {
    let mut connections = data.connections.unwrap_or_default();
    let total = connections.len();
    connections.sort_by(|left, right| {
        right
            .upload
            .saturating_add(right.download)
            .cmp(&left.upload.saturating_add(left.download))
            .then_with(|| left.id.cmp(&right.id))
    });
    let mut identities = HashSet::new();
    let items = connections.into_iter().enumerate().map(|(index, connection)| {
        let id = identity(&connection.id, "connection", index, &mut identities);
        let closeable = id == connection.id && crate::native_control::parse_connection_id(json!({"id":id})).is_ok();
        let metadata = connection.metadata;
        let address = short(&metadata.destination_ip);
        let port = short(&metadata.destination_port);
        let destination = short(&if port.is_empty() {
            address
        } else {
            format!("{address}:{port}")
        });
        json!({"id":id,"closeable":closeable,"host":short(&metadata.host),"destination":destination,
                "network":short(metadata.network.as_str()),"type":short(metadata.connection_type.as_str()),
                "application":application_name(&metadata.process_path),
                "process":basename(&metadata.process),"rule":short(&connection.rule),
                "rulePayload":rule_payload(&connection.rule, &connection.rule_payload),
                "outbound":connection.chains.first().map(|chain| short(chain)),"chainOrder":"exit-first",
                "chains":connection.chains.iter().take(8).map(|chain| short(chain)).collect::<Vec<_>>(),
                "upload":connection.upload,"download":connection.download,"start":short(&connection.start)})
    });
    let mut section = page(items, total, Section::Connections, query);
    section["uploadTotal"] = json!(data.upload_total);
    section["downloadTotal"] = json!(data.download_total);
    section["memory"] = json!(data.memory);
    section
}

fn project_rules(data: Rules, query: &ActivityQuery) -> Value {
    let total = data.rules.len();
    let items = data.rules.into_iter().enumerate().map(|(index, rule)| {
        let kind = rule.rule_type.as_str();
        json!({"index":index,"type":short(kind),
                "payload":rule_payload(kind, &rule.payload),
                "proxy":short(&rule.proxy),"size":rule.size.max(0) as u64})
    });
    page(items, total, Section::Rules, query)
}

fn application_name(path: &str) -> Option<String> {
    path.split(['/', '\\']).find_map(|part| {
        part.strip_suffix(".app").filter(|name| !name.is_empty()).map(short)
    })
}

fn rule_payload(kind: &str, payload: &str) -> String {
    if kind.to_ascii_uppercase().replace('-', "").contains("PROCESSPATH")
        || payload.to_ascii_uppercase().contains("PROCESS-PATH")
    {
        "[hidden]".to_owned()
    } else {
        text(payload, 256)
    }
}

fn project_providers(data: RuleProviders, query: &ActivityQuery) -> Value {
    let mut providers: Vec<_> = data.providers.into_iter().collect();
    let total = providers.len();
    providers.sort_by(|left, right| left.0.cmp(&right.0));
    let mut identities = HashSet::new();
    let items = providers.into_iter().enumerate().map(|(index, (key, provider))| {
        json!({"name":identity(&key,"provider",index,&mut identities),
                "behavior":short(provider.behavior.as_str()),"format":short(provider.format.as_str()),
                "type":short(provider.provider_type.as_str()),"ruleCount":provider.rule_count,
                "updatedAt":short(&provider.updated_at),"vehicleType":short(provider.vehicle_type.as_str())})
    });
    page(items, total, Section::Providers, query)
}

pub(crate) async fn read(path: &Path, client: &Mihomo, source: &'static str, query: &ActivityQuery) -> Value {
    if !matches!(
        tokio::time::timeout(Duration::from_secs(1), socket_available(path)).await,
        Ok(Ok(()))
    ) {
        return unavailable("socket_unavailable", "Local controller socket is unavailable");
    }
    let (connections, rules, providers) = tokio::join!(
        read_json::<Connections>(client, "/connections", "connections"),
        async {
            if query.section.is_none() || query.section == Some(Section::Rules) {
                read_json::<Rules>(client, "/rules", "rules").await
            } else { Err(ReadFailure { code: "not_requested", message: "Section was not requested" }) }
        },
        async {
            if query.section.is_none() || query.section == Some(Section::Providers) {
                read_json::<RuleProviders>(client, "/providers/rules", "providers").await
            } else { Err(ReadFailure { code: "not_requested", message: "Section was not requested" }) }
        },
    );
    json!({"schemaVersion":1,"source":source,
        "connections":connections.map(|data| project_connections(data,query)).unwrap_or_else(|error| failed_section("error",error,true)),
        "rules":rules.map(|data| project_rules(data,query)).unwrap_or_else(|error| failed_section("error",error,false)),
        "providers":providers.map(|data| project_providers(data,query)).unwrap_or_else(|error| failed_section("error",error,false))})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    #[test]
    fn queries_are_bounded_and_require_an_explicit_section() {
        parse_query(json!({})).unwrap();
        parse_query(json!({"section":"rules","query":"测试","offset":1_000_000,"limit":256})).unwrap();
        for params in [
            Value::Null,
            json!({"section":"logs"}),
            json!({"section":"rules","unknown":true}),
            json!({"query":"rule"}),
            json!({"limit":1}),
            json!({"section":"rules","limit":0}),
            json!({"section":"rules","limit":257}),
            json!({"section":"providers","limit":65}),
            json!({"section":"connections","offset":-1}),
            json!({"section":"rules","offset":1_000_001}),
            json!({"section":"rules","query":"测".repeat(86)}),
        ] {
            assert!(parse_query(params).is_err());
        }
    }

    fn many_rules() -> Rules {
        serde_json::from_value(json!({"rules":(0..310).map(|index| json!({
            "index":index,"type":"DomainSuffix","payload":format!("rule-{index}.test"),"proxy":"DIRECT"
        })).collect::<Vec<_>>()}))
        .unwrap()
    }

    #[test]
    fn rules_search_matches_beyond_the_first_page_and_preserves_source_indices() {
        let initial = project_rules(many_rules(), &ActivityQuery::default());
        assert_eq!(initial["total"], 310);
        assert_eq!(initial["matched"], 310);
        assert_eq!(initial["offset"], 0);
        assert_eq!(initial["items"].as_array().unwrap().len(), MAX_RULES);
        assert_eq!(initial["nextOffset"], 256);
        let query = parse_query(json!({"section":"rules","offset":256,"limit":54})).unwrap();
        let next = project_rules(many_rules(), &query);
        assert_eq!(next["items"][0]["index"], 256);
        assert_eq!(next["nextOffset"], Value::Null);
        let query = parse_query(json!({"section":"rules","query":"RULE-309.TEST"})).unwrap();
        let found = project_rules(many_rules(), &query);
        assert_eq!(found["total"], 310);
        assert_eq!(found["matched"], 1);
        assert_eq!(found["items"][0]["index"], 309);
        assert_eq!(found["nextOffset"], Value::Null);
        let query = parse_query(json!({"section":"rules","query":"unmatched"})).unwrap();
        let empty = project_rules(many_rules(), &query);
        assert_eq!(empty["matched"], 0);
        assert_eq!(empty["items"], json!([]));
        let query = parse_query(json!({"section":"rules","offset":1_000_000})).unwrap();
        let past_end = project_rules(many_rules(), &query);
        assert_eq!(past_end["offset"], 1_000_000);
        assert_eq!(past_end["items"], json!([]));
        assert_eq!(past_end["nextOffset"], Value::Null);
        let unrelated = project_connections(
            serde_json::from_value(json!({
                "uploadTotal":0,"downloadTotal":0,"connections":[{"id":"one","metadata":{"host":"other"}}]
            }))
            .unwrap(),
            &query,
        );
        assert_eq!(unrelated["offset"], 0);
        assert_eq!(unrelated["matched"], 1);
    }

    #[test]
    fn connection_identity_is_assigned_before_search_and_paging() {
        let connections = || {
            serde_json::from_value(json!({"uploadTotal":1,"downloadTotal":2,"connections":[
                {"id":"same","metadata":{"host":"first"},"upload":20},
                {"id":"same","metadata":{"host":"second"},"upload":10}
            ]}))
            .unwrap()
        };
        let initial = project_connections(connections(), &ActivityQuery::default());
        let query = parse_query(json!({"section":"connections","query":"SECOND","limit":1})).unwrap();
        let filtered = project_connections(connections(), &query);
        assert_eq!(filtered["items"][0]["id"], initial["items"][1]["id"]);
        assert_eq!(filtered["total"], 2);
        assert_eq!(filtered["matched"], 1);
        let query = parse_query(json!({"section":"connections","offset":1,"limit":1})).unwrap();
        let paged = project_connections(connections(), &query);
        assert_eq!(paged["items"][0]["id"], initial["items"][1]["id"]);
    }

    #[test]
    fn projection_omits_secrets_and_paths_and_bounds_output() {
        let data: Connections = serde_json::from_value(json!({
            "uploadTotal":u64::MAX,"downloadTotal":15,"memory":42,
            "private":"private-token","connections":[{
                "id":"one","metadata":{"host":"example.test","process":"/private/account/Test.app",
                    "processPath":"/private/account/Browser.app/Contents/MacOS/Browser Helper","sourceIP":"private-source","destinationIP":"127.0.0.1",
                    "destinationPort":"443","inboundUser":"private-user"},
                "upload":7,"download":8,"rule":"Domain","rulePayload":"example.test",
                "chains":["DIRECT"],"extra-secret":"private-token"}]
        }))
        .unwrap();
        let value = project_connections(data, &ActivityQuery::default());
        assert_eq!(value["items"][0]["process"], "Test.app");
        assert_eq!(value["items"][0]["application"], "Browser");
        assert_eq!(value["items"][0]["rulePayload"], "example.test");
        assert_eq!(value["items"][0]["outbound"], "DIRECT");
        assert_eq!(value["items"][0]["chainOrder"], "exit-first");
        assert_eq!(value["items"][0]["destination"], "127.0.0.1:443");
        assert_eq!(value["uploadTotal"], u64::MAX);
        assert!(!value.to_string().contains("private"));
        assert_eq!(rule_payload("ProcessPath", "/private/secret"), "[hidden]");
        assert_eq!(rule_payload("AND", "((PROCESS-PATH,/private/secret),(NETWORK,TCP))"), "[hidden]");
        assert_eq!(application_name("/Applications/Browser.app/Contents/Helpers/Helper.app/Contents/MacOS/Helper"), Some("Browser".to_owned()));
        assert_eq!(application_name("/usr/bin/curl"), None);

        let rules: Rules = serde_json::from_value(json!({"rules":[
            {"type":"ProcessPath","payload":"/private/secret","proxy":"DIRECT","index":-1,"size":-1},
            {"type":"AND","payload":"((PROCESS-PATH,/private/secret),(NETWORK,TCP))","proxy":"DIRECT"}
        ]}))
        .unwrap();
        let value = project_rules(rules, &ActivityQuery::default());
        assert_eq!(value["items"][0]["index"], 0);
        assert_eq!(value["items"][1]["index"], 1);
        assert_eq!(value["items"][0]["payload"], "[hidden]");
        assert!(!value.to_string().contains("/private"));

        let providers: RuleProviders = serde_json::from_value(json!({"providers":{
            "rules":{"name":"rules","ruleCount":100,"url":"private-token","path":"/private/secret"}
        }}))
        .unwrap();
        assert!(
            !project_providers(providers, &ActivityQuery::default())
                .to_string()
                .contains("private")
        );

        let repeated = json!({"id":"\u{754c}".repeat(2000),"metadata":{"host":"x".repeat(2000),
            "destinationIP":"x".repeat(2000),"destinationPort":"x".repeat(2000)},"chains":vec!["long".repeat(1000);40]});
        let data: Connections =
            serde_json::from_value(json!({"connections":vec![repeated;MAX_CONNECTIONS+1]})).unwrap();
        let value = project_connections(data, &ActivityQuery::default());
        assert_eq!(value["total"], MAX_CONNECTIONS + 1);
        assert_eq!(value["items"].as_array().unwrap().len(), MAX_CONNECTIONS);
        assert_eq!(value["truncated"], true);
        let ids: HashSet<_> = value["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), MAX_CONNECTIONS);
        for item in value["items"].as_array().unwrap() {
            assert!(item["id"].as_str().unwrap().chars().count() <= MAX_TEXT_CHARS);
            assert!(item["destination"].as_str().unwrap().chars().count() <= MAX_TEXT_CHARS);
        }
        assert!(value.to_string().len() < 2 * 1024 * 1024);

        let key = "\u{754c}".repeat(MAX_TEXT_CHARS + 1);
        let mut providers = serde_json::Map::new();
        providers.insert(format!("{key}a"), json!({"name":"same"}));
        providers.insert(format!("{key}b"), json!({"name":"same"}));
        let providers: RuleProviders = serde_json::from_value(json!({"providers":providers})).unwrap();
        let value = project_providers(providers, &ActivityQuery::default());
        assert_ne!(value["items"][0]["name"], value["items"][1]["name"]);
        for item in value["items"].as_array().unwrap() {
            assert!(item["name"].as_str().unwrap().chars().count() <= MAX_TEXT_CHARS);
        }
    }

    #[cfg(unix)]
    struct SocketFixture(std::path::PathBuf);

    #[cfg(unix)]
    impl SocketFixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("ta-{}", nanoid::nanoid!(8)));
            std::fs::create_dir(&root).unwrap();
            Self(root)
        }

        fn socket(&self) -> std::path::PathBuf {
            self.0.join("s")
        }

        fn client(&self) -> Mihomo {
            use tauri_plugin_mihomo::{MihomoContext, models::Protocol};
            let socket = self.socket().to_str().unwrap().to_owned();
            let client = MihomoContext::build_client(&Protocol::LocalSocket, Some(&socket)).unwrap();
            Mihomo::new(MihomoContext::new(
                Protocol::LocalSocket,
                None,
                None,
                None,
                Some(socket),
                READ_TIMEOUT,
                client,
            ))
        }
    }

    #[cfg(unix)]
    impl Drop for SocketFixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn local_reads_are_get_only_and_section_failures_do_not_hide_successes() {
        let fixture = SocketFixture::new();
        let listener = tokio::net::UnixListener::bind(fixture.socket()).unwrap();
        let server = tokio::spawn(async move {
            let mut tasks = Vec::new();
            for _ in 0..4 {
                let (mut socket, _) = listener.accept().await.unwrap();
                tasks.push(tokio::spawn(async move {
                    let mut headers = Vec::new();
                    let mut byte = [0; 1];
                    loop {
                        if socket.read(&mut byte).await.unwrap() == 0 {
                            assert!(headers.is_empty());
                            return None;
                        }
                        headers.push(byte[0]);
                        assert!(headers.len() < 4096);
                        if headers.ends_with(b"\r\n\r\n") {
                            break;
                        }
                    }
                    let request = std::str::from_utf8(&headers).unwrap();
                    let route = request.lines().next().unwrap().to_owned();
                    assert!(route.starts_with("GET "));
                    let response = if route.starts_with("GET /connections ") {
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            MAX_RESPONSE_BYTES + 1
                        )
                    } else if route.starts_with("GET /rules ") {
                        let body = "private-response-token";
                        format!(
                            "HTTP/1.1 500 Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        )
                    } else {
                        assert!(route.starts_with("GET /providers/rules "));
                        let body =
                            r#"{"providers":{"safe":{"name":"safe","ruleCount":12,"url":"private-provider-token"}}}"#;
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        )
                    };
                    let _ = socket.write_all(response.as_bytes()).await;
                    Some(route)
                }));
            }
            let mut routes = Vec::new();
            for task in tasks {
                if let Some(route) = task.await.unwrap() {
                    routes.push(route);
                }
            }
            routes
        });
        let value = read(
            &fixture.socket(),
            &fixture.client(),
            "sidecar",
            &ActivityQuery::default(),
        )
        .await;
        let routes = server.await.unwrap();
        assert_eq!(routes.len(), 3);
        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["connections"]["code"], "response_too_large");
        assert_eq!(value["connections"]["uploadTotal"], Value::Null);
        assert_eq!(value["rules"]["state"], "error");
        assert_eq!(value["providers"]["state"], "ready");
        assert_eq!(value["providers"]["items"][0]["ruleCount"], 12);
        assert!(!value.to_string().contains("private"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn streamed_response_limit_and_missing_payload_are_rejected() {
        let fixture = SocketFixture::new();
        let listener = tokio::net::UnixListener::bind(fixture.socket()).unwrap();
        let server = tokio::spawn(async move {
            for body in [
                vec![b' '; MAX_RESPONSE_BYTES + 1],
                br#"{"unexpected":"private-token"}"#.to_vec(),
            ] {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut headers = [0; 4096];
                let _ = socket.read(&mut headers).await.unwrap();
                socket
                    .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
                    .await
                    .unwrap();
                let _ = socket.write_all(&body).await;
            }
        });
        let client = fixture.client();
        let oversized = read_json::<Rules>(&client, "/rules", "rules").await.unwrap_err();
        assert_eq!(oversized.code, "response_too_large");
        let missing = read_json::<Rules>(&client, "/rules", "rules").await.unwrap_err();
        assert_eq!(missing.code, "controller_payload");
        server.await.unwrap();
    }
}
