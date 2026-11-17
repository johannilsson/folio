import Foundation

/// A wiki page's link to an annotation or a passage, as the card of that annotation lists it.
public struct Backlink: Equatable {
    /// The wiki page the link is in: the id of its file in the window, and its path in the wiki folder.
    public let pageID: String
    public let page: String
    /// The heading the link is under, else the line it is in.
    public let context: String
    /// The words of the link ("Priya"), empty for a bare URL. They find the place in the page.
    public let label: String
    public let line: Int

    public init(pageID: String, page: String, context: String, label: String, line: Int) {
        self.pageID = pageID
        self.page = page
        self.context = context
        self.label = label
        self.line = line
    }
}

/// The `folio://annotation`, `folio://passage` and `folio://document` links in a wiki page.
public enum WikiReferences {
    public struct Reference: Equatable {
        public let link: FolioLink
        /// 1-based.
        public let line: Int
        public let context: String
        public let label: String
    }

    /// Found by the engine (`wiki::references`), so the app counts the same links as `folio refs`.
    public static func find(in markdown: String) -> [Reference] {
        (try? Rust.references(in: markdown)) ?? []
    }
}
