//! Open items: the task items in a markdown file that carry one of the tags `#investigate`,
//! `#waiting` or `#replied`, which a set collects into its Open list (docs/wiki-mode.md).
//!
//! ```text
//! - [ ] Key rotation: asked in review #waiting https://github.com/t/s/pull/42#issuecomment-981
//!   - Sam: the family is revoked by the gateway since v3
//! ```
//!
//! The markdown is the record: this only reads it. Ticked items (`- [x]`) are done and not collected.

use serde::Serialize;

/// The tags that make a task item an open one.
pub const TAGS: [&str; 3] = ["investigate", "waiting", "replied"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OpenItem {
    /// 1-based.
    pub line: usize,
    /// One of `TAGS`.
    pub tag: String,
    /// What the item says, without its tags, links and addresses.
    pub text: String,
    /// The pull or merge request (or other page) the question was asked in: the first `http(s)` address.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The annotation, passage or document it is about: the first `folio://` link.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folio: Option<String>,
    /// The first line nested under the item: where an answer is summed up.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// The open items of `markdown`, in order. A fenced block of code has none.
pub fn open_items(markdown: &str) -> Vec<OpenItem> {
    let lines: Vec<&str> = markdown.lines().collect();
    let mut items = Vec::new();
    let mut fenced = false;
    for (index, line) in lines.iter().enumerate() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let Some((indent, rest)) = unticked(line) else { continue };
        let Some(tag) = first_tag(rest) else { continue };
        items.push(OpenItem {
            line: index + 1,
            tag: tag.to_string(),
            text: clean(rest),
            url: address(rest, &["https://", "http://"]),
            folio: address(rest, &["folio://annotation", "folio://passage", "folio://document"]),
            note: nested(&lines[index + 1..], indent),
        });
    }
    items
}

/// Ticks the item on `line` (1-based): its `[ ]` becomes `[x]`. None when that line is not an unticked
/// task item.
pub fn tick(markdown: &str, line: usize) -> Option<String> {
    let mut out = String::with_capacity(markdown.len());
    let mut done = false;
    for (index, text) in markdown.split_inclusive('\n').enumerate() {
        if index + 1 == line {
            let (indent, _) = unticked(text.trim_end_matches(['\n', '\r']))?;
            let box_at = indent + text[indent..].find("[ ]")?;
            out.push_str(&text[..box_at]);
            out.push_str("[x]");
            out.push_str(&text[box_at + 3..]);
            done = true;
        } else {
            out.push_str(text);
        }
    }
    done.then_some(out)
}

/// `- [ ] text` (or `*`, `+`): the width of the indent, and the text after the box.
fn unticked(line: &str) -> Option<(usize, &str)> {
    let trimmed = line.trim_start();
    let indent = line.len() - trimmed.len();
    let rest = trimmed.strip_prefix(['-', '*', '+'])?.strip_prefix(' ')?.trim_start();
    let rest = rest.strip_prefix("[ ]")?;
    // The box is followed by a space, or it is not a task item.
    (rest.is_empty() || rest.starts_with(' ')).then(|| (indent, rest.trim_start()))
}

/// The first of the known tags the text carries, as `#tag` ending at a space or punctuation.
fn first_tag(text: &str) -> Option<&'static str> {
    tags(text).next().map(|(_, _, tag)| tag)
}

