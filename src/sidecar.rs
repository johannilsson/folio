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
        anchor_raw_bytes(doc, &self.context_before, self.target.as_deref())
    }
}

/// Search `doc` for `context_before` + `target`, returning `(raw_start, raw_end)`
/// byte offsets into `doc`. Shared by `Annotation::anchor` (CLI patching) and
/// `anchor_raw_chars` (browser raw-mode anchoring) so both work off the same
/// proven 4-pass matcher without requiring a full `Annotation` in hand.
fn anchor_raw_bytes(doc: &str, context_before: &str, target: Option<&str>) -> Option<(usize, usize)> {
    // Decode HTML entities from annotation values so that agents who copied
    // raw entity text (e.g. &amp;) match the same way as agents who used the
    // rendered output (e.g. &).
    let ctx_decoded = decode_html_entities(context_before);
    let tgt_decoded = target.map(decode_html_entities);
    let has_entities =
        ctx_decoded != context_before || tgt_decoded.as_deref() != target;

        let doc_lower = doc.to_lowercase();
        let ctx = ctx_decoded.to_lowercase();

        // --- Passes 1 & 2: raw search ---
        // Skip when the annotation contained HTML entities: the decoded text may
        // produce partial-entity matches against the raw bytes (e.g. "&" matching
        // the "&" inside "&amp;"), so fall straight to the stripped pass instead.
        if !has_entities {
            match &tgt_decoded {
                Some(target) => {
                    let tgt = target.to_lowercase();
                    let exact = format!("{}{}", ctx, tgt);
                    if let Some(pos) = doc_lower.find(&exact) {
                        let start = pos + ctx_decoded.len();
                        let end = start + target.len();
                        if !ends_at_partial_entity(&doc_lower, end) {
                            return Some((start, end));
                        }
                    }
                    let spaced = format!("{} {}", ctx, tgt);
                    if let Some(pos) = doc_lower.find(&spaced) {
                        let start = pos + ctx_decoded.len() + 1;
                        let end = start + target.len();
                        if !ends_at_partial_entity(&doc_lower, end) {
                            return Some((start, end));
                        }
                    }
                }
                None => {
                    if let Some(pos) = doc_lower.find(&ctx) {
                        let offset = pos + ctx_decoded.len();
                        return Some((offset, offset));
                    }
                }
            }
        }

        // --- Pass 3: stripped search ---
        // strip_markdown decodes HTML entities. raw_spans[i] holds the raw byte
        // width of each stripped char (entity_len bytes for entities, char.len_utf8()
        // otherwise), so raw_end_from gives the correct byte boundary even when a
        // decoded entity is the last char of the matched range.
        let (stripped, pos_map, raw_spans) = strip_markdown(doc);
        let stripped_lower = stripped.to_lowercase();

        // context_before/target may themselves contain markdown syntax (e.g. an
        // agent copied a raw table row, pipes and all, into context_before) that
        // won't appear verbatim in the already-stripped document — strip them the
        // same way before searching, mirroring what anchor_chars (the browser's
        // rendered-text resolver) already does. Stripping plain text is a no-op,
        // so this only ever adds matches, never removes ones passes 1/2 found.
        let ctx_stripped_lower = strip_markdown(&ctx_decoded).0.to_lowercase();
        let ctx_chars = ctx_stripped_lower.chars().count();

        // Convert a byte offset in stripped_lower to a char index.
        let byte_to_char = |b: usize| stripped_lower[..b].chars().count();

        // Given char index `end_ci` (exclusive end), compute the raw byte end.
        let raw_end_from = |end_ci: usize| -> usize {
            if end_ci == 0 {
                return 0;
            }
            pos_map[end_ci - 1] + raw_spans[end_ci - 1]
        };

        match &tgt_decoded {
            Some(target) => {
                let tgt_stripped_lower = strip_markdown(target).0.to_lowercase();
                let tgt_chars = tgt_stripped_lower.chars().count();

                // Pass 3: exact search in stripped text
                let exact = format!("{}{}", ctx_stripped_lower, tgt_stripped_lower);
                let found = stripped_lower.find(&exact).map(|b| (byte_to_char(b), 0usize))
                    .or_else(|| {
                        let spaced = format!("{} {}", ctx_stripped_lower, tgt_stripped_lower);
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
                // Also strip a stray leading/trailing table pipe: context_before
                // can end mid-row (e.g. "...text |") without the row's own "|"
                // prefix, so strip_markdown never recognizes it as table syntax
                // and leaves the pipe (and its padding space) in place.
                let norm_ctx = normalize_for_fuzzy(strip_trailing_table_pipe(&ctx_stripped_lower));
                let norm_tgt = normalize_for_fuzzy(strip_leading_table_pipe(&tgt_stripped_lower));
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
                stripped_lower.find(&ctx_stripped_lower).map(|b| {
                    let end_ci = byte_to_char(b) + ctx_chars;
                    let raw = raw_end_from(end_ci);
                    (raw, raw)
                })
            }
        }
    }

/// Char-offset variant of `anchor_raw_bytes`, for the browser's CM6 raw-mode editor.
/// Like `anchor_raw_bytes`, but converts the result to **char** indices (JS
/// string offsets are per-code-unit, not per-byte) into the raw, unstripped
/// `doc` — i.e. offsets that cover the literal source text including `**`,
/// `#`, list markers, table pipes, etc.
pub fn anchor_raw_chars(doc: &str, context_before: &str, target: Option<&str>) -> Option<(usize, usize)> {
    let (byte_from, byte_to) = anchor_raw_bytes(doc, context_before, target)?;
    let char_from = doc[..byte_from].chars().count();
    let char_to = char_from + doc[byte_from..byte_to].chars().count();
    Some((char_from, char_to))
}

/// Strip inline and block-level markdown markers from `doc`, returning:
/// - the plain-text content as a `String`
/// - a `pos_map` where `pos_map[i]` is the raw byte offset of the i-th char
/// - a `raw_spans` where `raw_spans[i]` is the raw byte width of the i-th char
///   (1 for regular ASCII, >1 for multi-byte Unicode or decoded HTML entities)
///
/// Block boundaries (newlines) are dropped; text is concatenated with no separator,
/// matching the frontend's ProseMirror `findAnchor` behaviour.
fn strip_markdown(doc: &str) -> (String, Vec<usize>, Vec<usize>) {
    strip_markdown_impl(doc, true)
}

fn strip_markdown_impl(doc: &str, at_block_start: bool) -> (String, Vec<usize>, Vec<usize>) {
    let mut stripped = String::new();
    let mut pos_map: Vec<usize> = Vec::new();
    let mut raw_spans: Vec<usize> = Vec::new();

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
            // Horizontal rule: "---", "***", "___" or spaced "- - -" etc.
            // Checked before list markers so "- - -" is caught here rather than as "- " + stray chars.
            if matches!(ch, '-' | '*' | '_') {
                let line_end = {
                    let mut j = i;
                    while j < n && chars[j].1 != '\n' {
                        j += 1;
                    }
                    j
                };
                let is_hr = {
                    let mut cnt = 0usize;
                    let mut only_hr = true;
                    for &(_, c) in &chars[i..line_end] {
                        if c == ch {
                            cnt += 1;
                        } else if c != ' ' {
                            only_hr = false;
                            break;
                        }
                    }
                    only_hr && cnt >= 3
                };
                if is_hr {
                    i = line_end;
                    continue;
                }
                // Not a horizontal rule — fall through to list-marker / inline checks.
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
            // Table row: "| cell | cell |"
            // Alignment rows (|---|---|) are skipped; data rows emit trimmed cell text only.
            if ch == '|' {
                let line_end = {
                    let mut j = i;
                    while j < n && chars[j].1 != '\n' {
                        j += 1;
                    }
                    j
                };
                let is_alignment = {
                    let line_str: String =
                        chars[i..line_end].iter().map(|&(_, c)| c).collect();
                    let inner = line_str.trim_start_matches('|').trim_end_matches('|');
                    inner.split('|').filter(|c| !c.trim().is_empty()).all(|cell| {
                        let t = cell.trim();
                        !t.is_empty() && t.chars().all(|c| matches!(c, '-' | ':'))
                    })
                };
                if is_alignment {
                    i = line_end;
                    continue;
                }
                // Data row: iterate cells, strip inline markdown from each trimmed cell.
                let mut cell_start = i + 1; // skip the leading '|'
                while cell_start <= line_end {
                    let cell_end = {
                        let mut j = cell_start;
                        while j < line_end && chars[j].1 != '|' {
                            j += 1;
                        }
                        j
                    };
                    if cell_end > cell_start {
                        let mut ts = cell_start;
                        while ts < cell_end && chars[ts].1 == ' ' {
                            ts += 1;
                        }
                        let mut te = cell_end;
                        while te > ts && chars[te - 1].1 == ' ' {
                            te -= 1;
                        }
                        if te > ts {
                            let bstart = chars[ts].0;
                            let bend = if te < n { chars[te].0 } else { doc.len() };
                            let (is, ip, ir) =
                                strip_markdown_impl(&doc[bstart..bend], false);
                            stripped.push_str(&is);
                            for off in ip {
                                pos_map.push(bstart + off);
                            }
                            raw_spans.extend(ir);
                        }
                    }
                    if cell_end >= line_end {
                        break;
                    }
                    cell_start = cell_end + 1;
                }
                i = line_end;
                continue;
            }
            // Fenced code block: ```lang\n...\n``` or ~~~lang\n...\n~~~
            // Skip the entire block so diagram source (mermaid, plantuml, etc.)
            // is not included in the stripped text and does not shift offsets.
            if ch == '`' || ch == '~' {
                let fence_char = ch;
                let mut j = i;
                let mut fence_len = 0usize;
                while j < n && chars[j].1 == fence_char {
                    fence_len += 1;
                    j += 1;
                }
                if fence_len >= 3 {
                    // skip info string / language tag on opening line
                    while j < n && chars[j].1 != '\n' {
                        j += 1;
                    }
                    // find matching closing fence
                    'fence: while j < n {
                        j += 1; // step past '\n'
                        let mut close_len = 0usize;
                        while j < n && chars[j].1 == fence_char {
                            close_len += 1;
                            j += 1;
                        }
                        if close_len >= fence_len {
                            // skip trailing content on closing fence line
                            while j < n && chars[j].1 != '\n' {
                                j += 1;
                            }
                            break 'fence;
                        }
                        // not a closing fence — skip rest of line
                        while j < n && chars[j].1 != '\n' {
                            j += 1;
                        }
                    }
                    i = j;
                    continue;
                }
                // fewer than 3 fence chars — fall through to inline code handler
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
                            raw_spans.push(ch.len_utf8());
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
                    raw_spans.push(ch.len_utf8());
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
                            let (inner_stripped, inner_pos_map, inner_raw_spans) =
                                strip_markdown_impl(&doc[inner_byte_start..inner_byte_end], false);
                            stripped.push_str(&inner_stripped);
                            for offset in inner_pos_map {
                                pos_map.push(inner_byte_start + offset);
                            }
                            raw_spans.extend(inner_raw_spans);
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
                        raw_spans.push(ch.len_utf8());
                    }
                    i = j.min(n);
                }
                continue;
            }
            // mlen > 3: not a formatting marker — emit as literal
            for &(bp, ch) in &chars[open_start..i] {
                stripped.push(ch);
                pos_map.push(bp);
                raw_spans.push(ch.len_utf8());
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
                    let (inner_stripped, inner_pos_map, inner_raw_spans) =
                        strip_markdown_impl(&doc[inner_byte_start..inner_byte_end], false);
                    stripped.push_str(&inner_stripped);
                    for offset in inner_pos_map {
                        pos_map.push(inner_byte_start + offset);
                    }
                    raw_spans.extend(inner_raw_spans);
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
                    raw_spans.push(ch.len_utf8());
                }
                i = j.min(n);
            }
            continue;
        }

        // --- Image: ![alt](url) → emit only the alt text (same as a regular link) ---
        if ch == '!' && i + 1 < n && chars[i + 1].1 == '[' {
            let mut j = i + 2;
            while j < n && chars[j].1 != ']' && chars[j].1 != '\n' {
                j += 1;
            }
            if j < n && chars[j].1 == ']' && j + 1 < n && chars[j + 1].1 == '(' {
                let mut k = j + 2;
                while k < n && chars[k].1 != ')' && chars[k].1 != '\n' {
                    k += 1;
                }
                if k < n && chars[k].1 == ')' {
                    i += 1; // skip '!'; next iteration processes '[alt](url)' as a regular link
                    continue;
                }
            }
            // Not a valid image pattern — fall through and emit '!' literally.
        }

        // --- Markdown link: [text](url) → emit only the link text ---
        if ch == '[' {
            // Scan forward for the closing ']', stopping at newline.
            let mut j = i + 1;
            while j < n && chars[j].1 != ']' && chars[j].1 != '\n' {
                j += 1;
            }
            if j < n && chars[j].1 == ']' && j + 1 < n && chars[j + 1].1 == '(' {
                // Scan for the closing ')', stopping at newline.
                let mut k = j + 2;
                while k < n && chars[k].1 != ')' && chars[k].1 != '\n' {
                    k += 1;
                }
                if k < n && chars[k].1 == ')' {
                    // Valid [text](url): recursively strip the link text.
                    if i + 1 < j {
                        let text_byte_start = chars[i + 1].0;
                        let text_byte_end = chars[j].0;
                        let (inner_stripped, inner_pos_map, inner_raw_spans) =
                            strip_markdown_impl(&doc[text_byte_start..text_byte_end], false);
                        stripped.push_str(&inner_stripped);
                        for offset in inner_pos_map {
                            pos_map.push(text_byte_start + offset);
                        }
                        raw_spans.extend(inner_raw_spans);
                    }
                    i = k + 1;
                    continue;
                }
            }
            // Not a valid link pattern: fall through and emit '[' literally.
        }

        // --- HTML entity: &amp; &lt; &gt; &quot; &apos; ---
        // Decode so that pos_map[i+1] points past the full entity bytes, not just
        // the single '&' byte. This keeps raw_end_from() correct for accept patches.
        if ch == '&' {
            if let Some((decoded, entity_len)) = decode_html_entity(&chars[i..]) {
                // Compute the entity's raw byte span: all entity chars are ASCII so
                // entity_len chars == entity_len bytes.
                stripped.push(decoded);
                pos_map.push(bp);
                raw_spans.push(entity_len);
                i += entity_len;
                continue;
            }
        }

        // --- Regular character ---
        stripped.push(ch);
        pos_map.push(bp);
        raw_spans.push(ch.len_utf8());
        i += 1;
    }

    (stripped, pos_map, raw_spans)
}

