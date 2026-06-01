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
    /// Returns `(raw_start, raw_end)` byte offsets of `target` within `doc`.
    ///
    /// Three-pass strategy:
    /// 1. Raw exact: search raw markdown bytes (backward-compatible).
    /// 2. Raw spaced: same with a single space between context and target.
    /// 3. Stripped: strip inline markdown markers, search rendered plain text,
    ///    then map the found position back to raw byte offsets.
    ///
    /// For `insert`/`comment` (no target) both values are the same insertion point.
    pub fn anchor(&self, doc: &str) -> Option<(usize, usize)> {
        let doc_lower = doc.to_lowercase();
        let ctx = self.context_before.to_lowercase();

        // --- Passes 1 & 2: raw search ---
        match &self.target {
            Some(target) => {
                let tgt = target.to_lowercase();
                let exact = format!("{}{}", ctx, tgt);
                if let Some(pos) = doc_lower.find(&exact) {
                    let start = pos + self.context_before.len();
                    return Some((start, start + target.len()));
                }
                let spaced = format!("{} {}", ctx, tgt);
                if let Some(pos) = doc_lower.find(&spaced) {
                    let start = pos + self.context_before.len() + 1;
                    return Some((start, start + target.len()));
                }
            }
            None => {
                if let Some(pos) = doc_lower.find(&ctx) {
                    let offset = pos + self.context_before.len();
                    return Some((offset, offset));
                }
            }
        }

        // --- Pass 3: stripped search ---
        let (stripped, pos_map) = strip_markdown(doc);
        let stripped_lower = stripped.to_lowercase();
        let ctx_chars = self.context_before.chars().count();

        // Convert a byte offset in stripped_lower to a char index.
        let byte_to_char = |b: usize| stripped_lower[..b].chars().count();

        // Given char index `end_ci` (exclusive end), compute the raw byte end.
        let raw_end_from = |end_ci: usize| -> usize {
            if end_ci == 0 {
                return 0;
            }
            let last_raw = pos_map[end_ci - 1];
            let last_char = stripped.chars().nth(end_ci - 1).unwrap_or('\0');
            last_raw + last_char.len_utf8()
        };

        match &self.target {
            Some(target) => {
                let tgt = target.to_lowercase();
                let tgt_chars = target.chars().count();
                let exact = format!("{}{}", ctx, tgt);
                let found = stripped_lower.find(&exact).map(|b| (byte_to_char(b), 0usize))
                    .or_else(|| {
                        let spaced = format!("{} {}", ctx, tgt);
                        stripped_lower.find(&spaced).map(|b| (byte_to_char(b), 1usize))
                    });
                found.map(|(match_ci, space)| {
                    let from_ci = match_ci + ctx_chars + space;
                    let to_ci = from_ci + tgt_chars;
                    let raw_start = pos_map[from_ci];
                    let raw_end = raw_end_from(to_ci);
                    (raw_start, raw_end)
                })
            }
            None => {
                stripped_lower.find(&ctx).map(|b| {
                    let end_ci = byte_to_char(b) + ctx_chars;
                    let raw = raw_end_from(end_ci);
                    (raw, raw)
                })
            }
        }
    }
}