/// Each `#tag` in the text: where it starts and ends, and which it is.
fn tags(text: &str) -> impl Iterator<Item = (usize, usize, &'static str)> + '_ {
    text.match_indices('#').filter_map(move |(at, _)| {
        // Not the middle of a word or an address: `…#issuecomment-981` is not a tag.
        if text[..at].chars().next_back().is_some_and(|c| !c.is_whitespace() && !"([,;".contains(c)) {
            return None;
        }
        let word = &text[at + 1..];
        let end = word.find(|c: char| !(c.is_alphanumeric() || c == '-' || c == '_')).unwrap_or(word.len());
        let name = word[..end].to_lowercase();
        TAGS.iter().find(|tag| **tag == name).map(|tag| (at, at + 1 + end, *tag))
    })
}

/// The first address that starts with one of `starts`, up to a space or the `)` that closes its markdown link.
fn address(text: &str, starts: &[&str]) -> Option<String> {
    let at = starts.iter().filter_map(|start| text.find(start)).min()?;
    let tail = &text[at..];
    let end = tail.find(|c: char| c.is_whitespace() || c == ')' || c == '>').unwrap_or(tail.len());
    let found = tail[..end].trim_end_matches(['.', ',', ';', ':']);
    (!found.is_empty()).then(|| found.to_string())
}

/// The item's words: the tags, the markdown links to addresses and the bare addresses left out.
fn clean(text: &str) -> String {
    let mut text = text.to_string();
    // Back to front, so the places stay right.
    let found: Vec<_> = tags(&text).map(|(from, to, _)| (from, to)).collect();
    for (from, to) in found.into_iter().rev() {
        text.replace_range(from..to, "");
    }
    // `[label](https://…)` and `[label](folio://…)`.
    let mut out = String::new();
    let mut rest = text.as_str();
    while let Some(open) = rest.find('[') {
        let after = &rest[open..];
        let linked = after.find("](").and_then(|mid| {
            let close = after[mid..].find(')')? + mid;
            let target = &after[mid + 2..close];
            (target.starts_with("http://") || target.starts_with("https://") || target.starts_with("folio://")).then_some(close + 1)
        });
        match linked {
            Some(len) => {
                out.push_str(&rest[..open]);
                rest = &rest[open + len..];
            }
            None => {
                out.push_str(&rest[..open + 1]);
                rest = &rest[open + 1..];
            }
        }
    }
    out.push_str(rest);
    let words: Vec<&str> = out
        .split_whitespace()
        .filter(|word| !(word.starts_with("http://") || word.starts_with("https://") || word.starts_with("folio://")))
        .collect();
    // A comma that followed a tag is left with a space before it.
    words.join(" ").replace(" ,", ",").trim_end_matches([' ', ':', '-', '–', '—', ',']).to_string()
}

/// The first line under an item that is indented more than it: its answer, without a list marker.
fn nested(after: &[&str], indent: usize) -> Option<String> {
    let line = after.iter().find(|line| !line.trim().is_empty())?;
    let trimmed = line.trim_start();
    if line.len() - trimmed.len() <= indent {
        return None;
    }
    let text = trimmed.strip_prefix(['-', '*', '+']).filter(|rest| rest.starts_with(' ')).unwrap_or(trimmed);
    Some(text.trim().to_string()).filter(|text| !text.is_empty())
}

/// What a `folio://` link points at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum LinkTarget {
    /// `folio://document?…`: the file as a whole.
    Document,
    /// `folio://annotation/<id>?…`.
    Annotation { id: String },
    /// `folio://passage?…&q=…[&before=…]`: rendered text of the file, and the words just before it
    /// when it appears more than once.
    Passage {
        text: String,
        #[serde(skip_serializing_if = "String::is_empty")]
        before: String,
    },
}

/// A `folio://` link as `folio link` writes it: its target, and the file's repo, branch and path in
/// that checkout (`file`, where it was on disk, for an older link or a file in no repo).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FolioLink {
    #[serde(flatten)]
    pub target: LinkTarget,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

/// Where a file is, as links name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Here {
    pub repo: Option<String>,
    pub branch: Option<String>,
    /// The path in the checkout ("docs/t.md"), with `/` between folders.
    pub path: String,
    /// Absolute.
    pub file: std::path::PathBuf,
}

impl Here {
    pub fn of(file: &std::path::Path) -> Here {
        let file = crate::location::absolute(file);
        let root = crate::location::detect_root(&file);
        let identity = crate::location::repo_identity(&root);
        let path = file.strip_prefix(&root).unwrap_or(&file).to_string_lossy().replace('\\', "/");
        Here { repo: identity.as_ref().map(|i| i.repo.clone()), branch: identity.and_then(|i| i.branch), path, file }
    }
}

