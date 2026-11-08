import Foundation

/// How a set's folder is listed in the sidebar, and what is said when its files change on disk.
public enum SidebarTree {
    public enum Row: Equatable {
        /// A subfolder heading, at its depth below the set's folder (1 for a folder in it).
        case folder(name: String, depth: Int)
        /// The file at `index` in the paths given, shown by its own name at its depth (0 for a
        /// file directly in the set's folder).
        case file(index: Int, name: String, depth: Int)
    }

    /// The rows for files given by their paths in the folder ("research/b.md"), in the order
    /// libfolio lists them: each folder's files, then its subfolders. A subfolder gets a heading
    /// before its first file.
    public static func rows(_ paths: [String]) -> [Row] {
        var rows: [Row] = []
        var open: [String] = []
        for (index, path) in paths.enumerated() {
            var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let name = parts.popLast() ?? path
            // Headings for the folders this file is in that the file before was not.
            var shared = 0
            while shared < min(open.count, parts.count), open[shared] == parts[shared] { shared += 1 }
            for depth in shared..<parts.count {
                rows.append(.folder(name: parts[depth], depth: depth + 1))
            }
            open = parts
            rows.append(.file(index: index, name: name, depth: parts.count))
        }
        return rows
    }

    /// A checkout a set's files are in: what the sidebar heads a group of files with.
    public struct Checkout: Equatable {
        /// Where its sidecars live. Distinct per checkout, so it tells groups apart.
        public let root: String
        public let repo: String
        public let branch: String?
        public let worktree: Bool

        public init(root: String, repo: String, branch: String?, worktree: Bool) {
            self.root = root
            self.repo = repo
            self.branch = branch
            self.worktree = worktree
        }

        /// The name a person knows it by: the branch if it has one, else its folder.
        public var label: String { branch ?? (root as NSString).lastPathComponent }
    }

    /// The heading of each checkout, by root: "payments-svc · main", and
    /// "payments-svc · fix/logout · worktree" for a linked worktree. Two checkouts that would
    /// read the same (two clones on one branch) get the end of their path to tell them apart.
    public static func headings(_ checkouts: [Checkout]) -> [String: String] {
        func base(_ c: Checkout) -> String {
            [c.repo, c.branch, c.worktree ? "worktree" : nil].compactMap { $0 }.joined(separator: " · ")
        }
        func tail(_ root: String, _ count: Int) -> String {
            root.split(separator: "/").suffix(count).joined(separator: "/")
        }
        var seen = Set<String>()
        let unique = checkouts.filter { seen.insert($0.root).inserted }
        var titles = Dictionary(uniqueKeysWithValues: unique.map { ($0.root, base($0)) })
        // Checkouts that read the same get the shortest end of their path that tells them apart.
        for (title, same) in Dictionary(grouping: unique, by: base) where same.count > 1 {
            var count = 2
            while count < 32, Set(same.map { tail($0.root, count) }).count < same.count { count += 1 }
            for checkout in same { titles[checkout.root] = "\(title) — \(tail(checkout.root, count))" }
        }
        return titles
    }

    /// The window's subtitle for the file open: its name, and where else the same file is in the
    /// set, in the same repo on another branch or worktree ("docs/a.md · also on fix/logout").
    public static func subtitle(name: String, checkout: Checkout?, others: [(name: String, checkout: Checkout)]) -> String {
        guard let checkout else { return name }
        let elsewhere = others
            .filter { $0.name == name && $0.checkout.repo == checkout.repo && $0.checkout.root != checkout.root }
            .map { $0.checkout.label }
        let labels = Array(Set(elsewhere)).sorted()
        return labels.isEmpty ? name : "\(name) · also on \(labels.joined(separator: ", "))"
    }

    /// What a file shows when it changed while the reader was elsewhere.
    public enum Mark: Equatable {
        /// Not there when the window opened.
        case new
        /// Its text changed since the reader last looked at it.
        case changed
    }

    /// One line for the sidebar about files that changed underneath: "c.md added, b.md changed".
    /// More than two in a kind are counted instead ("3 files added"). Nil when nothing changed.
    public static func notice(added: [String], removed: [String], changed: [String]) -> String? {
        func part(_ names: [String], _ verb: String) -> String? {
            switch names.count {
            case 0: return nil
            case 1, 2: return names.map { "\($0) \(verb)" }.joined(separator: ", ")
            default: return "\(names.count) files \(verb)"
            }
        }
        let parts = [part(added, "added"), part(removed, "removed"), part(changed, "changed")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
