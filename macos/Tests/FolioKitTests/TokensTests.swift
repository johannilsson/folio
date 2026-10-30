import AppKit
import FolioKit
import Testing

@Suite struct TokensTests {
    func hex(_ color: NSColor, in appearance: NSAppearance.Name) -> String {
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let c = resolved!
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    @Test func aPairFollowsTheAppearance() {
        #expect(hex(Tokens.background, in: .aqua) == "#ffffff")
        #expect(hex(Tokens.background, in: .darkAqua) == "#1a1a1a")
    }

    @Test func aSingleColourIsTheSameInBoth() {
        #expect(hex(Tokens.avatarYou, in: .aqua) == "#6366f1")
        #expect(hex(Tokens.avatarYou, in: .darkAqua) == "#6366f1")
    }
}