impl FolioLink {
    pub fn parse(url: &str) -> Option<FolioLink> {
        let rest = url.strip_prefix("folio://")?;
        let (head, query) = rest.split_once('?').unwrap_or((rest, ""));
        let pairs: Vec<(String, String)> = query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(key, value)| (key.to_string(), decode(value)))
            .collect();
        let get = |name: &str| pairs.iter().find(|(key, value)| key == name && !value.is_empty()).map(|(_, value)| value.clone());
        let target = match head.split_once('/').unwrap_or((head, "")) {
            ("document", _) => LinkTarget::Document,
            ("annotation", id) if !id.is_empty() => LinkTarget::Annotation { id: decode(id) },
            ("passage", _) => LinkTarget::Passage { text: get("q")?, before: get("before").unwrap_or_default() },
            _ => return None,
        };
        Some(FolioLink { target, repo: get("repo"), branch: get("branch"), path: get("path"), file: get("file") })
    }

    /// Whether the link names this file: by repo, branch and path when it has them (no branch: any
    /// checkout of the repo), else by where the file was. As `FolioLink.points(to:)` in the app.
    pub fn points_to(&self, here: &Here) -> bool {
        if let (Some(repo), Some(path)) = (&self.repo, &self.path) {
            return here.repo.as_ref() == Some(repo)
                && &here.path == path
                && (self.branch.is_none() || self.branch == here.branch);
        }
        self.file.as_ref().is_some_and(|file| crate::location::absolute(std::path::Path::new(file)) == here.file)
    }
}

/// Which open file a link means (as `FolioLink.resolve(among:)` in the app): a link names repo, branch
/// and path, never a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolution {
    /// The index in the files given.
    Found(usize),
    /// The repo is there but not on this branch any more.
    BranchGone(String),
    /// The repo is there on the branch, without this path.
    Missing(String),
    /// The link names no repo that is there (or none): go by `file`.
    Unknown,
}

pub fn resolve(link: &FolioLink, open: &[Here]) -> Resolution {
    let (Some(repo), Some(path)) = (&link.repo, &link.path) else { return Resolution::Unknown };
    let same: Vec<usize> = (0..open.len()).filter(|&i| open[i].repo.as_ref() == Some(repo)).collect();
    if same.is_empty() {
        return Resolution::Unknown;
    }
    let on_branch: Vec<usize> = same.into_iter().filter(|&i| link.branch.is_none() || open[i].branch == link.branch).collect();
    if on_branch.is_empty() {
        return Resolution::BranchGone(link.branch.clone().unwrap_or_default());
    }
    match on_branch.iter().find(|&&i| &open[i].path == path) {
        Some(&i) => Resolution::Found(i),
        None => Resolution::Missing(path.clone()),
    }
}

/// Whether what the link points at is in `file`: the document itself, an annotation its sidecar has,
/// unresolved, whose text the markdown still has, or a passage the markdown has. Anchored as the app does.
pub fn target_found(target: &LinkTarget, file: &std::path::Path) -> bool {
    let Ok(markdown) = std::fs::read_to_string(file) else { return false };
    match target {
        LinkTarget::Document => true,
        LinkTarget::Passage { text, before } => crate::sidecar::anchor_raw_chars(&markdown, before, Some(text)).is_some(),
        LinkTarget::Annotation { id } => {
            let Ok(sidecar) = crate::sidecar::Sidecar::load(&crate::location::folio_path(file)) else { return false };
            sidecar
                .annotations
                .iter()
                .find(|a| &a.id == id && !a.resolved)
                .is_some_and(|a| crate::sidecar::anchor_raw_chars(&markdown, &a.context_before, a.target.as_deref()).is_some())
        }
    }
}

/// Why a link cannot be followed among the `open` files, None when it can. The same reasons the app
/// greys a link with.
pub fn dead_reason(link: &FolioLink, open: &[Here]) -> Option<String> {
    let name = |file: &std::path::Path| file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let in_file = |file: &std::path::Path| (!target_found(&link.target, file)).then(|| format!("Not found in {}", name(file)));
    match resolve(link, open) {
        Resolution::Found(index) => in_file(&open[index].file),
        Resolution::BranchGone(branch) => Some(format!("{branch} isn't checked out any more")),
        Resolution::Missing(path) => Some(format!("{path} isn't in this checkout")),
        Resolution::Unknown => match &link.file {
            // Not in the set, but where the file was is still there.
            Some(file) if std::path::Path::new(file).is_file() => in_file(std::path::Path::new(file)),
            Some(file) => Some(match &link.repo {
                Some(repo) => format!("{repo} isn't in the set"),
                None => format!("{} isn't there any more", name(std::path::Path::new(file))),
            }),
            None => Some(link.repo.as_ref().map_or("The link names no file".to_string(), |repo| format!("{repo} isn't in the set"))),
        },
    }
}

