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
pub struct ThreadReply {
    pub id: String,
    pub author: String,
    pub source: AnnotationSource,
    pub body: String,
    pub created: String,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub replies: Vec<ThreadReply>,
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

                // Pass 3: exact search in stripped text
                let exact = format!("{}{}", ctx, tgt);
                let found = stripped_lower.find(&exact).map(|b| (byte_to_char(b), 0usize))
                    .or_else(|| {
                        let spaced = format!("{} {}", ctx, tgt);
                        stripped_lower.find(&spaced).map(|b| (byte_to_char(b), 1usize))
                    });
                if let Some((match_ci, space)) = found {
                    let from_ci = match_ci + ctx_chars + space;
                    let to_ci = from_ci + tgt_chars;
                    let raw_start = if from_ci < pos_map.len() {
                        pos_map[from_ci]
                    } else {
                        raw_end_from(from_ci)
                    };
                    return Some((raw_start, raw_end_from(to_ci)));
                }

                // Pass 4: normalized fuzzy — strip stray markers and collapse whitespace,
                // then search again with a warning when this fallback is used.
                let norm_ctx = normalize_for_fuzzy(&ctx);
                let norm_tgt = normalize_for_fuzzy(&tgt);
                let norm_ctx_chars = norm_ctx.chars().count();
                let norm_tgt_chars = norm_tgt.chars().count();
                let (norm_stripped, norm_map) = normalize_with_map(&stripped_lower);
                let norm_search = format!("{}{}", norm_ctx, norm_tgt);
                if let Some(norm_byte) = norm_stripped.find(&norm_search) {
                    let norm_from = norm_stripped[..norm_byte].chars().count() + norm_ctx_chars;
                    let norm_to = norm_from + norm_tgt_chars;
                    if let Some(&stripped_from) = norm_map.get(norm_from) {
                        if stripped_from < pos_map.len() {
                            let stripped_to = norm_map
                                .get(norm_to)
                                .copied()
                                .unwrap_or_else(|| stripped.chars().count());
                            let raw_start = pos_map[stripped_from];
                            let raw_end = raw_end_from(stripped_to);
                            eprintln!(
                                "warning: strict anchor failed, matched via normalization at offset {}",
                                raw_start
                            );
                            return Some((raw_start, raw_end));
                        }
                    }
                }
                None
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
    strip_markdown_impl(doc, true)
}

