//! The link between the MCP server and the running macOS app. The app listens on a Unix
//! socket in the config folder (`app.sock`); the MCP server, a separate process that Claude
//! starts, connects when a tool asks about what the reader has open. One request and one
//! response per connection, each a line of JSON: `{"op": "state", ...}` answered by
//! `{"ok": ...}` or `{"error": "..."}`. The answers come from Swift (`AppServer`); this
//! module only moves the lines.

use serde_json::Value;
use std::path::PathBuf;

/// Why a question to the app got no answer.
#[derive(Debug, PartialEq)]
pub enum LiveError {
    /// Nothing is listening: Folio is not running, or is a build without the link.
    NotRunning,
    Failed(String),
}

impl std::fmt::Display for LiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotRunning => write!(f, "Folio is not running. Use the open tool to start it."),
            Self::Failed(message) => write!(f, "{message}"),
        }
    }
}

pub fn socket_path() -> anyhow::Result<PathBuf> {
    Ok(crate::set::config_dir()?.join("app.sock"))
}

/// Asks the running app. `args` is merged into the request next to `op`.
pub fn request(op: &str, args: Value) -> Result<Value, LiveError> {
    imp::request(op, args)
}

#[cfg(unix)]
mod imp {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::Path;
    use std::time::Duration;

    // A socket path has to fit in sockaddr_un (104 bytes on macOS, 108 on Linux).
    const MAX_PATH: usize = 100;
    // Revealing a file may open a window, so the app gets a while to answer.
    const ANSWER_TIMEOUT: Duration = Duration::from_secs(15);

    pub fn request(op: &str, args: Value) -> Result<Value, LiveError> {
        let path = socket_path().map_err(|e| LiveError::Failed(e.to_string()))?;
        let mut stream = UnixStream::connect(&path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => LiveError::NotRunning,
            _ => LiveError::Failed(format!("cannot reach Folio at {}: {e}", path.display())),
        })?;
        let failed = |e: std::io::Error| LiveError::Failed(format!("Folio did not answer: {e}"));
        stream.set_read_timeout(Some(ANSWER_TIMEOUT)).map_err(failed)?;
        stream.set_write_timeout(Some(ANSWER_TIMEOUT)).map_err(failed)?;

        let mut message = json!({ "op": op });
        if let (Some(into), Value::Object(from)) = (message.as_object_mut(), args) {
            into.extend(from);
        }
        writeln!(stream, "{message}").map_err(failed)?;

        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).map_err(failed)?;
        let answer: Value = serde_json::from_str(&line)
            .map_err(|_| LiveError::Failed("Folio gave an answer that is not JSON".to_string()))?;
        match answer.get("error").and_then(Value::as_str) {
            Some(error) => Err(LiveError::Failed(error.to_string())),
            None => Ok(answer.get("ok").cloned().unwrap_or(Value::Null)),
        }
    }

    /// Serves the socket on a thread of its own. `handler` gets each request line and returns the
    /// response line. Fails when another Folio already answers on the socket; a socket left
    /// behind by one that died is replaced.
    pub fn listen(path: &Path, handler: impl Fn(String) -> String + Send + Sync + 'static) -> std::io::Result<()> {
        if path.as_os_str().len() > MAX_PATH {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("socket path is too long: {}", path.display()),
            ));
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if path.exists() {
            if UnixStream::connect(path).is_ok() {
                return Err(std::io::Error::new(std::io::ErrorKind::AddrInUse, "another Folio is already serving"));
            }
            std::fs::remove_file(path)?;
        }
        let listener = UnixListener::bind(path)?;
        // Only this user may drive the app.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;

        let handler = std::sync::Arc::new(handler);
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let handler = handler.clone();
                std::thread::spawn(move || serve_connection(stream, &*handler));
            }
        });
        Ok(())
    }

    fn serve_connection(mut stream: UnixStream, handler: &dyn Fn(String) -> String) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let answer = handler(line);
        let _ = writeln!(stream, "{}", answer.trim_end());
    }

    /// Takes the socket away when the app quits.
    pub fn stop() {
        if let Ok(path) = socket_path() {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[cfg(not(unix))]
mod imp {
    use super::*;

    pub fn request(_op: &str, _args: Value) -> Result<Value, LiveError> {
        Err(LiveError::NotRunning)
    }

    pub fn listen(_path: &std::path::Path, _handler: impl Fn(String) -> String + Send + Sync + 'static) -> std::io::Result<()> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "the app link needs a Unix socket"))
    }

    pub fn stop() {}
}

pub use imp::{listen, stop};

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serde_json::json;

    // Socket paths are short; the system temp folder on a Mac is already most of the way to the limit.
    fn short_config(tag: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/folio-live-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_request_reaches_the_handler_and_its_answer_comes_back() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let dir = short_config("roundtrip");
        std::env::set_var("FOLIO_CONFIG_DIR", &dir);

        assert_eq!(request("state", json!({})), Err(LiveError::NotRunning));

        listen(&socket_path().unwrap(), |line| {
            let request: Value = serde_json::from_str(&line).unwrap();
            if request["op"] == "boom" {
                return json!({ "error": "it broke" }).to_string();
            }
            json!({ "ok": { "echo": request } }).to_string()
        })
        .unwrap();

        let answer = request("reveal", json!({ "file": "/a.md" })).unwrap();
        assert_eq!(answer["echo"], json!({ "op": "reveal", "file": "/a.md" }));
        assert_eq!(request("boom", json!({})), Err(LiveError::Failed("it broke".to_string())));

        // The socket is private to this user.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(socket_path().unwrap()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);

        // A second app does not take the socket from a live one.
        let again = listen(&socket_path().unwrap(), |_| String::new()).unwrap_err();
        assert_eq!(again.kind(), std::io::ErrorKind::AddrInUse);

        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_socket_left_by_a_dead_app_is_replaced() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let dir = short_config("stale");
        std::env::set_var("FOLIO_CONFIG_DIR", &dir);
        let path = socket_path().unwrap();

        // Bind and drop: the file stays, nothing answers.
        drop(std::os::unix::net::UnixListener::bind(&path).unwrap());
        assert!(path.exists());
        assert_eq!(request("state", json!({})), Err(LiveError::NotRunning));

        listen(&path, |_| json!({ "ok": 1 }).to_string()).unwrap();
        assert_eq!(request("state", json!({})), Ok(json!(1)));

        stop();
        assert!(!path.exists());
        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_path_too_long_for_a_socket_is_reported() {
        let long = PathBuf::from(format!("/tmp/{}/app.sock", "x".repeat(120)));
        let err = listen(&long, |_| String::new()).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
    }
}
