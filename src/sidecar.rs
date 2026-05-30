use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AnnotationKind {
    Replace,
    Delete,
    Insert,
    Comment,
    Highlight,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AnnotationSource {
    Local,
    Agent,
    Github,
    Gitlab,
}

impl std::fmt::Display for AnnotationSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Local => write!(f, "local"),
            Self::Agent => write!(f, "agent"),
            Self::Github => write!(f, "github"),
            Self::Gitlab => write!(f, "gitlab"),
        }
    }
}

impl std::fmt::Display for AnnotationKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Replace => write!(f, "replace"),
            Self::Delete => write!(f, "delete"),
            Self::Insert => write!(f, "insert"),
            Self::Comment => write!(f, "comment"),
            Self::Highlight => write!(f, "highlight"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Annotation {
    pub id: String,
    pub kind: AnnotationKind,
    pub source: AnnotationSource,
    pub author: String,
    pub context_before: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replacement: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    pub created: String,
    pub resolved: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_as: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_at: Option<String>,
}

impl Annotation {
    /// Returns the byte offset of the start of `target` within `doc`.
    /// Uses case-insensitive matching of `context_before + target`.
    /// Tries exact concatenation first, then with a single space between them
    /// (common when context_before ends at a word boundary).
    pub fn anchor(&self, doc: &str) -> Option<usize> {
        let doc_lower = doc.to_lowercase();
        let context_lower = self.context_before.to_lowercase();

        match &self.target {
            Some(target) => {
                let target_lower = target.to_lowercase();
                // Try exact concatenation
                let search = format!("{}{}", context_lower, target_lower);
                if let Some(pos) = doc_lower.find(&search) {
                    return Some(pos + self.context_before.len());
                }
                // Try with a space separator
                let search_spaced = format!("{} {}", context_lower, target_lower);
                doc_lower
                    .find(&search_spaced)
                    .map(|pos| pos + self.context_before.len() + 1)
            }
            None => {
                // insert/comment: anchor to end of context_before
                doc_lower
                    .find(&context_lower)
                    .map(|pos| pos + self.context_before.len())
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sidecar {
    pub version: u32,
    pub annotations: Vec<Annotation>,
}

impl Sidecar {
    pub fn empty() -> Self {
        Self {
            version: 1,
            annotations: Vec::new(),
        }
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("cannot read {}: {}", path.display(), e))?;
        let sidecar: Self = serde_json::from_str(&content)
            .map_err(|e| anyhow::anyhow!("invalid sidecar JSON: {}", e))?;
        if sidecar.version != 1 {
            anyhow::bail!(
                "unsupported sidecar version {} (expected 1)",
                sidecar.version
            );
        }
        Ok(sidecar)
    }

    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }
}

#[allow(dead_code)]
pub fn generate_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    // mix with a counter using the thread id pointer as entropy
    let ptr = &nanos as *const _ as u64;
    let hash = nanos as u64 ^ (ptr.wrapping_mul(0x9e3779b97f4a7c15));
    let chars: Vec<char> = "abcdefghijklmnopqrstuvwxyz0123456789".chars().collect();
    let s: String = (0..8)
        .map(|i| chars[((hash >> (i * 4)) & 0x1f) as usize % chars.len()])
        .collect();
    format!("ann_{}", s)
}

pub fn now_iso8601() -> String {
    // Simple ISO 8601 UTC timestamp without extra deps
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // days since epoch → date (Gregorian, approximate but correct for recent dates)
    let (year, month, day) = days_to_ymd(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, h, m, s
    )
}

fn days_to_ymd(days: u64) -> (u64, u64, u64) {
    // Algorithm: civil_from_days (Howard Hinnant)
    let z = days + 719468;
    let era = z / 146097;
    let doe = z % 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}