/// Strip inline and block-level markdown markers from `doc`, returning:
/// - the plain-text content as a `String`
/// - a `pos_map` where `pos_map[i]` is the raw byte offset of the i-th char
///
/// Block boundaries (newlines) are dropped; text is concatenated with no separator,
/// matching the frontend's ProseMirror `findAnchor` behaviour.
fn strip_markdown(doc: &str) -> (String, Vec<usize>) {
    let mut stripped = String::new();
    let mut pos_map: Vec<usize> = Vec::new();

    let chars: Vec<(usize, char)> = doc.char_indices().collect();
    let n = chars.len();
    let mut i = 0;
    let mut at_line_start = true;

    while i < n {
        let (bp, ch) = chars[i];

        if ch == '\n' {
            at_line_start = true;
            i += 1;
            continue;
        }

        // --- Line-start: skip indentation and block markers ---
        if at_line_start {
            if ch == ' ' || ch == '\t' {
                i += 1;
                continue;
            }
            at_line_start = false;

            // Heading: "# ", "## ", etc.
            if ch == '#' {
                while i < n && chars[i].1 == '#' {
                    i += 1;
                }
                if i < n && chars[i].1 == ' ' {
                    i += 1;
                }
                continue;
            }
            // Unordered list: "- ", "+ "  (and "* " handled below)
            if matches!(ch, '-' | '+') && i + 1 < n && chars[i + 1].1 == ' ' {
                i += 2;
                continue;
            }
            // "* " as list marker (when at line start)
            if ch == '*' && i + 1 < n && chars[i + 1].1 == ' ' {
                i += 2;
                continue;
            }
            // Ordered list: "1. ", "10. " etc.
            if ch.is_ascii_digit() {
                let save = i;
                while i < n && chars[i].1.is_ascii_digit() {
                    i += 1;
                }
                if i < n && chars[i].1 == '.' && i + 1 < n && chars[i + 1].1 == ' ' {
                    i += 2;
                    continue;
                }
                i = save; // not an ordered list item
            }
            // Blockquote: "> "
            if ch == '>' && i + 1 < n && chars[i + 1].1 == ' ' {
                i += 2;
                continue;
            }
        }

        // --- Inline code: `text` or ``text`` ---
        if ch == '`' {
            let tick_start = i;
            let mut ticks = 0;
            while i < n && chars[i].1 == '`' {
                ticks += 1;
                i += 1;
            }
            let content_start = i;
            let mut j = i;
            let mut closed = false;
            'code: while j < n && chars[j].1 != '\n' {
                if chars[j].1 == '`' {
                    let cs = j;
                    let mut ct = 0;
                    while j < n && chars[j].1 == '`' {
                        ct += 1;
                        j += 1;
                    }
                    if ct == ticks {
                        for k in content_start..cs {
                            stripped.push(chars[k].1);
                            pos_map.push(chars[k].0);
                        }
                        i = j;
                        closed = true;
                        break 'code;
                    }
                } else {
                    j += 1;
                }
            }
            if !closed {
                for k in tick_start..j.min(n) {
                    stripped.push(chars[k].1);
                    pos_map.push(chars[k].0);
                }
                i = j.min(n);
            }
            continue;
        }

        // --- Bold / italic: *, **, ***, _, __, ___ ---
        if ch == '*' || ch == '_' {
            let marker = ch;
            let open_start = i;
            let mut mlen = 0;
            while i < n && chars[i].1 == marker {
                mlen += 1;
                i += 1;
            }
            if mlen <= 3 {
                let content_start = i;
                let mut j = i;
                let mut closed = false;
                while j < n && chars[j].1 != '\n' {
                    if chars[j].1 == marker {
                        let cs = j;
                        let mut cl = 0;
                        while j < n && chars[j].1 == marker {
                            cl += 1;
                            j += 1;
                        }
                        if cl == mlen {
                            for k in content_start..cs {
                                stripped.push(chars[k].1);
                                pos_map.push(chars[k].0);
                            }
                            i = j;
                            closed = true;
                            break;
                        }
                        // Wrong close length; those chars are content — continue scanning
                    } else {
                        j += 1;
                    }
                }
                if !closed {
                    for k in open_start..j.min(n) {
                        stripped.push(chars[k].1);
                        pos_map.push(chars[k].0);
                    }
                    i = j.min(n);
                }
                continue;
            }
            // mlen > 3: not a formatting marker — emit as literal
            for k in open_start..i {
                stripped.push(chars[k].1);
                pos_map.push(chars[k].0);
            }
            continue;
        }

        // --- Strikethrough: ~~text~~ ---
        if ch == '~' && i + 1 < n && chars[i + 1].1 == '~' {
            let open_start = i;
            i += 2;
            let content_start = i;
            let mut j = i;
            let mut closed = false;
            while j + 1 < n && chars[j].1 != '\n' {
                if chars[j].1 == '~' && chars[j + 1].1 == '~' {
                    for k in content_start..j {
                        stripped.push(chars[k].1);
                        pos_map.push(chars[k].0);
                    }
                    i = j + 2;
                    closed = true;
                    break;
                }
                j += 1;
            }
            if !closed {
                for k in open_start..j.min(n) {
                    stripped.push(chars[k].1);
                    pos_map.push(chars[k].0);
                }
                i = j.min(n);
            }
            continue;
        }

        // --- Regular character ---
        stripped.push(ch);
        pos_map.push(bp);
        i += 1;
    }

    (stripped, pos_map)
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
