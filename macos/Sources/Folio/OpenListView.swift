import AppKit
import FolioKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One open item: its words, what answered it, where it is, the address it waits on, the annotation it is about.
/// `compact` is the row of the Open pane: the box, the words, then where it is and the address on one line,
/// and a dot when it is about an annotation of the file on screen (`marked`).
private final class OpenItemRowView: NSView {
    let entry: OpenEntry
    let compact: Bool
    let marked: Bool
    var onTick: () -> Void = {}
    var onOpen: () -> Void = {}
    var onLink: (URL) -> Void = { _ in }

    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let text: PassthroughLabel
    private let note: PassthroughLabel?
    private let place: PassthroughLabel
    private let address: PassthroughLabel?
    private let chip: PassthroughLabel?

    private var pad: CGFloat { compact ? 8 : 12 }
    private var mainX: CGFloat { compact ? 8 + 16 + 6 : 12 + 18 + 10 }
    /// Room at the right of a compact row for its dot.
    private var dotRoom: CGFloat { compact ? 14 : 0 }

    /// What the row says, for the self-test.
    var plainText: String { [text.stringValue, note?.stringValue].compactMap { $0 }.joined(separator: "\n") }
    var placeText: String { place.stringValue }
    var addressText: String? { address?.stringValue }
    var chipText: String? { chip?.stringValue }

