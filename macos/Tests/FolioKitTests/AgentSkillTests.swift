import Foundation
import FolioKit
import Testing

@Suite struct AgentSkillTests {
    private func status(_ state: SkillStatus.State, _ names: [String]) -> SkillStatus {
        SkillStatus(state: state, places: names.map { SkillStatus.Place(name: $0, file: "/\($0)/SKILL.md") })
    }

    @Test func theCardWaitsUntilTheSkillIsInPlaceAndCurrent() {
        #expect(status(.missing, ["Claude Code"]).needsAttention)
        #expect(status(.outdated, ["Claude Code"]).needsAttention)
        #expect(!status(.current, ["Claude Code"]).needsAttention)
    }

    @Test func thePillAndBadgeFollowTheState() {
        let missing = status(.missing, ["Claude Code"])
        #expect(missing.buttonTitle == "Install")
        #expect(missing.badge == "Recommended")
        let outdated = status(.outdated, ["Claude Code"])
        #expect(outdated.buttonTitle == "Update")
        #expect(outdated.badge == "Update available")
        let current = status(.current, ["Claude Code"])
        #expect(current.buttonTitle == "Installed")
        #expect(current.badge == nil)
    }

    @Test func theMenuAlwaysOffersAWayToInstall() {
        #expect(status(.missing, []).menuTitle == "Install Agent Skill…")
        #expect(status(.outdated, []).menuTitle == "Update Agent Skill…")
        #expect(status(.current, []).menuTitle == "Reinstall Agent Skill…")
    }

    @Test func agentsReadAsASentence() {
        #expect(status(.missing, []).agents == "your agents")
        #expect(status(.missing, ["Claude Code"]).agents == "Claude Code")
        #expect(status(.missing, ["Claude Code", "OpenCode"]).agents == "Claude Code and OpenCode")
        #expect(status(.missing, ["A", "B", "C"]).agents == "A, B and C")
    }
}
