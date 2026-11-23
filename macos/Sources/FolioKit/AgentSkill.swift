import Foundation

/// Whether the Folio agent skill is in the skills folders of the agents found (libfolio decides which and
/// compares the copies), and what the welcome card and the menu say about it.
public struct SkillStatus: Equatable {
    public enum State: String, Equatable {
        case missing, outdated, current
    }

    public struct Place: Equatable {
        public let name: String
        public let file: String

        public init(name: String, file: String) {
            self.name = name
            self.file = file
        }
    }

    public let state: State
    public let places: [Place]

    public init(state: State, places: [Place]) {
        self.state = state
        self.places = places
    }

    /// The welcome card waits until the skill is in place and up to date.
    public var needsAttention: Bool { state != .current }

    /// The pill on the card.
    public var buttonTitle: String {
        switch state {
        case .missing: "Install"
        case .outdated: "Update"
        case .current: "Installed"
        }
    }

    /// The small badge beside the card's title.
    public var badge: String? {
        switch state {
        case .missing: "Recommended"
        case .outdated: "Update available"
        case .current: nil
        }
    }

    /// The agents, as a sentence part: "Claude Code", "Claude Code and OpenCode", "A, B and C".
    public var agents: String {
        let names = places.map(\.name)
        guard let last = names.last else { return "your agents" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The card's one-line pitch.
    public var pitch: String {
        switch state {
        case .missing: "Teaches your agents to review documents in Folio. Installs for \(agents)."
        case .outdated: "A newer skill comes with this version of Folio. Updates it for \(agents)."
        case .current: "Installed for \(agents)."
        }
    }

    /// Folio ▸ Install Agent Skill…, whatever the state: it installs what is missing and replaces what is old.
    public var menuTitle: String {
        switch state {
        case .missing: "Install Agent Skill…"
        case .outdated: "Update Agent Skill…"
        case .current: "Reinstall Agent Skill…"
        }
    }
}
