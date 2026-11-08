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
    /// The annotation or passage it is about: the first `folio://` link.
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
            folio: address(rest, &["folio://annotation", "folio://passage"]),
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
}
