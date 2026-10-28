use std::io::Write;
use std::process::{Command, Output, Stdio};

fn roundtrip(input: &[u8]) -> Output {
    let mut process = Command::new(env!("CARGO_BIN_EXE_tez-backend-wire"))
        .arg("--roundtrip")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    process.stdin.take().unwrap().write_all(input).unwrap();
    process.wait_with_output().unwrap()
}

#[test]
fn cli_normalizes_valid_frames_without_diagnostics() {
    let output = roundtrip(b"{ \"version\": 1, \"kind\": \"response\", \"id\": \"r\", \"result\": null }\n");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(output.stdout.last(), Some(&b'\n'));
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(value["result"].is_null());
    assert_eq!(value["id"], "r");
}

#[test]
fn cli_rejects_malformed_and_unterminated_input() {
    for input in [b"\n".as_slice(), b"{}\n", b"{\"version\":1}"] {
        let output = roundtrip(input);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
    }
}