/// The branch a link whose branch is gone can move to: the one checkout among `open` of the repo that
/// has the file. None when the link is not in that state, or two branches have the file (the reader's
/// call).
pub fn moved_to(link: &FolioLink, open: &[Here]) -> Option<usize> {
    if !matches!(resolve(link, open), Resolution::BranchGone(_)) {
        return None;
    }
    let (repo, path) = (link.repo.as_ref()?, link.path.as_ref()?);
    let has: Vec<usize> = (0..open.len()).filter(|&i| open[i].repo.as_ref() == Some(repo) && &open[i].path == path).collect();
    match has.as_slice() {
        [one] => Some(*one),
        _ => None,
    }
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        match (bytes[i], bytes.get(i + 1).copied().and_then(hex), bytes.get(i + 2).copied().and_then(hex)) {
            (b'%', Some(high), Some(low)) => {
                out.push((high * 16 + low) as u8);
                i += 3;
            }
            (b, ..) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A `folio://` link in a page, where it is and what it says.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Reference {
    /// 1-based.
    pub line: usize,
    /// The heading the link is under, else its line, short.
    pub context: String,
    /// The words of the markdown link (`[these](folio://…)`), empty for a bare one.
    pub label: String,
    pub url: String,
    #[serde(flatten)]
    pub link: FolioLink,
}

/// The `folio://document`, `folio://annotation` and `folio://passage` links of `markdown`, in order.
/// A fenced block of code has none.
pub fn references(markdown: &str) -> Vec<Reference> {
    let mut found = Vec::new();
    let mut heading: Option<String> = None;
    let mut fenced = false;
    for (index, line) in markdown.lines().enumerate() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let hashes = line.len() - line.trim_start_matches('#').len();
        if hashes > 0 && line[hashes..].starts_with(' ') {
            let title = line.trim_start_matches('#').trim().trim_end_matches('#').trim();
            if !title.is_empty() {
                heading = Some(title.to_string());
            }
        }
        for (at, _) in line.match_indices("folio://") {
            let tail = &line[at..];
            let end = tail.find(|c: char| c.is_whitespace() || ")>]\"'".contains(c)).unwrap_or(tail.len());
            let url = &tail[..end];
            let Some(link) = FolioLink::parse(url) else { continue };
            found.push(Reference {
                line: index + 1,
                context: heading.clone().unwrap_or_else(|| snippet(line)),
                label: link_words(&line[..at]),
                url: url.to_string(),
                link,
            });
        }
    }
    found
}

/// The words of the markdown link whose target starts right after `before`: `[these](`.
fn link_words(before: &str) -> String {
    let Some(head) = before.strip_suffix("](") else { return String::new() };
    head.rfind('[').map(|open| head[open + 1..].trim().to_string()).unwrap_or_default()
}

/// A line without its list marker, short.
fn snippet(line: &str) -> String {
    let mut text = line.trim();
    for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] {
        if let Some(rest) = text.strip_prefix(marker) {
            text = rest.trim();
            break;
        }
    }
    if text.chars().count() > 80 {
        format!("{}…", text.chars().take(80).collect::<String>())
    } else {
        text.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MR: &str = "https://github.com/team/svc/pull/42#issuecomment-981";

    #[test]
    fn an_item_has_its_tag_text_address_and_line() {
        let doc = format!("# Notes\n\n- [ ] Key rotation: asked in review #waiting {MR}\n");
        let items = open_items(&doc);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].line, 3);
        assert_eq!(items[0].tag, "waiting");
        assert_eq!(items[0].text, "Key rotation: asked in review");
        assert_eq!(items[0].url.as_deref(), Some(MR));
        assert_eq!(items[0].folio, None);
    }

    #[test]
    fn the_three_tags_and_no_others() {
        let doc = "- [ ] a #investigate\n- [ ] b #waiting\n- [ ] c #replied\n- [ ] d #todo\n- [ ] e no tag\n";
        let tags: Vec<_> = open_items(doc).into_iter().map(|i| i.tag).collect();
        assert_eq!(tags, ["investigate", "waiting", "replied"]);
    }

    #[test]
    fn tags_ignore_case_and_may_come_first() {
        let items = open_items("- [ ] #Waiting asked Anna\n- [ ] ask #INVESTIGATE, later\n");
        assert_eq!(items.iter().map(|i| i.tag.as_str()).collect::<Vec<_>>(), ["waiting", "investigate"]);
        assert_eq!(items[0].text, "asked Anna");
        assert_eq!(items[1].text, "ask , later".replace(" ,", ","));
    }

    #[test]
    fn a_hash_inside_an_address_or_word_is_not_a_tag() {
        assert!(open_items(&format!("- [ ] see {MR}#waiting\n")).is_empty());
        assert!(open_items("- [ ] issue#waiting\n").is_empty());
        assert!(open_items("- [ ] a #waiting-room\n").is_empty());
    }

    #[test]
    fn ticked_and_plain_items_are_not_open() {
        let doc = "- [x] done #waiting\n- [X] done too #waiting\n- plain #waiting\n[ ] no marker #waiting\n- [ ]no space #waiting\n";
        assert!(open_items(doc).is_empty());
    }

    #[test]
    fn other_list_markers_and_indents_work() {
        let items = open_items("* [ ] star #waiting\n+ [ ] plus #waiting\n    - [ ] deep #investigate\n");
        assert_eq!(items.iter().map(|i| i.text.as_str()).collect::<Vec<_>>(), ["star", "plus", "deep"]);
    }

    #[test]
    fn a_folio_link_is_the_annotation_it_is_about() {
        let link = "folio://annotation/c3d4?repo=svc&branch=main&path=docs/t.md&file=/x/docs/t.md";
        let items = open_items(&format!("- [ ] Key rotation #waiting {MR} [Priya]({link})\n"));
        assert_eq!(items[0].folio.as_deref(), Some(link));
        assert_eq!(items[0].url.as_deref(), Some(MR));
        assert_eq!(items[0].text, "Key rotation");
    }

    #[test]
    fn a_link_to_the_document_is_what_the_item_is_about_too() {
        let link = "folio://document?repo=svc&branch=main&path=docs/t.md&file=/x/docs/t.md";
        let items = open_items(&format!("- [ ] Check the whole spec #investigate [spec.md]({link})\n"));
        assert_eq!(items[0].folio.as_deref(), Some(link));
        assert_eq!(items[0].text, "Check the whole spec");
    }

    #[test]
    fn a_markdown_link_to_an_address_is_left_out_of_the_text() {
        let items = open_items(&format!("- [ ] Asked in [the MR]({MR}) about rotation #waiting\n"));
        assert_eq!(items[0].url.as_deref(), Some(MR));
        assert_eq!(items[0].text, "Asked in about rotation");
        // A link that is not to an address stays in the words.
        assert_eq!(open_items("- [ ] see [notes](notes.md) #waiting\n")[0].text, "see [notes](notes.md)");
    }

    #[test]
    fn the_first_nested_line_is_the_note() {
        let doc = "- [ ] Rotation #replied\n  - Sam: the family is revoked by the gateway\n  - second\n- [ ] Next #waiting\n";
        let items = open_items(doc);
        assert_eq!(items[0].note.as_deref(), Some("Sam: the family is revoked by the gateway"));
        assert_eq!(items[1].note, None);
    }

    #[test]
    fn a_line_at_the_same_indent_is_not_nested() {
        let items = open_items("- [ ] a #waiting\n- [ ] b #waiting\n\n  later paragraph\n");
        assert_eq!(items[0].note, None);
        assert_eq!(items[1].note.as_deref(), Some("later paragraph"));
    }

    #[test]
    fn code_blocks_have_no_items() {
        assert!(open_items("```\n- [ ] in code #waiting\n```\n").is_empty());
        assert_eq!(open_items("```\nx\n```\n- [ ] after #waiting\n").len(), 1);
    }

    #[test]
    fn windows_line_endings_work() {
        let items = open_items("- [ ] a #waiting\r\n  - note\r\n- [ ] b #replied\r\n");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].text, "a");
        assert_eq!(items[0].note.as_deref(), Some("note"));
    }

    #[test]
    fn ticking_an_item_changes_only_its_box() {
        let doc = "# Notes\n\n- [ ] a #waiting\n- [ ] b #waiting\n";
        assert_eq!(tick(doc, 3).unwrap(), "# Notes\n\n- [x] a #waiting\n- [ ] b #waiting\n");
        assert_eq!(tick("  * [ ] deep #waiting", 1).unwrap(), "  * [x] deep #waiting");
        assert_eq!(tick("- [ ] crlf #waiting\r\n- [ ] b\r\n", 1).unwrap(), "- [x] crlf #waiting\r\n- [ ] b\r\n");
    }

    #[test]
    fn ticking_what_is_not_an_open_item_changes_nothing() {
        assert_eq!(tick("- [x] done\n", 1), None);
        assert_eq!(tick("plain\n", 1), None);
        assert_eq!(tick("- [ ] a\n", 2), None);
    }

    #[test]
    fn a_link_parses_to_its_target_and_place() {
        let link = FolioLink::parse("folio://passage?repo=svc&branch=fix/logout&path=docs/t.md&file=/x/a%20b.md&q=rotate%20on&before=We%20").unwrap();
        assert_eq!(link.target, LinkTarget::Passage { text: "rotate on".into(), before: "We ".into() });
        assert_eq!((link.repo.as_deref(), link.branch.as_deref(), link.path.as_deref()), (Some("svc"), Some("fix/logout"), Some("docs/t.md")));
        assert_eq!(link.file.as_deref(), Some("/x/a b.md"));
        assert_eq!(FolioLink::parse("folio://annotation/c3d4?file=/x").unwrap().target, LinkTarget::Annotation { id: "c3d4".into() });
        assert_eq!(FolioLink::parse("folio://document?path=a.md").unwrap().target, LinkTarget::Document);
        assert_eq!(FolioLink::parse("folio://wiki?name=x"), None);
        assert_eq!(FolioLink::parse("folio://passage?repo=svc"), None);
        assert_eq!(FolioLink::parse("https://example.com"), None);
    }

    #[test]
    fn a_link_points_to_a_file_by_repo_branch_and_path() {
        let here = Here { repo: Some("svc".into()), branch: Some("main".into()), path: "docs/t.md".into(), file: "/w/svc/docs/t.md".into() };
        let link = |q: &str| FolioLink::parse(&format!("folio://document?{q}")).unwrap();
        assert!(link("repo=svc&branch=main&path=docs/t.md").points_to(&here));
        assert!(link("repo=svc&path=docs/t.md").points_to(&here));
        assert!(!link("repo=svc&branch=fix&path=docs/t.md").points_to(&here));
        assert!(!link("repo=svc&branch=main&path=docs/u.md").points_to(&here));
        assert!(!link("repo=other&branch=main&path=docs/t.md").points_to(&here));
        // The place wins over `file`; an older link has only `file`.
        assert!(!link("repo=svc&branch=fix&path=docs/t.md&file=/w/svc/docs/t.md").points_to(&here));
        assert!(link("file=/w/svc/docs/t.md").points_to(&here));
        assert!(!link("file=/w/svc/docs/u.md").points_to(&here));
    }

    #[test]
    fn references_have_their_line_heading_and_words() {
        let doc = "Intro [spec](folio://document?path=t.md) here\n\n## Rotation ##\n\n- [Priya: “Does”](folio://annotation/c3d4?path=t.md) and folio://passage?path=t.md&q=x.\n```\nfolio://document?path=t.md\n```\n[[page]] [web](https://x)\n";
        let refs = references(doc);
        assert_eq!(refs.len(), 3);
        assert_eq!((refs[0].line, refs[0].context.as_str(), refs[0].label.as_str()), (1, "Intro [spec](folio://document?path=t.md) here", "spec"));
        assert_eq!((refs[1].line, refs[1].context.as_str(), refs[1].label.as_str()), (5, "Rotation", "Priya: “Does”"));
        assert_eq!(refs[1].url, "folio://annotation/c3d4?path=t.md");
        assert_eq!(refs[2].label, "");
        assert_eq!(refs[2].link.target, LinkTarget::Passage { text: "x.".into(), before: String::new() });
    }

    fn here(branch: &str, path: &str) -> Here {
        Here { repo: Some("svc".into()), branch: Some(branch.into()), path: path.into(), file: format!("/nowhere/{branch}/{path}").into() }
    }

    #[test]
    fn a_link_resolves_to_an_open_file_or_says_why_not() {
        let open = [here("main", "docs/t.md"), here("fix", "docs/u.md")];
        let link = |q: &str| FolioLink::parse(&format!("folio://document?{q}")).unwrap();
        assert_eq!(resolve(&link("repo=svc&branch=main&path=docs/t.md"), &open), Resolution::Found(0));
        assert_eq!(resolve(&link("repo=svc&path=docs/u.md"), &open), Resolution::Found(1));
        assert_eq!(resolve(&link("repo=svc&branch=gone&path=docs/t.md"), &open), Resolution::BranchGone("gone".into()));
        assert_eq!(resolve(&link("repo=svc&branch=main&path=docs/x.md"), &open), Resolution::Missing("docs/x.md".into()));
        assert_eq!(resolve(&link("repo=other&branch=main&path=docs/t.md"), &open), Resolution::Unknown);
        assert_eq!(resolve(&link("file=/x/y.md"), &open), Resolution::Unknown);
        let reasons = |q: &str| dead_reason(&link(q), &open);
        assert_eq!(reasons("repo=svc&branch=gone&path=docs/t.md").as_deref(), Some("gone isn't checked out any more"));
        assert_eq!(reasons("repo=svc&branch=main&path=docs/x.md").as_deref(), Some("docs/x.md isn't in this checkout"));
        assert_eq!(reasons("repo=other&path=a.md&file=/no/such.md").as_deref(), Some("other isn't in the set"));
        assert_eq!(reasons("file=/no/such.md").as_deref(), Some("such.md isn't there any more"));
    }

    #[test]
    fn a_link_with_a_gone_branch_moves_to_the_only_checkout_that_has_the_file() {
        let link = FolioLink::parse("folio://document?repo=svc&branch=gone&path=docs/t.md").unwrap();
        assert_eq!(moved_to(&link, &[here("main", "docs/t.md"), here("fix", "docs/u.md")]), Some(0));
        // Two branches have it: the reader's call. Nothing is gone: nothing moves.
        assert_eq!(moved_to(&link, &[here("main", "docs/t.md"), here("fix", "docs/t.md")]), None);
        assert_eq!(moved_to(&link, &[here("fix", "docs/u.md")]), None);
        let live = FolioLink::parse("folio://document?repo=svc&branch=main&path=docs/t.md").unwrap();
        assert_eq!(moved_to(&live, &[here("main", "docs/t.md")]), None);
    }

    #[test]
    fn a_target_is_found_while_the_file_still_has_it() {
        let dir = std::env::temp_dir().join(format!("folio-target-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dunce::canonicalize(&dir).unwrap().join("a.md");
        std::fs::write(&file, "We rotate on every use. Then we rotate again.\n").unwrap();
        crate::commands::annotate::run(&file, "highlight", "We ", Some("rotate on every use"), None, None, "me", "local").unwrap();
        let sidecar = crate::location::folio_path(&file);
        let id = crate::sidecar::Sidecar::load(&sidecar).unwrap().annotations[0].id.clone();
        let passage = |text: &str, before: &str| LinkTarget::Passage { text: text.into(), before: before.into() };
        assert!(target_found(&LinkTarget::Document, &file));
        assert!(target_found(&passage("rotate again", ""), &file));
        assert!(target_found(&LinkTarget::Annotation { id: id.clone() }, &file));
        assert!(!target_found(&LinkTarget::Annotation { id: "ann_nope".into() }, &file));
        assert!(!target_found(&LinkTarget::Document, &dir.join("missing.md")));
        // Edited away: the passage and the annotation's text are gone.
        std::fs::write(&file, "Tokens are replaced on every refresh.\n").unwrap();
        assert!(!target_found(&passage("rotate again", ""), &file));
        assert!(!target_found(&LinkTarget::Annotation { id }, &file));
        std::fs::remove_dir_all(dir).ok();
    }
}
