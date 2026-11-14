import FolioKit
import Testing

@Suite struct NavigationHistoryTests {
    func visited(_ places: String...) -> NavigationHistory<String> {
        var history = NavigationHistory<String>(places.first)
        for place in places.dropFirst() { history.visit(place) }
        return history
    }

    @Test func aNewHistoryHasNowhereToGo() {
        let history = NavigationHistory("a")
        #expect(history.current == "a" && !history.canGoBack && !history.canGoForward)
    }

    @Test func backAndForwardRetraceTheVisits() {
        var history = visited("a", "b", "c")
        #expect(history.goBack() == "b")
        #expect(history.goBack() == "a")
        #expect(history.goBack() == nil)
        #expect(history.current == "a")
        #expect(history.goForward() == "b")
        #expect(history.goForward() == "c")
        #expect(history.goForward() == nil)
        #expect(history.current == "c")
    }

    @Test func goingSomewhereNewDropsWhatWasAhead() {
        var history = visited("a", "b", "c")
        _ = history.goBack()
        history.visit("d")
        #expect(!history.canGoForward)
        #expect(history.back == ["a", "b"])
        #expect(history.current == "d")
    }

    @Test func goingToThePlaceOnScreenChangesNothing() {
        var history = visited("a", "b")
        _ = history.goBack()
        history.visit("a")
        #expect(history.back.isEmpty && history.forward == ["b"] && history.current == "a")
    }

    @Test func aPlaceThatWentAwayIsDropped() {
        var history = visited("a", "b", "a", "c", "d")
        _ = history.goBack()
        history.remove { $0 == "b" || $0 == "d" }
        // a, a in a row become one; d ahead is gone.
        #expect(history.back == ["a"] && history.current == "c" && history.forward.isEmpty)
    }

    @Test func aStepToThePlaceOnScreenIsDropped() {
        var history = visited("a", "b", "a")
        history.remove { $0 == "b" }
        #expect(history.back.isEmpty && history.current == "a")
    }

    @Test func thePlaceOnScreenGoingAwayLeavesNoCurrentUntilTheNextVisit() {
        var history = visited("a", "b")
        history.remove { $0 == "b" }
        #expect(history.current == nil && history.back == ["a"])
        history.visit("a")
        // No step back from a to a.
        #expect(history.current == "a" && history.back.isEmpty)
    }
}
