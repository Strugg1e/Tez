use anyhow::Result;
use futures::StreamExt as _;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{net::UnixStream, task::JoinHandle};
use tokio_tungstenite::{
    client_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};

const CAPACITY: usize = 1000;

struct Buffer {
    lines: VecDeque<String>,
    last_read: Instant,
    gap: bool,
    truncated: bool,
}

pub(crate) struct NativeLogStream {
    buffer: Arc<Mutex<Buffer>>,
    socket: Option<PathBuf>,
    worker: Option<JoinHandle<()>>,
}

impl NativeLogStream {
    pub fn new() -> Self {
        Self {
            buffer: Arc::new(Mutex::new(Buffer {
                lines: VecDeque::new(),
                last_read: Instant::now(),
                gap: false,
                truncated: false,
            })),
            socket: None,
            worker: None,
        }
    }

    pub async fn connect(&mut self, socket: &Path) -> Result<bool> {
        if self.socket.as_deref() == Some(socket) && self.worker.as_ref().is_some_and(|worker| !worker.is_finished()) {
            return Ok(false);
        }
        if let Some(worker) = self.worker.take() {
            worker.abort();
        }
        let reconnect = self.socket.is_some();
        let stream = tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(socket)).await??;
        let config = WebSocketConfig::default()
            .max_message_size(Some(64 * 1024))
            .max_frame_size(Some(64 * 1024));
        let (mut stream, _) = tokio::time::timeout(
            Duration::from_secs(5),
            client_async_with_config("ws://localhost/logs?level=debug", stream, Some(config)),
        )
        .await??;
        self.socket = Some(socket.to_owned());
        {
            let mut buffer = self.buffer.lock().unwrap();
            if reconnect {
                buffer.gap = true;
            }
            buffer.last_read = Instant::now();
        }
        let buffer = self.buffer.clone();
        self.worker = Some(tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            loop {
                tokio::select! {
                    message = stream.next() => match message {
                        Some(Ok(Message::Text(text))) => {
                            let parsed = serde_json::from_str::<Value>(&text).ok();
                            if let Some(value) = parsed {
                                if let (Some(level), Some(payload)) = (value["type"].as_str(), value["payload"].as_str()) {
                                    let line = format!("{} [{}] {}", chrono::Local::now().format("%m-%d %H:%M:%S"), level, payload.chars().take(4096).collect::<String>());
                                    let mut state = buffer.lock().unwrap();
                                    if payload.chars().count() > 4096 { state.truncated = true; }
                                    if state.lines.len() == CAPACITY { state.lines.pop_front(); state.truncated = true; }
                                    state.lines.push_back(line);
                                } else {
                                    buffer.lock().unwrap().gap = true;
                                }
                            } else {
                                buffer.lock().unwrap().gap = true;
                            }
                        }
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                        _ => {}
                    },
                    _ = interval.tick() => {
                        if buffer.lock().unwrap().last_read.elapsed() > Duration::from_secs(12) { break; }
                    }
                }
            }
        }));
        Ok(true)
    }

    pub fn seed(&mut self, lines: Vec<String>) {
        let mut buffer = self.buffer.lock().unwrap();
        if lines.iter().any(|line| line.chars().count() > 4096) {
            buffer.truncated = true;
        }
        let mut combined: VecDeque<_> = lines
            .into_iter()
            .map(|line| line.chars().take(4096).collect())
            .collect();
        combined.append(&mut buffer.lines);
        while combined.len() > CAPACITY {
            combined.pop_front();
            buffer.truncated = true;
        }
        buffer.lines = combined;
    }

    pub fn read(&self, limit: usize, level: &str, query: &str) -> Value {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.last_read = Instant::now();
        let streaming = self.worker.as_ref().is_some_and(|worker| !worker.is_finished());
        if self.socket.is_some() && !streaming {
            buffer.gap = true;
        }
        let response_limited = buffer.lines.iter().map(String::len).sum::<usize>() > 1024 * 1024;
        json!({"lines":crate::native_workspace::filter_logs(buffer.lines.iter().cloned().collect(), limit, level, query),
            "gap":buffer.gap,"truncated":buffer.truncated || response_limited,"streaming":streaming})
    }

    pub fn reset(&mut self) {
        if let Some(worker) = self.worker.take() {
            worker.abort();
        }
        self.socket = None;
        let mut buffer = self.buffer.lock().unwrap();
        buffer.lines.clear();
        buffer.gap = false;
        buffer.truncated = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Context as _;
    use futures::SinkExt as _;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn native_log_stream_retains_burst_beyond_service_ring() -> Result<()> {
        let path = std::env::temp_dir().join(format!("tez-log-test-{}.sock", nanoid::nanoid!()));
        let listener = UnixListener::bind(&path)?;
        let (sent, finished) = tokio::sync::oneshot::channel();
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
            for index in 0..150 {
                ws.send(Message::Text(
                    json!({"type":"info","payload":format!("fixture-{index}")})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
            }
            let _ = sent.send(());
            let _ = wait.await;
        });
        let mut logs = NativeLogStream::new();
        logs.connect(&path).await.context("stream connect")?;
        finished.await?;
        for _ in 0..100 {
            if logs.buffer.lock().unwrap().lines.len() == 150 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let result = logs.read(1000, "all", "fixture-");
        assert_eq!(result["lines"].as_array().unwrap().len(), 150);
        assert_eq!(result["gap"], false);
        logs.reset();
        logs.seed(vec![format!("[info] {}", "x".repeat(4097))]);
        assert_eq!(logs.read(1000, "all", "")["truncated"], true);
        logs.reset();
        let _ = release.send(());
        server.await?;
        std::fs::remove_file(path)?;
        Ok(())
    }

    #[test]
    fn native_log_stream_reports_capacity_and_response_limits() {
        let mut logs = NativeLogStream::new();
        logs.seed((0..1001).map(|index| format!("[info] {index}")).collect());
        assert_eq!(logs.read(1000, "all", "")["lines"].as_array().unwrap().len(), 1000);
        assert_eq!(logs.read(1000, "all", "")["truncated"], true);
        logs.reset();
        logs.seed(vec![format!("[info] {}", "x".repeat(4000)); 300]);
        assert_eq!(logs.read(1000, "all", "")["truncated"], true);
        assert!(serde_json::to_vec(&logs.read(1000, "all", "")).unwrap().len() < 8 * 1024 * 1024);
    }

    #[tokio::test]
    async fn native_log_stream_marks_interrupted_connection_after_reconnect() -> Result<()> {
        let path = std::env::temp_dir().join(format!("tez-log-reconnect-{}.sock", nanoid::nanoid!()));
        let listener = UnixListener::bind(&path)?;
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            let (first, _) = listener.accept().await.unwrap();
            let mut first = tokio_tungstenite::accept_async(first).await.unwrap();
            first
                .send(Message::Text(
                    json!({"type":"info","payload":"before"}).to_string().into(),
                ))
                .await
                .unwrap();
            drop(first);
            let (second, _) = listener.accept().await.unwrap();
            let _second = tokio_tungstenite::accept_async(second).await.unwrap();
            let _ = wait.await;
        });
        let mut logs = NativeLogStream::new();
        logs.connect(&path).await?;
        for _ in 0..200 {
            if logs.worker.as_ref().is_some_and(|worker| worker.is_finished()) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(logs.worker.as_ref().is_some_and(|worker| worker.is_finished()));
        assert_eq!(logs.read(1000, "all", "")["streaming"], false);
        assert_eq!(logs.read(1000, "all", "")["gap"], true);
        assert!(logs.connect(&path).await?);
        let result = logs.read(1000, "all", "");
        assert_eq!(result["gap"], true);
        assert_eq!(result["lines"].as_array().unwrap().len(), 1);
        logs.reset();
        let _ = release.send(());
        server.await?;
        std::fs::remove_file(path)?;
        Ok(())
    }
}