/// Returns true if a raw match ending at `raw_end` in `doc` ended at the `&`
/// of an HTML entity (e.g. matched "&" but the doc has "&amp;").
/// Used to reject partial-entity hits in the raw Pass 1/2 search.
fn ends_at_partial_entity(doc: &str, raw_end: usize) -> bool {
    if raw_end == 0 || raw_end > doc.len() {
        return false;
    }
    if !doc[..raw_end].ends_with('&') {
        return false;
    }
    let after = &doc[raw_end..];
    after.starts_with("amp;")
        || after.starts_with("lt;")
        || after.starts_with("gt;")
        || after.starts_with("quot;")
        || after.starts_with("apos;")
        || after.starts_with("nbsp;")
        || after.starts_with("#39;")
        || after.starts_with("#34;")
}

/// If `chars` starts with a named HTML entity, return `(decoded_char, entity_char_count)`.
fn decode_html_entity(chars: &[(usize, char)]) -> Option<(char, usize)> {
    if chars.first().map(|(_, c)| *c) != Some('&') {
        return None;
    }
    let mut s = String::new();
    for (idx, &(_, c)) in chars.iter().enumerate() {
        s.push(c);
        if idx > 0 && c == ';' {
            let decoded = match s.as_str() {
                "&amp;" => '&',
                "&lt;" => '<',
                "&gt;" => '>',
                "&quot;" => '"',
                "&apos;" | "&#39;" => '\'',
                "&nbsp;" => '\u{00A0}',
                _ => return None,
            };
            return Some((decoded, idx + 1));
        }
        if idx >= 9 {
            break;
        }
    }
    None
}

