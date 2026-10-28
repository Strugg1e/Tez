use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value};
use std::fmt;

pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireError(String);

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for WireError {}

fn invalid(detail: &str) -> WireError {
    WireError(detail.to_owned())
}

#[derive(Debug, Clone, PartialEq)]
pub struct Frame(Value);

impl Frame {
    pub fn new(value: Value) -> Result<Self, WireError> {
        validate_numbers(&value)?;
        let object = value.as_object().ok_or_else(|| invalid("frame must be an object"))?;
        if object.get("version").and_then(Value::as_u64) != Some(1) {
            return Err(invalid("unsupported or invalid version"));
        }
        match object.get("kind").and_then(Value::as_str) {
            Some("request") => {
                nonempty_string(object, "id")?;
                nonempty_string(object, "command")?;
                if !object.get("params").is_some_and(Value::is_object) {
                    return Err(invalid("request params must be an object"));
                }
            }
            Some("response") => {
                nonempty_string(object, "id")?;
                match (object.contains_key("result"), object.get("error")) {
                    (true, None) => {}
                    (false, Some(Value::Object(error))) => {
                        if !error.get("detail").is_some_and(Value::is_string) {
                            return Err(invalid("error detail must be a string"));
                        }
                        if let Some(code) = error.get("code") {
                            if !code.is_null() && !code.is_string() {
                                return Err(invalid("error code must be a string or null"));
                            }
                        }
                    }
                    _ => return Err(invalid("response requires exactly one result or error object")),
                }
            }
            Some("event") => {
                nonempty_string(object, "name")?;
                let sequence = nonempty_string(object, "sequence")?;
                if !sequence.bytes().all(|byte| byte.is_ascii_digit())
                    || (sequence.len() > 1 && sequence.starts_with('0'))
                {
                    return Err(invalid("event sequence must be a canonical nonnegative decimal string"));
                }
                if !object.contains_key("payload") {
                    return Err(invalid("event requires payload"));
                }
            }
            Some("hello") => {
                if object.get("protocol").and_then(Value::as_str) != Some("tez.native") {
                    return Err(invalid("hello protocol must be tez.native"));
                }
                nonempty_string(object, "sessionID")?;
                if !object
                    .get("capabilities")
                    .and_then(Value::as_array)
                    .is_some_and(|items| items.iter().all(Value::is_string))
                {
                    return Err(invalid("hello capabilities must be an array of strings"));
                }
            }
            _ => return Err(invalid("unknown or invalid frame kind")),
        }
        Ok(Self(value))
    }

    pub fn value(&self) -> &Value {
        &self.0
    }

    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let mut bytes = serde_json::to_vec(&self.0).map_err(|error| invalid(&error.to_string()))?;
        bytes.push(b'\n');
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(invalid("frame exceeds 8 MiB including newline"));
        }
        Ok(bytes)
    }
}

fn validate_numbers(value: &Value) -> Result<(), WireError> {
    match value {
        Value::Number(number) => {
            let token = number.to_string();
            if token.contains(['.', 'e', 'E']) {
                if !token.parse::<f64>().is_ok_and(f64::is_finite) {
                    return Err(invalid("decimal or exponent number exceeds finite Double range"));
                }
            } else if token.starts_with('-') {
                if token.parse::<i64>().is_err() {
                    return Err(invalid("integer number is below Int64 minimum"));
                }
            } else if token.parse::<u64>().is_err() {
                return Err(invalid("integer number exceeds UInt64 maximum"));
            }
        }
        Value::Array(items) => {
            for item in items {
                validate_numbers(item)?;
            }
        }
        Value::Object(object) => {
            for item in object.values() {
                validate_numbers(item)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn nonempty_string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, WireError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .ok_or_else(|| invalid(&format!("{key} must be a nonempty string")))
}

struct Envelope(Value);

impl<'de> Deserialize<'de> for Envelope {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct EnvelopeVisitor;

        impl<'de> Visitor<'de> for EnvelopeVisitor {
            type Value = Envelope;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a frame object without duplicate envelope keys")
            }

            fn visit_map<M: MapAccess<'de>>(self, mut access: M) -> Result<Envelope, M::Error> {
                let mut object = Map::new();
                while let Some(key) = access.next_key::<String>()? {
                    if object.contains_key(&key) {
                        return Err(de::Error::custom(format!("duplicate envelope key: {key}")));
                    }
                    object.insert(key, access.next_value::<Value>()?);
                }
                Ok(Envelope(Value::Object(object)))
            }
        }

        deserializer.deserialize_map(EnvelopeVisitor)
    }
}

