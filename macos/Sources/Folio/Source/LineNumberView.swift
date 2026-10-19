import AppKit

/// The numbers beside the source: one per line of the file (a wrapped line has its number once).
/// Only the part that is on screen is drawn.
final class LineNumberView: NSView {
    weak var textView: SourceTextView?
    /// Where each line of the text starts (UTF-16 offsets), sorted.
    var lineStarts: [Int] = [0] {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The number of the line that holds character `index`, counted from 1.
    private func number(at index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let length = (textView.string as NSString).length

        func draw(_ number: Int, baseline: CGFloat) {
            let text = NSAttributedString(string: String(number), attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.width - 8 - size.width, y: baseline - Self.font.ascender))
        }

        let inContainer = NSRect(x: 0, y: dirtyRect.minY - origin.y, width: container.size.width, height: dirtyRect.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: inContainer, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let startsLine = characters.location == 0
                || (textView.string as NSString).character(at: characters.location - 1) == 0x0A
            guard startsLine else { return }
            let baseline = lineRect.minY + origin.y + layoutManager.location(forGlyphAt: glyphRange.location).y
            draw(self.number(at: characters.location), baseline: baseline)
        }
        // After a final newline there is one more, empty, line.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, extra.maxY + origin.y > dirtyRect.minY, extra.minY + origin.y < dirtyRect.maxY, length > 0 {
            draw(lineStarts.count, baseline: extra.minY + origin.y + (extra.height + Self.font.ascender) / 2)
        }
    }
}