/// Decode common HTML entities in a string (used to normalise annotation fields).
fn decode_html_entities(s: &str) -> String {
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    let n = chars.len();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < n {
        let (_, ch) = chars[i];
        if ch == '&' {
            if let Some((decoded, entity_len)) = decode_html_entity(&chars[i..]) {
                out.push(decoded);
                i += entity_len;
                continue;
            }
        }
        out.push(ch);
        i += 1;
    }
    out
}

/// Returns the plain-text representation of `doc` as seen by the anchoring engine.
pub fn render_plain_text(doc: &str) -> String {
    strip_markdown(doc).0
}

/// Search `doc` for an annotation identified by `context_before` + `target`,
/// returning `(from_ci, to_ci)` — character indices of the target in the
/// rendered plain text (i.e. what `render_plain_text` produces).
///
/// Both the document and annotation fields are stripped of markdown syntax
/// before searching, so the returned indices correspond directly to the
/// character sequence that `buildCharPos` constructs in the frontend.
///
/// Returns `None` if no match is found.
pub fn anchor_chars(
    doc: &str,
    context_before: &str,
    target: Option<&str>,
) -> Option<(usize, usize)> {
    let (ctx_stripped, _, _) = strip_markdown(context_before);
    let ctx = ctx_stripped.to_lowercase();
    let ctx_chars = ctx.chars().count();

    let tgt_stripped = target.map(|t| strip_markdown(t).0);

    let (stripped_doc, _, _) = strip_markdown(doc);
    let stripped_lower = stripped_doc.to_lowercase();

    let byte_to_char = |b: usize| stripped_lower[..b].chars().count();

    match tgt_stripped.as_deref() {
        Some(tgt_str) => {
            let tgt = tgt_str.to_lowercase();
            let tgt_chars = tgt.chars().count();

            // Exact then spaced search in stripped text
            let found = stripped_lower
                .find(&format!("{}{}", ctx, tgt))
                .map(|b| (byte_to_char(b), 0usize))
                .or_else(|| {
                    stripped_lower
                        .find(&format!("{} {}", ctx, tgt))
                        .map(|b| (byte_to_char(b), 1usize))
                });

            if let Some((match_ci, space)) = found {
                let from_ci = match_ci + ctx_chars + space;
                let to_ci = from_ci + tgt_chars;
                return Some((from_ci, to_ci));
            }

            // Fuzzy: strip stray markers, collapse whitespace, try both separators
            let norm_ctx = normalize_for_fuzzy(&ctx);
            let norm_tgt = normalize_for_fuzzy(&tgt);
            let norm_ctx_chars = norm_ctx.chars().count();
            let norm_tgt_chars = norm_tgt.chars().count();
            let (norm_stripped, norm_map) = normalize_with_map(&stripped_lower);

            for sep in &["", " "] {
                let needle = format!("{}{}{}", norm_ctx, sep, norm_tgt);
                if let Some(norm_byte) = norm_stripped.find(&needle) {
                    let norm_ci = norm_stripped[..norm_byte].chars().count();
                    let norm_from = norm_ci + norm_ctx_chars + sep.len();
                    let norm_to = norm_from + norm_tgt_chars;
                    if let Some(&from_ci) = norm_map.get(norm_from) {
                        let to_ci = norm_map
                            .get(norm_to)
                            .copied()
                            .unwrap_or_else(|| stripped_doc.chars().count());
                        return Some((from_ci, to_ci));
                    }
                }
            }

            None
        }
        None => {
            if let Some(b) = stripped_lower.find(&ctx) {
                let end_ci = byte_to_char(b) + ctx_chars;
                return Some((end_ci, end_ci));
            }
            // Fuzzy fallback: handles padding spaces in table rows, etc.
            let norm_ctx = normalize_for_fuzzy(&ctx);
            let norm_ctx_chars = norm_ctx.chars().count();
            let (norm_stripped, norm_map) = normalize_with_map(&stripped_lower);
            if let Some(norm_byte) = norm_stripped.find(&norm_ctx) {
                let norm_ci = norm_stripped[..norm_byte].chars().count();
                let norm_end = norm_ci + norm_ctx_chars;
                let end_ci = norm_map
                    .get(norm_end)
                    .copied()
                    .unwrap_or_else(|| stripped_doc.chars().count());
                return Some((end_ci, end_ci));
            }
            None
        }
    }
}