#[derive(Default)]
pub struct Decoder {
    pending: Vec<u8>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<Frame>, WireError> {
        let mut frames = Vec::new();
        for part in chunk.split_inclusive(|byte| *byte == b'\n') {
            if self.pending.len() + part.len() > MAX_FRAME_BYTES {
                return Err(invalid("frame exceeds 8 MiB including newline"));
            }
            self.pending.extend_from_slice(part);
            if self.pending.last() == Some(&b'\n') {
                let envelope: Envelope = serde_json::from_slice(&self.pending[..self.pending.len() - 1])
                    .map_err(|error| invalid(&format!("invalid JSON frame: {error}")))?;
                frames.push(Frame::new(envelope.0)?);
                self.pending.clear();
            } else if self.pending.len() == MAX_FRAME_BYTES {
                return Err(invalid("frame exceeds 8 MiB including newline"));
            }
        }
        Ok(frames)
    }

    pub fn finish(&self) -> Result<(), WireError> {
        if self.pending.is_empty() {
            Ok(())
        } else {
            Err(invalid("incomplete frame at EOF: missing newline"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn decode(bytes: &[u8]) -> Result<Vec<Frame>, WireError> {
        let mut decoder = Decoder::new();
        let frames = decoder.push(bytes)?;
        decoder.finish()?;
        Ok(frames)
    }

    #[test]
    fn roundtrips_all_kinds_and_preserves_structured_errors() {
        let values = [
            json!({"version":1,"kind":"request","id":"a","command":"read","params":{}}),
            json!({"version":1,"kind":"response","id":"a","result":null}),
            json!({"version":1,"kind":"response","id":"a","error":{"detail":"failed","code":null,"operation":{"nested":[1,null]},"extra":true}}),
            json!({"version":1,"kind":"event","sequence":"184467440737095516160","name":"changed","payload":null}),
            json!({"version":1,"kind":"hello","protocol":"tez.native","sessionID":"s","capabilities":["events"]}),
        ];
        for value in values {
            let frame = Frame::new(value.clone()).unwrap();
            assert_eq!(decode(&frame.encode().unwrap()).unwrap()[0].value(), &value);
        }
    }

    #[test]
    fn unicode_and_numbers_survive_single_byte_chunks() {
        let bytes = "{\"version\":1,\"kind\":\"response\",\"id\":\"中文\",\"result\":[9007199254740993,18446744073709551615,1.25,-42,1e100]}\n".as_bytes();
        let mut decoder = Decoder::new();
        let mut frames = Vec::new();
        for byte in bytes {
            frames.extend(decoder.push(&[*byte]).unwrap());
        }
        decoder.finish().unwrap();
        assert_eq!(frames.len(), 1);
        let normalized = String::from_utf8(frames[0].encode().unwrap()).unwrap();
        assert!(normalized.contains("中文"));
        assert!(normalized.contains("9007199254740993"));
        assert!(normalized.contains("18446744073709551615"));
        assert!(normalized.contains("1.25"));
        assert!(normalized.contains("-42"));
        assert!(normalized.contains("1e+100") || normalized.contains("1e100"));
    }

    #[test]
    fn accepts_integer_boundaries_and_finite_decimal_numbers() {
        let bytes = b"{\"version\":1,\"kind\":\"response\",\"id\":\"r\",\"result\":[-9223372036854775808,18446744073709551615,1.7976931348623157e308,1e-999]}\n";
        assert_eq!(decode(bytes).unwrap().len(), 1);
    }

    #[test]
    fn rejects_out_of_range_numbers_recursively() {
        for token in ["-9223372036854775809", "18446744073709551616", "1e309", "-1e309"] {
            for envelope in [
                format!(r#"{{"version":1,"kind":"request","id":"r","command":"x","params":{{"nested":[{token}]}}}}"#),
                format!(r#"{{"version":1,"kind":"response","id":"r","result":{{"nested":[{token}]}}}}"#),
                format!(
                    r#"{{"version":1,"kind":"response","id":"r","error":{{"detail":"x","operation":{{"nested":[{token}]}}}}}}"#
                ),
                format!(r#"{{"version":1,"kind":"event","sequence":"0","name":"x","payload":{{"nested":[{token}]}}}}"#),
            ] {
                assert!(
                    decode(format!("{envelope}\n").as_bytes()).is_err(),
                    "accepted {envelope}"
                );
            }
        }
    }

    #[test]
    fn rejects_invalid_schemas() {
        let cases = [
            json!({"version":2,"kind":"request","id":"a","command":"x","params":{}}),
            json!({"version":1,"kind":"other"}),
            json!({"version":1,"kind":"request","id":"","command":"x","params":{}}),
            json!({"version":1,"kind":"request","id":"a","command":"","params":{}}),
            json!({"version":1,"kind":"request","id":"a","command":"x","params":[]}),
            json!({"version":1,"kind":"response","id":"a"}),
            json!({"version":1,"kind":"response","id":"a","result":null,"error":{"detail":"x"}}),
            json!({"version":1,"kind":"response","id":"a","error":null}),
            json!({"version":1,"kind":"response","id":"a","error":{"detail":42}}),
            json!({"version":1,"kind":"response","id":"a","error":{"detail":"x","code":1}}),
            json!({"version":1,"kind":"hello","protocol":"wrong","sessionID":"s","capabilities":[]}),
            json!({"version":1,"kind":"hello","protocol":"tez.native","sessionID":"s","capabilities":[1]}),
            json!({"version":1,"kind":"event","sequence":"1","name":"event"}),
        ];
        for value in cases {
            assert!(Frame::new(value.clone()).is_err(), "accepted {value}");
        }
    }

    #[test]
    fn rejects_noncanonical_sequences() {
        for sequence in ["", "01", "-1", "+1", "1.0", " 1", "١"] {
            assert!(
                Frame::new(json!({"version":1,"kind":"event","sequence":sequence,"name":"x","payload":null})).is_err()
            );
        }
        for sequence in ["0", "1", "100"] {
            assert!(
                Frame::new(json!({"version":1,"kind":"event","sequence":sequence,"name":"x","payload":null})).is_ok()
            );
        }
    }

    #[test]
    fn rejects_blank_malformed_invalid_utf8_and_truncated_frames() {
        for bytes in [b"\n".as_slice(), b" \n", b"{\n", b"\xff\n", b"{}"] {
            assert!(decode(bytes).is_err());
        }
        assert!(decode(b"").unwrap().is_empty());
    }

    #[test]
    fn rejects_duplicate_envelope_keys_including_escaped_equivalents() {
        for bytes in [
            br#"{"version":1,"kind":"response","id":"a","result":null,"id":"b"}
"#
            .as_slice(),
            br#"{"version":1,"kind":"response","id":"a","result":null,"\u0069d":"b"}
"#,
        ] {
            assert!(decode(bytes).is_err());
        }
    }

    #[test]
    fn accepts_exact_limit_and_rejects_oversize() {
        let mut value = json!({"version":1,"kind":"response","id":"a","result":""});
        let overhead = Frame::new(value.clone()).unwrap().encode().unwrap().len();
        value["result"] = Value::String("x".repeat(MAX_FRAME_BYTES - overhead));
        let encoded = Frame::new(value.clone()).unwrap().encode().unwrap();
        assert_eq!(encoded.len(), MAX_FRAME_BYTES);
        assert_eq!(decode(&encoded).unwrap().len(), 1);
        value["result"] = Value::String("x".repeat(MAX_FRAME_BYTES - overhead + 1));
        assert!(Frame::new(value).unwrap().encode().is_err());
        assert!(Decoder::new().push(&vec![b'x'; MAX_FRAME_BYTES]).is_err());
        assert!(Decoder::new().push(&vec![b'x'; MAX_FRAME_BYTES + 1]).is_err());
    }

    #[test]
    fn decodes_multiple_frames_per_chunk_and_checks_final_eof() {
        let frame = Frame::new(json!({"version":1,"kind":"response","id":"a","result":true}))
            .unwrap()
            .encode()
            .unwrap();
        let mut bytes = frame.clone();
        bytes.extend_from_slice(&frame);
        assert_eq!(decode(&bytes).unwrap().len(), 2);
        bytes.extend_from_slice(b"{");
        assert!(decode(&bytes).is_err());
    }
}