    init(entry: OpenEntry, compact: Bool = false, marked: Bool = false) {
        self.entry = entry
        self.compact = compact
        self.marked = marked
        let item = entry.item
        text = PassthroughLabel(NSAttributedString(string: item.text, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 12 : 13), .foregroundColor: NSColor.labelColor,
        ]))
        if compact {
            // Where it is and the address it waits on, as one line under the words.
            let meta = ["\(entry.page):\(item.line)"] + (item.url.map { [OpenList.shortAddress($0)] } ?? [])
            place = PassthroughLabel(NSAttributedString(string: meta.joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            note = nil
            address = nil
            chip = nil
            super.init(frame: .zero)
            box.controlSize = .small
            setUp()
            return
        }
        note = item.note.map {
            PassthroughLabel(NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        place = PassthroughLabel(NSAttributedString(string: "\(entry.page):\(item.line)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor,
        ]))
        address = item.url.map {
            PassthroughLabel(NSAttributedString(string: OpenList.shortAddress($0), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor,
            ]))
        }
        chip = item.folio.flatMap { URL(string: $0) }.flatMap(FolioLink.init).map { link in
            let word: String
            switch link.target {
            case .annotation: word = "annotation"
            case .passage: word = "passage"
            }
            return PassthroughLabel(NSAttributedString(string: word, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.systemPurple,
            ]))
        }
        super.init(frame: .zero)
        setUp()
    }

    private func setUp() {
        box.target = self
        box.action = #selector(ticked)
        addSubview(box)
        for label in [text, note, place, address, chip].compactMap({ $0 }) {
            let wraps = label === text || label === note || (compact && label === place)
            label.maximumNumberOfLines = wraps ? 0 : 1
            label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel(entry.item.text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func ticked() {
        box.state = .on
        onTick()
    }

    func tick() { ticked() }

    func layoutContent(width: CGFloat) -> CGFloat {
        if compact { return layoutCompact(width: width) }
        let pad = self.pad
        let mainX = self.mainX
        let mainW = width - mainX - pad
        box.frame = NSRect(x: pad, y: pad - 1, width: 18, height: 18)
        var y = pad
        let textH = AnnotationStyle.height(of: text.attributedStringValue, width: mainW)
        text.frame = NSRect(x: mainX, y: y, width: mainW, height: textH)
        y += textH + 2
        if let note {
            let h = AnnotationStyle.height(of: note.attributedStringValue, width: mainW)
            note.frame = NSRect(x: mainX, y: y + 2, width: mainW, height: h)
            y += h + 4
        }
        // Where it is, the address it waits on, the annotation it is about: one line, cut short at the end.
        var x = mainX
        let metaY = y + 3
        var parts: [PassthroughLabel] = [place]
        if let address { parts.append(address) }
        if let chip { parts.append(chip) }
        for label in parts {
            label.sizeToFit()
            let room = max(40, width - pad - x)
            label.frame = NSRect(x: x, y: metaY, width: min(label.frame.width, room), height: label.frame.height)
            x = label.frame.maxX + 12
        }
        let height = metaY + 14 + pad
        frame.size = NSSize(width: width, height: height)
        needsDisplay = true
        return height
    }

    /// The words, and under them where the item is, both wrapping in the room left by the box and the dot.
    private func layoutCompact(width: CGFloat) -> CGFloat {
        let mainW = max(40, width - mainX - pad - dotRoom)
        box.frame = NSRect(x: pad, y: pad - 1, width: 16, height: 16)
        // Measured by the labels' cells, which wrap a little earlier than the bare text would (their padding).
        func height(_ label: PassthroughLabel) -> CGFloat {
            ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: mainW, height: .greatestFiniteMagnitude)).height
                ?? AnnotationStyle.height(of: label.attributedStringValue, width: mainW))
        }
        let textH = height(text)
        text.frame = NSRect(x: mainX, y: pad - 1, width: mainW, height: textH)
        let placeH = height(place)
        place.frame = NSRect(x: mainX, y: text.frame.maxY + 2, width: mainW, height: placeH)
        let height = place.frame.maxY + pad - 1
        frame.size = NSSize(width: width, height: height)
        needsDisplay = true
        return height
    }

    /// Where the dot of a compact row is drawn.
    var dotFrame: NSRect? {
        guard compact, marked else { return nil }
        return NSRect(x: bounds.width - pad - 6, y: pad + 4, width: 6, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = compact ? 8 : 10
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        // An answer to read is lightly green.
        (entry.item.tag == "replied" ? NSColor.systemGreen.withAlphaComponent(0.1) : AnnotationStyle.cardFill).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        // About an annotation of the file on screen: Folio's purple, as the annotations are.
        if let dotFrame {
            NSColor.systemPurple.setFill()
            NSBezierPath(ovalIn: dotFrame).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A compact row opens where the item is, wherever it is clicked (the box is a button of its own).
        if compact { onOpen(); return }
        let point = convert(event.locationInWindow, from: nil)
        if let address, address.frame.contains(point), let url = entry.item.url.flatMap({ URL(string: $0) }) {
            onLink(url)
        } else if let chip, chip.frame.contains(point), let url = entry.item.folio.flatMap({ URL(string: $0) }) {
            onLink(url)
        } else if place.frame.contains(point) {
            onOpen()
        }
    }

    override var allowsVibrancy: Bool { false }
}

/// The Open list of a set window: the open items (`- [ ] … #waiting`) of every file of the set, by tag or by
/// file. The files are the record: ticking an item writes `[x]` in its file, and the list follows the files.
final class OpenListView: NSView {
    enum Grouping { case tag, file }

    var entries: [OpenEntry] = [] {
        didSet { if entries != oldValue { rebuild() } }
    }
    var grouping: Grouping = .tag {
        didSet {
            guard grouping != oldValue else { return }
            picker.selectedSegment = grouping == .tag ? 0 : 1
            rebuild()
        }
    }
    /// An item was ticked.
    var onTick: (OpenEntry) -> Void = { _ in }
    /// Open the file at the item's line.
    var onOpen: (OpenEntry) -> Void = { _ in }
    /// An address or a Folio link on a row was clicked.
    var onLink: (URL) -> Void = { _ in }

    private let heading = PassthroughLabel(NSAttributedString(string: "Open", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
    ]))
    private let caption = PassthroughLabel(NSAttributedString(string: "from every file in the set", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    private let picker = NSSegmentedControl(labels: ["By tag", "By file"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let canvas = FlippedView()
    private let empty = PassthroughLabel(NSAttributedString(string: "No open items", attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    private var headings: [PassthroughLabel] = []
    private var rows: [OpenItemRowView] = []
    private var groupSizes: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(groupingChanged)
        picker.setAccessibilityLabel("Group by")
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for view in [scroll, picker, heading, caption, empty] { addSubview(view) }
        empty.isHidden = true
        setAccessibilityIdentifier("open-list")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func groupingChanged() {
        grouping = picker.selectedSegment == 1 ? .file : .tag
    }

    // MARK: what the self-test looks at

    var groupTitles: [String] { headings.map(\.stringValue) }
    var rowTexts: [String] { rows.map(\.plainText) }
    var rowPlaces: [String] { rows.map(\.placeText) }
    var rowAddresses: [String?] { rows.map(\.addressText) }
    var rowChips: [String?] { rows.map(\.chipText) }
    var emptyShown: Bool { !empty.isHidden }
    func tick(row index: Int) { if rows.indices.contains(index) { rows[index].tick() } }
    func open(row index: Int) { if rows.indices.contains(index) { rows[index].onOpen() } }

    // MARK: content

    private func rebuild() {
        headings.forEach { $0.removeFromSuperview() }
        rows.forEach { $0.removeFromSuperview() }
        headings = []
        rows = []
        groupSizes = []
        empty.isHidden = !entries.isEmpty
        for group in grouping == .tag ? OpenList.byTag(entries) : OpenList.byFile(entries) {
            let title = PassthroughLabel(NSAttributedString(string: group.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            title.maximumNumberOfLines = 1
            canvas.addSubview(title)
            headings.append(title)
            groupSizes.append(group.entries.count)
            for entry in group.entries {
                let row = OpenItemRowView(entry: entry)
                row.onTick = { [weak self] in self?.onTick(entry) }
                row.onOpen = { [weak self] in self?.onOpen(entry) }
                row.onLink = { [weak self] url in self?.onLink(url) }
                canvas.addSubview(row)
                rows.append(row)
            }
        }
        needsLayout = true
    }

    // MARK: layout

    override func layout() {
        super.layout()
        // The toolbar floats over the content side, as it does over the text.
        let inset: CGFloat = 40
        let top = max(safeAreaInsets.top, 52) + 8
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: inset, y: top)
        caption.sizeToFit()
        caption.frame.origin = NSPoint(x: heading.frame.maxX + 10, y: top + 2)
        picker.sizeToFit()
        picker.frame.origin = NSPoint(x: max(caption.frame.maxX + 20, bounds.width - inset - picker.frame.width), y: top - 3)
        let below = top + 36
        scroll.frame = NSRect(x: 0, y: below, width: bounds.width, height: max(0, bounds.height - below))
        let width = scroll.contentSize.width
        let column = min(760, width - 2 * inset)
        var y: CGFloat = 8
        var next = 0
        for (index, title) in headings.enumerated() {
            title.sizeToFit()
            title.frame = NSRect(x: inset, y: y, width: max(column, 100), height: 18)
            y += 26
            for row in rows[next..<(next + groupSizes[index])] {
                let height = row.layoutContent(width: max(column, 200))
                row.frame = NSRect(x: inset, y: y, width: max(column, 200), height: height)
                y += height + 6
            }
            next += groupSizes[index]
            y += 14
        }
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 24, scroll.contentSize.height))
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: inset, y: below + 16)
    }

    override var allowsVibrancy: Bool { false }
}

/// The Open pane: the inspector of a set window, beside the editor and its comments pane, listing by tag the open
/// items of the whole set or only those about the file on screen. The window controller owns what it lists and
/// its scope (`SetWindowController.openPaneOn`, `openScope`); the pane draws what it is given.
final class OpenPaneView: NSView {
    /// Its width, fixed.
    static let width: CGFloat = 272

    var rows: [OpenList.PaneRow] = [] {
        didSet { if rows != oldValue { rebuild() } }
    }
    var scope: OpenList.Scope = .set {
        didSet {
            picker.selectedSegment = scope == .file ? 0 : 1
            if scope != oldValue { rebuild() }
        }
    }
    /// The reader chose "This file" or "Whole set".
    var onScope: (OpenList.Scope) -> Void = { _ in }
    /// An item was ticked.
    var onTick: (OpenEntry) -> Void = { _ in }
    /// Open the file at the item.
    var onOpen: (OpenEntry) -> Void = { _ in }

    private let heading = PassthroughLabel(NSAttributedString(string: "Open", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
    ]))
    private let picker = NSSegmentedControl(labels: ["This file", "Whole set"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let canvas = FlippedView()
    private let empty = PassthroughLabel(NSAttributedString(string: "", attributes: [:]))
    private var headings: [PassthroughLabel] = []
    private var rowViews: [OpenItemRowView] = []
    private var groupSizes: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        picker.selectedSegment = 1
        picker.target = self
        picker.action = #selector(scopeChanged)
        picker.setAccessibilityLabel("Show the open items of")
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        for view in [scroll, heading, picker, empty] { addSubview(view) }
        setAccessibilityIdentifier("open-pane")
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func scopeChanged() {
        onScope(picker.selectedSegment == 0 ? .file : .set)
    }

    // MARK: what the self-test looks at

    var groupTitles: [String] { headings.map(\.stringValue) }
    var rowTexts: [String] { rowViews.map(\.plainText) }
    var rowPlaces: [String] { rowViews.map(\.placeText) }
    var rowMarked: [Bool] { rowViews.map(\.marked) }
    var emptyText: String? { empty.isHidden ? nil : empty.stringValue }
    func tick(row index: Int) { if rowViews.indices.contains(index) { rowViews[index].tick() } }
    func open(row index: Int) { if rowViews.indices.contains(index) { rowViews[index].onOpen() } }
    /// What a click on "This file" or "Whole set" does.
    func choose(_ scope: OpenList.Scope) {
        picker.selectedSegment = scope == .file ? 0 : 1
        scopeChanged()
    }

    // MARK: content

    private static func color(of tag: String) -> NSColor {
        switch tag {
        case "replied": return .systemGreen
        case "waiting": return .systemOrange
        default: return .systemGray
        }
    }

    private func rebuild() {
        headings.forEach { $0.removeFromSuperview() }
        rowViews.forEach { $0.removeFromSuperview() }
        headings = []
        rowViews = []
        groupSizes = []
        empty.attributedStringValue = NSAttributedString(
            string: scope == .file ? "Nothing open about this file" : "No open items",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        empty.isHidden = !rows.isEmpty
        let entries = rows.map(\.entry)
        for group in OpenList.byTag(entries) {
            // One font on the line: a dot in the tag's colour, then its name.
            let tag = group.entries.first?.item.tag ?? ""
            let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let title = NSMutableAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: Self.color(of: tag)])
            title.append(NSAttributedString(string: group.title.uppercased(), attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.3,
            ]))
            let label = PassthroughLabel(title)
            label.maximumNumberOfLines = 1
            canvas.addSubview(label)
            headings.append(label)
            groupSizes.append(group.entries.count)
            for entry in group.entries {
                let marked = rows.first { $0.entry == entry }?.aboutAnnotation ?? false
                let row = OpenItemRowView(entry: entry, compact: true, marked: marked)
                row.onTick = { [weak self] in self?.onTick(entry) }
                row.onOpen = { [weak self] in self?.onOpen(entry) }
                canvas.addSubview(row)
                rowViews.append(row)
            }
        }
        needsLayout = true
    }

    // MARK: layout

    override func layout() {
        super.layout()
        // The toolbar floats over the content side: the pane starts below it.
        let inset: CGFloat = 12
        let top = max(safeAreaInsets.top, 52) + 10
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: inset, y: top)
        picker.sizeToFit()
        picker.frame.origin = NSPoint(x: bounds.width - inset - picker.frame.width, y: top - 2)
        let below = top + 28
        scroll.frame = NSRect(x: 0, y: below, width: bounds.width, height: max(0, bounds.height - below))
        let width = max(100, scroll.contentSize.width - 2 * inset)
        var y: CGFloat = 4
        var next = 0
        for (index, title) in headings.enumerated() {
            title.sizeToFit()
            title.frame = NSRect(x: inset, y: y, width: width, height: title.frame.height)
            y += title.frame.height + 5
            for row in rowViews[next..<(next + groupSizes[index])] {
                let height = row.layoutContent(width: width)
                row.frame = NSRect(x: inset, y: y, width: width, height: height)
                y += height + 5
            }
            next += groupSizes[index]
            y += 8
        }
        canvas.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(y + 16, scroll.contentSize.height))
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: inset, y: below + 6)
    }

    // The split view draws the divider beside it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override var allowsVibrancy: Bool { false }
}