/// Strips formatting markers and collapses whitespace runs to a single space.
/// Strips a stray trailing "|" (and any padding space before it) — the
/// closing pipe of a table row that ended up in context_before without the
/// leading "|" strip_markdown needs to recognize it as table syntax in the
/// first place. Leaves ordinary trailing whitespace (e.g. a context_before
/// ending "Some ") untouched — only strings that actually end in "|" are
/// affected.
fn strip_trailing_table_pipe(s: &str) -> &str {
    let trimmed = s.trim_end();
    match trimmed.strip_suffix('|') {
        Some(without_pipe) => without_pipe.trim_end(),
        None => s,
    }
}

/// Mirror of `strip_trailing_table_pipe`, for a stray leading "|".
fn strip_leading_table_pipe(s: &str) -> &str {
    let trimmed = s.trim_start();
    match trimmed.strip_prefix('|') {
        Some(without_pipe) => without_pipe.trim_start(),
        None => s,
    }
}

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
        let sidecar: Self = serde_json::from_str(&content).map_err(|e| {
            let line = e.line();
            let col = e.column();
            let lines: Vec<&str> = content.lines().collect();
            if line > 0 && line <= lines.len() {
                let bad_line = lines[line - 1];
                let caret = format!("{}^-- here", " ".repeat(col.saturating_sub(1)));
                anyhow::anyhow!(
                    "invalid sidecar JSON: {}\n\n{:>4} | {}\n       {}",
                    e,
                    line,
                    bad_line,
                    caret
                )
            } else {
                anyhow::anyhow!("invalid sidecar JSON: {}", e)
            }
        })?;
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
        let (s, _, _) = strip_markdown("## Hello world");
        assert_eq!(s, "Hello world");
    }

    #[test]
    fn strip_bold_markers() {
        let (s, _, _) = strip_markdown("Some **bold** text.");
        assert_eq!(s, "Some bold text.");
    }

    #[test]
    fn strip_italic_markers() {
        let (s, _, _) = strip_markdown("Some *italic* text.");
        assert_eq!(s, "Some italic text.");
    }

    #[test]
    fn strip_list_marker() {
        let (s, _, _) = strip_markdown("- List item text");
        assert_eq!(s, "List item text");
    }

    #[test]
    fn strip_preserves_inline_code_content() {
        let (s, _, _) = strip_markdown("Use `foo()` here.");
        assert_eq!(s, "Use foo() here.");
    }

    #[test]
    fn block_boundaries_concatenated_without_separator() {
        let (s, _, _) = strip_markdown("First paragraph.\n\nSecond paragraph.");
        assert_eq!(s, "First paragraph.Second paragraph.");
    }

    #[test]
    fn anchor_chars_returns_char_indices() {
        // "## Heading\n\nThe target sentence here."
        // stripped: "HeadingThe target sentence here."
        // ctx = "HeadingThe " (11 chars), tgt = "target" (6 chars)
        // → from_ci = 11, to_ci = 17
        let doc = "## Heading\n\nThe target sentence here.";
        let (from, to) = anchor_chars(doc, "HeadingThe ", Some("target")).unwrap();
        assert_eq!(from, 11);
        assert_eq!(to, 17);
    }

    #[test]
    fn anchor_chars_strips_link_syntax_in_annotation() {
        let doc = "see REF-001 for details";
        let (from, to) = anchor_chars(doc, "see ", Some("[REF-001](docs/other.md) for details")).unwrap();
        assert_eq!(from, 4);
        assert_eq!(to, 23);
    }

    #[test]
    fn anchor_raw_chars_returns_raw_char_indices() {
        // Unlike anchor_chars, markdown syntax counts toward the offsets: the
        // returned range covers the literal raw text "target", including the
        // fact that context_before itself contains "## " and "**".
        let doc = "## Heading\n\nThe **target** sentence here.";
        let (from, to) = anchor_raw_chars(doc, "## Heading\n\nThe **", Some("target")).unwrap();
        assert_eq!(from, 18);
        assert_eq!(to, 24);
        let matched: String = doc.chars().skip(from).take(to - from).collect();
        assert_eq!(matched, "target");
    }

    #[test]
    fn anchor_raw_chars_handles_multibyte_before_target() {
        // Regression guard for byte-vs-char: a multibyte café/em-dash prefix
        // must not throw off char indices the way raw byte offsets would.
        let doc = "café — the target word";
        let (from, to) = anchor_raw_chars(doc, "café — the ", Some("target")).unwrap();
        assert_eq!(from, "café — the ".chars().count());
        assert_eq!(to, from + "target".chars().count());
        let matched: String = doc.chars().skip(from).take(to - from).collect();
        assert_eq!(matched, "target");
    }

    #[test]
    fn anchor_raw_chars_no_target_table_row_with_pipe_padding_mismatch() {
        // Regression for the pet-nat bug: a comment annotation (no target) whose
        // context_before is a raw table row copied without the file's actual
        // column padding. Pass 1 (raw exact) fails on the padding mismatch, and
        // pre-fix, pass 3 also failed because it searched the raw, pipe-containing
        // context_before against the already-pipe-stripped document.
        let doc = "| Orange wine    | 1 week – 6 months          | Result |\n| Next row | x | y |";
        let ctx = "| Orange wine | 1 week – 6 months | Result |";
        let (from, to) = anchor_raw_chars(doc, ctx, None).unwrap();
        assert_eq!(from, to); // comment/insert — insertion point, no range
    }

    #[test]
    fn anchor_raw_chars_context_ends_mid_table_row_stray_trailing_pipe() {
        // Regression for ann_demo005: context_before ends with the closing "|"
        // of the PREVIOUS table row ("...is a flaw |\n") but doesn't start with
        // "|" itself, so strip_markdown never enters table-row parsing for that
        // fragment and leaves the pipe (plus its padding space) in place —
        // mismatching the fully-stripped document, which has zero characters
        // between "flaw" and the next row's first cell.
        let doc = "| A | B | pronounced VA is a flaw |\n\
                   | Mousiness | Fault | Lactic bacteria producing THP; irreversible |\n";
        let ctx = "pronounced VA is a flaw |\n";
        let target = "| Mousiness | Fault | Lactic bacteria producing THP; irreversible |";
        let (from, to) = anchor_raw_chars(doc, ctx, Some(target)).unwrap();
        let matched: String = doc.chars().skip(from).take(to - from).collect();
        assert_eq!(matched, target);
    }

    #[test]
    fn anchor_chars_no_target_fuzzy_table_spacing() {
        // Table pipes and padding are stripped, so a context_before that uses pipes
        // ("| Orange wine |...") matches the stripped cell text via the exact pass.
        let doc = "| Orange wine    | 1 week – 6 months          | Result |\n| Next row | x | y |";
        let ctx = "| Orange wine | 1 week – 6 months | Result |";
        let (from, to) = anchor_chars(doc, ctx, None).unwrap();
        assert_eq!(from, to); // insert/comment — no range
    }

    #[test]
    fn strip_markdown_horizontal_rule_skipped() {
        let (s, _, _) = strip_markdown("---");
        assert_eq!(s, "");
        let (s, _, _) = strip_markdown("***");
        assert_eq!(s, "");
        let (s, _, _) = strip_markdown("- - -");
        assert_eq!(s, "");
        // Text before and after a horizontal rule is preserved.
        let (s, _, _) = strip_markdown("Before.\n\n---\n\nAfter.");
        assert_eq!(s, "Before.After.");
    }

    #[test]
    fn strip_markdown_image_emits_alt_only() {
        let (s, _, _) = strip_markdown("see ![diagram](img.png) here");
        assert_eq!(s, "see diagram here");
        // Lone '!' without a valid image pattern is emitted literally.
        let (s, _, _) = strip_markdown("not an image !");
        assert_eq!(s, "not an image !");
    }

    #[test]
    fn strip_markdown_table_alignment_row_skipped() {
        let (s, _, _) = strip_markdown("| --- | --- |");
        assert_eq!(s, "");
        // Colon-aligned variants are also skipped.
        let (s, _, _) = strip_markdown("| :---: | ---: |");
        assert_eq!(s, "");
    }

    #[test]
    fn strip_markdown_table_data_row_extracts_cells() {
        let (s, map, _) = strip_markdown("| Cell1 | Cell2 |");
        assert_eq!(s, "Cell1Cell2");
        // 'C' of Cell1 is at raw byte 2; 'C' of Cell2 is at raw byte 10.
        assert_eq!(map[0], 2);
        assert_eq!(map[5], 10);
    }

    #[test]
    fn strip_markdown_table_inline_formatting_in_cell() {
        let (s, _, _) = strip_markdown("| **Bold** | `code` |");
        assert_eq!(s, "Boldcode");
    }

    #[test]
    fn anchor_chars_after_table_correct_char_indices() {
        // stripped: "Section ACol1Col2ABTarget sentence here."
        //            9         8      2  21                   = 40 chars total
        // "AB" ends at char 19; target starts at 19, ends at 40.
        let doc = "## Section A\n\n| Col1 | Col2 |\n|------|------|\n| A    | B    |\n\nTarget sentence here.";
        let (from, to) = anchor_chars(doc, "AB", Some("Target sentence here.")).unwrap();
        assert_eq!(from, 19);
        assert_eq!(to, 40);
    }

    #[test]
    fn strip_markdown_fenced_code_block_skipped() {
        let (s, _, _) = strip_markdown("```mermaid\ngraph TD\nA --> B\n```");
        assert_eq!(s, "");
        // Tilde fences also skipped.
        let (s, _, _) = strip_markdown("~~~\nsome code\n~~~");
        assert_eq!(s, "");
        // Text before and after the block is preserved.
        let (s, _, _) = strip_markdown("Before.\n\n```\ncode\n```\n\nAfter.");
        assert_eq!(s, "Before.After.");
    }

    #[test]
    fn anchor_chars_after_mermaid_diagram() {
        // Diagram source must not appear in stripped text so char indices after it are correct.
        // anchor_chars returns char indices into the stripped text, not byte offsets into doc.
        let doc = "## Intro\n\n```mermaid\ngraph TD\n    A --> B\n    B --> C\n```\n\nThis sentence follows the diagram.";
        let (stripped, _, _) = strip_markdown(doc);
        assert!(!stripped.contains("graph"), "diagram source should be stripped");
        // stripped = "IntroThis sentence follows the diagram." — 39 chars total
        let (from, to) = anchor_chars(doc, "Intro", Some("This sentence follows the diagram.")).unwrap();
        let chars: Vec<char> = stripped.chars().collect();
        let extracted: String = chars[from..to].iter().collect();
        assert_eq!(extracted, "This sentence follows the diagram.");
    }

    #[test]
    fn anchor_chars_repro_italic_target_across_bullet_boundary() {
        // Reproducer from bug report: replace annotation whose target contains
        // *primary* (italic) and whose context_before ends at the previous bullet.
        let doc = "# Repro\n\n### Section\n\n\
- Bullet Alpha ends with the word widget because the widget layer is what matters, not the wrapper by itself.\n\
- Bullet Beta describes the *primary* control path and how it interacts with the wrapper before any downstream call. Without this ordering, a stale wrapper could cause the first call after startup to fail against the widget once the switch to *primary* has happened.\n\
- Bullet Gamma plans for the eventual widget change.";

        let context_before = "the widget layer is what matters, not the wrapper by itself.";
        let target = "Bullet Beta describes the *primary* control path and how it interacts with the wrapper before any downstream call. Without this ordering, a stale wrapper could cause the first call after startup to fail against the widget once the switch to *primary* has happened.";

        let (stripped, _, _) = strip_markdown(doc);
        let (from_ci, to_ci) = anchor_chars(doc, context_before, Some(target)).unwrap();
        let chars: Vec<char> = stripped.chars().collect();

        // from_ci must land on 'B' of "Bullet Beta", not somewhere inside Bullet Alpha.
        assert_eq!(chars[from_ci], 'B', "from_ci={} should be 'B' (start of Bullet Beta), got '{}'", from_ci, chars[from_ci]);
        let extracted: String = chars[from_ci..to_ci].iter().collect();
        // The extracted range should match the stripped target (asterisks removed).
        let expected = "Bullet Beta describes the primary control path and how it interacts with the wrapper before any downstream call. Without this ordering, a stale wrapper could cause the first call after startup to fail against the widget once the switch to primary has happened.";
        assert_eq!(extracted, expected);
    }

    #[test]
    fn anchor_chars_returns_none_on_no_match() {
        let result = anchor_chars("Hello world", "missing ", Some("text"));
        assert!(result.is_none());
    }

    #[test]
    fn strip_markdown_link_to_text() {
        let (s, _, _) = strip_markdown("see [REF-001](docs/other.md) for details");
        assert_eq!(s, "see REF-001 for details");
    }

    #[test]
    fn strip_markdown_incomplete_link_emits_literally() {
        let (s, _, _) = strip_markdown("not a [link");
        assert_eq!(s, "not a [link");
    }

    #[test]
    fn strip_markdown_bracket_without_paren_emits_literally() {
        let (s, _, _) = strip_markdown("[not a link] (space before paren)");
        assert_eq!(s, "[not a link] (space before paren)");
    }

    #[test]
    fn pos_map_offset_for_heading() {
        // "## Hello world" → stripped "Hello world", 'H' is at raw byte 3
        let (s, map, _) = strip_markdown("## Hello world");
        assert_eq!(s, "Hello world");
        assert_eq!(map[0], 3); // 'H'
        assert_eq!(map[5], 8); // ' ' between Hello and world
    }

    #[test]
    fn pos_map_offset_for_bold() {
        // "Some **bold** text." → stripped "Some bold text.", 'b' is at raw byte 7
        let (s, map, _) = strip_markdown("Some **bold** text.");
        assert_eq!(s, "Some bold text.");
        assert_eq!(map[5], 7); // 'b' of "bold"
    }

    #[test]
    fn strip_nested_bold_inside_italic() {
        let (s, _, _) = strip_markdown("*italic with **bold** inside*");
        assert_eq!(s, "italic with bold inside");
    }

    #[test]
    fn strip_nested_italic_inside_bold() {
        let (s, _, _) = strip_markdown("**bold with _italic_ inside**");
        assert_eq!(s, "bold with italic inside");
    }

    #[test]
    fn strip_nested_bold_pos_map() {
        // "*a **b** c*" — 'b' is nested inside italic+bold.
        // Raw bytes: 0:'*', 1:'a', 2:' ', 3:'*', 4:'*', 5:'b', 6:'*', 7:'*', 8:' ', 9:'c', 10:'*'
        // Stripped: "a b c"
        let (s, map, _) = strip_markdown("*a **b** c*");
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
        let (s, _, _) = strip_markdown("*- list item*");
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

    // ── HTML entity handling ──────────────────────────────────────────────────

    #[test]
    fn strip_decodes_html_entities() {
        let (s, _, _) = strip_markdown("cats &amp; dogs");
        assert_eq!(s, "cats & dogs");
    }

    #[test]
    fn anchor_entity_in_doc_decoded_annotation() {
        // Doc has &amp; on disk; agent used folio render and wrote the decoded "&".
        // Pass 3 (stripped) must find it and the accepted byte range must span
        // all 5 bytes of &amp;, not just the leading "&".
        let doc = "foo &amp; bar";
        // "&amp;" occupies bytes 4-8; space after is byte 9.
        let result = ann("foo ", Some("&")).anchor(doc);
        assert!(result.is_some(), "decoded annotation should anchor against entity doc");
        let (start, end) = result.unwrap();
        assert_eq!(&doc[start..end], "&amp;");
    }

    #[test]
    fn anchor_entity_annotation_against_entity_doc() {
        // Agent copied &amp; literally from the raw file.
        // Pass 1 raw search finds it; byte range spans the full entity.
        let doc = "foo &amp; bar";
        let result = ann("foo ", Some("&amp;")).anchor(doc);
        assert!(result.is_some());
        let (start, end) = result.unwrap();
        assert_eq!(&doc[start..end], "&amp;");
    }

    #[test]
    fn anchor_entity_in_context_before() {
        // Entity appears in context_before, not target.
        let doc = "foo &amp; bar baz";
        let result = ann("foo &amp; bar ", Some("baz")).anchor(doc);
        assert!(result.is_some());
        let (start, end) = result.unwrap();
        assert_eq!(&doc[start..end], "baz");
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
