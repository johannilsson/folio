import AppKit

/// What the two text surfaces, the markdown source and the preview, do the same way on their
/// `NSTextView`: anchor annotations in the markdown, draw them as marks, say where a character is, build
/// the selection the annotation UI needs, find and flash. What differs (how the text is edited, how a
/// position in the text is a position in the file) stays in the surfaces.
@MainActor
enum TextSurface {
    private static let purple = NSColor.systemPurple
    private static let red = NSColor.systemRed

    /// Where each annotation is in the markdown `text`, as UTF-16 ranges, found with the same matcher the CLI uses.
    static func anchor(_ pending: [Annotation], in text: String) -> [String: NSRange] {
        let items: [[String: Any]] = pending.map { annotation in
            var item: [String: Any] = ["id": annotation.id, "context_before": annotation.contextBefore]
            if let target = annotation.target { item["target"] = target }
            return item
        }
        var found: [String: NSRange] = [:]
        if !items.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: items),
           let answer = try? Rust.anchor(doc: text, itemsJSON: String(decoding: data, as: UTF8.self), raw: true),
           let list = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String, let from = (entry["char_from"] as? NSNumber)?.intValue,
                      let to = (entry["char_to"] as? NSNumber)?.intValue else { continue }
                found[id] = NSRange(location: from, length: max(0, to - from))
            }
        }
        return found
    }

    /// Draws each annotation over its text without touching the text: temporary attributes. `ranges` are
    /// where the annotations are in the text on screen, `pendingRange` the text being commented on.
    /// Returns where suggestions would insert text (zero-width annotations), which the source marks.
    @discardableResult
    static func applyMarks(in textView: NSTextView, pending: [Annotation], ranges: [String: NSRange], pendingRange: NSRange?) -> [Int] {
        guard let layoutManager = textView.layoutManager else { return [] }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        for key in [NSAttributedString.Key.backgroundColor, .strikethroughStyle, .strikethroughColor, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
        }
        // A mark is drawn line by line and never over a line break: the background of a break runs to
        // the edge of the line, outside the text column.
        let text = textView.string as NSString
        func mark(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            let range = NSIntersectionRange(range, whole)
            var start = range.location
            for index in range.location...max(range.location, range.upperBound) {
                let atBreak = index < range.upperBound && "\n\r\u{2028}\u{2029}".contains(Character(UnicodeScalar(text.character(at: index)) ?? " "))
                guard atBreak || index == range.upperBound else { continue }
                if index > start { layoutManager.addTemporaryAttributes(attributes, forCharacterRange: NSRange(location: start, length: index - start)) }
                start = index + 1
            }
        }
        var inserts: [Int] = []
        for annotation in pending {
            guard let range = ranges[annotation.id] else { continue }
            switch annotation.kind {
            case .comment, .highlight:
                mark([.backgroundColor: purple.withAlphaComponent(0.22)], range)
            case .replace, .delete:
                var attributes: [NSAttributedString.Key: Any] = [
                    .backgroundColor: red.withAlphaComponent(0.12),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: red,
                ]
                if annotation.kind == .delete {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = red
                }
                mark(attributes, range)
            case .insert:
                inserts.append(range.location)
            default: break
            }
        }
        if let pendingRange {
            mark([.backgroundColor: purple.withAlphaComponent(0.4)], pendingRange)
        }
        return inserts
    }

    /// Where the character at `index` is, in the coordinates of the view the text view is in: the top
    /// and bottom of its line, and how far along that line it is.
    static func position(of index: Int, in textView: NSTextView) -> (top: Double, bottom: Double, left: Double)? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        var x = layoutManager.location(forGlyphAt: glyph).x + line.minX + origin.x
        if index >= length { x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX + origin.x }
        return (Double(textView.frame.minY + line.minY + origin.y), Double(textView.frame.minY + line.maxY + origin.y), Double(textView.frame.minX + x))
    }

    /// The selection of `displayRange` (what is selected in the text view) as the annotation UI needs it.
    /// `fileRange` is the same text in the markdown `document`, whose rendered words anchor a comment
    /// (what agents and the preview anchor by, without markdown syntax); only a selection of markup or
    /// code has none, and then the raw text is used.
    static func selection(in textView: NSTextView, displayRange range: NSRange, fileRange: NSRange, document: String) -> SelectionInfo? {
        guard range.length > 0, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let first = position(of: range.location, in: textView) else { return nil }
        let text = document as NSString
        let last = position(of: max(range.location, range.upperBound - 1), in: textView) ?? first
        let box = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let origin = textView.textContainerOrigin
        var target = text.substring(with: fileRange)
        var contextBefore: String
        if let rendered = try? Rust.renderedSelection(doc: document, range: fileRange) {
            (target, contextBefore) = rendered
        } else {
            // 30 UTF-16 units back, moved on to the start of a character so a pair is not cut in half.
            let start = text.rangeOfComposedCharacterSequence(at: max(0, fileRange.location - 30)).location
            let from = start < fileRange.location - 30 ? text.rangeOfComposedCharacterSequence(at: start).upperBound : start
            contextBefore = text.substring(with: NSRange(location: min(from, fileRange.location), length: fileRange.location - min(from, fileRange.location)))
        }
        return SelectionInfo(
            from: fileRange.location, to: fileRange.upperBound, top: first.top, bottom: first.bottom, endBottom: last.bottom,
            left: Double(textView.frame.minX + box.minX + origin.x), right: Double(textView.frame.minX + box.maxX + origin.x),
            target: target, contextBefore: contextBefore
        )
    }

    /// The annotation whose text the character at `index` is in (or just after), if any.
    static func annotation(at index: Int, in pending: [Annotation], ranges: [String: NSRange]) -> String? {
        pending.first { annotation in
            guard let range = ranges[annotation.id] else { return false }
            return index >= range.location && index <= range.upperBound
        }?.id
    }

    /// Selects the next (or previous) match of `text`, wrapping round, and shows it. A match for which
    /// `skip` is true (text that is on screen but not in the file) is passed over. Returns whether there is one.
    @discardableResult
    static func find(_ text: String, backwards: Bool, in textView: NSTextView, skip: (NSRange) -> Bool = { _ in false }) -> Bool {
        guard !text.isEmpty else { return false }
        let all = textView.string as NSString
        let selection = textView.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        func match(in range: NSRange) -> NSRange {
            var rest = range
            while rest.length > 0 {
                let found = all.range(of: text, options: options, range: rest)
                guard found.location != NSNotFound else { break }
                if !skip(found) { return found }
                rest = backwards ? NSRange(location: range.location, length: found.location - range.location)
                                 : NSRange(location: found.upperBound, length: range.upperBound - found.upperBound)
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        let ahead = backwards ? NSRange(location: 0, length: selection.location) : NSRange(location: selection.upperBound, length: all.length - selection.upperBound)
        var found = match(in: ahead)
        if found.location == NSNotFound { found = match(in: NSRange(location: 0, length: all.length)) }
        guard found.location != NSNotFound else { return false }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }

    /// Briefly highlights `text`, the first time it is in the text view, then calls `restore` to draw the marks again.
    static func flash(_ text: String, in textView: NSTextView, then restore: @escaping () -> Void) {
        guard let layoutManager = textView.layoutManager else { return }
        let found = (textView.string as NSString).range(of: text)
        guard found.location != NSNotFound else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), forCharacterRange: found)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { restore() }
    }
}