fn strip_markdown_impl(doc: &str, at_block_start: bool) -> (String, Vec<usize>) {
    let mut stripped = String::new();
    let mut pos_map: Vec<usize> = Vec::new();

    let chars: Vec<(usize, char)> = doc.char_indices().collect();
    let n = chars.len();
    let mut i = 0;
    let mut at_line_start = at_block_start;

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
                        for &(bp, ch) in &chars[content_start..cs] {
                            stripped.push(ch);
                            pos_map.push(bp);
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
                for &(bp, ch) in &chars[tick_start..j.min(n)] {
                    stripped.push(ch);
                    pos_map.push(bp);
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
                            let inner_byte_start = chars[content_start].0;
                            let inner_byte_end = chars[cs].0;
                            let (inner_stripped, inner_pos_map) =
                                strip_markdown_impl(&doc[inner_byte_start..inner_byte_end], false);
                            stripped.push_str(&inner_stripped);
                            for offset in inner_pos_map {
                                pos_map.push(inner_byte_start + offset);
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
                    for &(bp, ch) in &chars[open_start..j.min(n)] {
                        stripped.push(ch);
                        pos_map.push(bp);
                    }
                    i = j.min(n);
                }
                continue;
            }
            // mlen > 3: not a formatting marker — emit as literal
            for &(bp, ch) in &chars[open_start..i] {
                stripped.push(ch);
                pos_map.push(bp);
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
                    let inner_byte_start = chars[content_start].0;
                    let inner_byte_end = chars[j].0;
                    let (inner_stripped, inner_pos_map) =
                        strip_markdown_impl(&doc[inner_byte_start..inner_byte_end], false);
                    stripped.push_str(&inner_stripped);
                    for offset in inner_pos_map {
                        pos_map.push(inner_byte_start + offset);
                    }
                    i = j + 2;
                    closed = true;
                    break;
                }
                j += 1;
            }
            if !closed {
                for &(bp, ch) in &chars[open_start..j.min(n)] {
                    stripped.push(ch);
                    pos_map.push(bp);
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

/// Returns the plain-text representation of `doc` as seen by the anchoring engine.
pub fn render_plain_text(doc: &str) -> String {
    strip_markdown(doc).0
}

/// Strips formatting markers and collapses whitespace runs to a single space.
fn normalize_for_fuzzy(s: &str) -> String {
    let mut out = String::new();
    let mut last_space = false;
    for ch in s.chars() {
        if matches!(ch, '*' | '_' | '~' | '`') {
            continue;
        }
        if ch.is_whitespace() {
            if !last_space {
                out.push(' ');
            }
            last_space = true;
        } else {
            out.push(ch);
            last_space = false;
        }
    }
    out
}

/// Same as `normalize_for_fuzzy` but also returns a map from normalized char index
/// to original char index, for remapping positions back after a fuzzy match.
fn normalize_with_map(s: &str) -> (String, Vec<usize>) {
    let mut norm = String::new();
    let mut map: Vec<usize> = Vec::new();
    let mut last_space = false;
    for (ci, ch) in s.chars().enumerate() {
        if matches!(ch, '*' | '_' | '~' | '`') {
            continue;
        }
        if ch.is_whitespace() {
            if !last_space {
                norm.push(' ');
                map.push(ci);
            }
            last_space = true;
        } else {
            norm.push(ch);
            map.push(ci);
            last_space = false;
        }
    }
    (norm, map)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn ann(context_before: &str, target: Option<&str>) -> Annotation {
        Annotation {
            id: "test".into(),
            kind: AnnotationKind::Comment,
            source: AnnotationSource::Agent,
            author: "test".into(),
            context_before: context_before.into(),
            target: target.map(|s| s.into()),
            replacement: None,
            comment: None,
            created: "2026-01-01T00:00:00Z".into(),
            resolved: false,
            resolved_as: None,
            resolved_at: None,
            replies: vec![],
        }
    }

    // ── strip_markdown ────────────────────────────────────────────────────────

    #[test]
    fn strip_heading_marker() {
        let (s, _) = strip_markdown("## Hello world");
        assert_eq!(s, "Hello world");
    }

    #[test]
    fn strip_bold_markers() {
        let (s, _) = strip_markdown("Some **bold** text.");
        assert_eq!(s, "Some bold text.");
    }

    #[test]
    fn strip_italic_markers() {
        let (s, _) = strip_markdown("Some *italic* text.");
        assert_eq!(s, "Some italic text.");
    }

    #[test]
    fn strip_list_marker() {
        let (s, _) = strip_markdown("- List item text");
        assert_eq!(s, "List item text");
    }

    #[test]
    fn strip_preserves_inline_code_content() {
        let (s, _) = strip_markdown("Use `foo()` here.");
        assert_eq!(s, "Use foo() here.");
    }

    #[test]
    fn block_boundaries_concatenated_without_separator() {
        let (s, _) = strip_markdown("First paragraph.\n\nSecond paragraph.");
        assert_eq!(s, "First paragraph.Second paragraph.");
    }

    #[test]
    fn pos_map_offset_for_heading() {
        // "## Hello world" → stripped "Hello world", 'H' is at raw byte 3
        let (s, map) = strip_markdown("## Hello world");
        assert_eq!(s, "Hello world");
        assert_eq!(map[0], 3); // 'H'
        assert_eq!(map[5], 8); // ' ' between Hello and world
    }

    #[test]
    fn pos_map_offset_for_bold() {
        // "Some **bold** text." → stripped "Some bold text.", 'b' is at raw byte 7
        let (s, map) = strip_markdown("Some **bold** text.");
        assert_eq!(s, "Some bold text.");
        assert_eq!(map[5], 7); // 'b' of "bold"
    }

    #[test]
    fn strip_nested_bold_inside_italic() {
        let (s, _) = strip_markdown("*italic with **bold** inside*");
        assert_eq!(s, "italic with bold inside");
    }

    #[test]
    fn strip_nested_italic_inside_bold() {
        let (s, _) = strip_markdown("**bold with _italic_ inside**");
        assert_eq!(s, "bold with italic inside");
    }

    #[test]
    fn strip_nested_bold_pos_map() {
        // "*a **b** c*" — 'b' is nested inside italic+bold.
        // Raw bytes: 0:'*', 1:'a', 2:' ', 3:'*', 4:'*', 5:'b', 6:'*', 7:'*', 8:' ', 9:'c', 10:'*'
        // Stripped: "a b c"
        let (s, map) = strip_markdown("*a **b** c*");
        assert_eq!(s, "a b c");
        assert_eq!(map[0], 1); // 'a' at raw byte 1
        assert_eq!(map[2], 5); // 'b' at raw byte 5
        assert_eq!(map[4], 9); // 'c' at raw byte 9
    }

    // ── Annotation::anchor ────────────────────────────────────────────────────

    #[test]
    fn anchor_target_in_middle_of_paragraph() {
        let doc = "Hello world, this is a test.";
        assert_eq!(ann("Hello ", Some("world")).anchor(doc), Some((6, 11)));
    }

    #[test]
    fn anchor_target_at_end_of_first_block() {
        // "line." ends the first paragraph; raw search finds it directly.
        let doc = "First line.\n\nSecond line.";
        assert_eq!(ann("First ", Some("line.")).anchor(doc), Some((6, 11)));
    }

    #[test]
    fn anchor_case_insensitive() {
        let doc = "Hello World.";
        assert_eq!(ann("HELLO ", Some("WORLD")).anchor(doc), Some((6, 11)));
    }

    #[test]
    fn anchor_no_target_returns_insertion_point() {
        // insert/comment annotations have no target; both offsets are identical.
        let doc = "Hello world.";
        assert_eq!(ann("Hello ", None).anchor(doc), Some((6, 6)));
    }

    #[test]
    fn anchor_not_found_returns_none() {
        let doc = "Hello world.";
        assert_eq!(ann("does not exist", Some("here")).anchor(doc), None);
    }

    #[test]
    fn anchor_stripped_bold_target() {
        // context_before and target are plain text; the doc has **bold** markers.
        // Raw search "Some important" won't match; stripped search will.
        // "Some **important** text." — 'i' of "important" is at raw byte 7.
        let doc = "Some **important** text.";
        assert_eq!(ann("Some ", Some("important")).anchor(doc), Some((7, 16)));
    }

    #[test]
    fn anchor_target_in_first_bullet_after_heading() {
        // "## Header\n\n- First bullet text"
        // 'F' of "First" is at raw byte 13 (after `## Header\n\n- `).
        // context_before = "Header" (plain rendered text, no `## ` prefix).
        // Pass 1 raw: "headerfirst" not in raw doc (block markers and newlines separate them).
        // Pass 3 stripped: "HeaderFirst bullet text" → from_ci=6 → pos_map[6]=13.
        let doc = "## Header\n\n- First bullet text";
        assert_eq!(
            ann("Header", Some("First")).anchor(doc),
            Some((13, 18))
        );
    }

    #[test]
    fn anchor_target_in_first_bullet_context_crosses_boundary() {
        // Verifies that when context_before is rendered text from the heading and the
        // target is the first word of the following bullet, anchoring resolves to the
        // bullet and not to anything inside the heading.
        let doc = "## Intro\n\n- Start of bullet here";
        // "Intro" ends at raw byte 8. "- " is at 10-11. 'S' of "Start" is at raw byte 12.
        assert_eq!(
            ann("Intro", Some("Start")).anchor(doc),
            Some((12, 17))
        );
    }

    #[test]
    fn anchor_context_spans_block_boundary() {
        // Stripped text concatenates blocks with no separator, so context_before
        // can bridge a paragraph boundary that is invisible in rendered text.
        // "End of first.\n\nStart of second." — 's' of "second." is at raw byte 24.
        let doc = "End of first.\n\nStart of second.";
        assert_eq!(
            ann("End of first.Start of ", Some("second.")).anchor(doc),
            Some((24, 31))
        );
    }

    #[test]
    fn anchor_nested_bold_inside_italic() {
        // The reported bug: agent targets "documented instructions" but the doc has
        // *...**documented instructions**...* — nested bold inside italic.
        // After the fix, Pass 3 (stripped) resolves correctly.
        let doc = "*This paragraph has **documented instructions** inside it.*";
        // Raw bytes: 0:'*', then "This paragraph has " (1-19), then "**" (20-21),
        // then "documented instructions" (22-44), then "**" (45-46), ...
        let result = ann("This paragraph has ", Some("documented instructions")).anchor(doc);
        assert!(result.is_some(), "should anchor nested bold target");
        let (start, end) = result.unwrap();
        assert_eq!(&doc[start..end], "documented instructions");
    }

    #[test]
    fn strip_list_marker_inside_inline_span() {
        // Recursive strip_markdown_impl must start with at_line_start=false so that
        // "- " at the start of span content is NOT stripped as a list marker.
        let (s, _) = strip_markdown("*- list item*");
        assert_eq!(s, "- list item");
    }

    #[test]
    fn anchor_empty_target_at_doc_end_no_panic() {
        // When target="" and context_before ends at the document end,
        // from_ci == pos_map.len() — must not panic.
        let doc = "hello";
        let result = ann("hello", Some("")).anchor(doc);
        assert!(result.is_some());
        let (start, end) = result.unwrap();
        assert_eq!(start, end); // insertion point at end of doc
    }

    #[test]
    fn anchor_fuzzy_stray_markers() {
        // If the target contains stray markers (e.g. agent forgot to strip them),
        // Pass 4 normalized fuzzy match finds the annotation anyway.
        let doc = "Some important text here.";
        // Target has stray markers that should have been stripped; fuzzy removes them.
        let result = ann("Some ", Some("**important**")).anchor(doc);
        assert!(result.is_some(), "fuzzy pass should match stray-marker target");
        let (start, end) = result.unwrap();
        assert_eq!(&doc[start..end], "important");
    }

    // ── ThreadReply serialization ─────────────────────────────────────────────

    #[test]
    fn reply_round_trip() {
        let mut a = ann("Hello ", Some("world"));
        a.replies.push(ThreadReply {
            id: "reply-1".into(),
            author: "me".into(),
            source: AnnotationSource::Local,
            body: "Looks good".into(),
            created: "2026-06-01T00:00:00Z".into(),
        });
        let json = serde_json::to_string(&a).unwrap();
        let decoded: Annotation = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.replies.len(), 1);
        assert_eq!(decoded.replies[0].body, "Looks good");
    }

    #[test]
    fn reply_backward_compat_missing_key() {
        let json = r#"{
            "id":"t","kind":"comment","source":"agent","author":"a",
            "context_before":"x","created":"2026-01-01T00:00:00Z","resolved":false
        }"#;
        let a: Annotation = serde_json::from_str(json).unwrap();
        assert!(a.replies.is_empty());
    }

    #[test]
    fn empty_replies_omitted_from_json() {
        let a = ann("Hello ", Some("world"));
        let json = serde_json::to_string(&a).unwrap();
        assert!(!json.contains("replies"));
    }
}
