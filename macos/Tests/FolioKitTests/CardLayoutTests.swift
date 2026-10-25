import CoreGraphics
import Foundation
import FolioKit
import Testing

@Suite struct CardLayoutTests {
    func card(_ top: CGFloat?, order: Int = 0, height: CGFloat = 50) -> CardLayout.Card {
        CardLayout.Card(anchor: top.map { CardLayout.Anchor(top: $0, order: order) }, height: height)
    }

    // MARK: the comments pane

    @Test func aCardSitsAtItsAnchorsTopMinusFour() {
        let stacked = CardLayout.stack([card(100)], end: 1000)
        #expect(stacked.placed.map { $0.top } == [96])
        #expect(stacked.extent == 96 + 50 + 6)
    }

    @Test func aCardThatWouldOverlapIsPushedDownSixBelowTheOneAbove() {
        let stacked = CardLayout.stack([card(100, order: 1, height: 80), card(120, order: 2, height: 30)], end: 1000)
        #expect(stacked.placed.map { $0.top } == [96, 96 + 80 + 6])
    }

    @Test func aCardWithRoomStaysAtItsAnchor() {
        let stacked = CardLayout.stack([card(100, order: 1, height: 20), card(300, order: 2)], end: 1000)
        #expect(stacked.placed.map { $0.top } == [96, 296])
    }

    @Test func cardsAreStackedInDocumentOrder() {
        // Given out of order: the one earlier in the document goes first, whatever its anchor's top.
        let stacked = CardLayout.stack([card(100, order: 5), card(200, order: 2)], end: 1000)
        #expect(stacked.placed.map { $0.index } == [1, 0])
        #expect(stacked.placed.map { $0.top } == [196, 196 + 50 + 6])
    }

    @Test func aCardNotFoundInTheDocumentIsParkedAfterTheText() {
        let stacked = CardLayout.stack([card(nil), card(100, order: 3)], end: 400)
        #expect(stacked.placed.map { $0.index } == [1, 0])
        #expect(stacked.placed.map { $0.top } == [96, 396])
    }

    @Test func nothingToStackReachesNowhere() {
        let stacked = CardLayout.stack([], end: 400)
        #expect(stacked.placed.isEmpty)
        #expect(stacked.extent == 0)
    }

    // MARK: floating

    let visible = CGRect(x: 0, y: 1000, width: 800, height: 600)

    @Test func floatsBelowTheText() {
        let origin = CardLayout.floatingOrigin(width: 280, height: 100, left: 50, top: 1100, bottom: 1120,
                                               visible: visible, textWidth: 800)
        #expect(origin == CGPoint(x: 50, y: 1126))
    }

    @Test func flipsAboveNearTheBottomOfTheVisibleArea() {
        let origin = CardLayout.floatingOrigin(width: 280, height: 100, left: 50, top: 1500, bottom: 1520,
                                               visible: visible, textWidth: 800)
        #expect(origin == CGPoint(x: 50, y: 1500 - 100 - 6))
    }

    @Test func fittingNeitherWayStaysInsideWhatIsVisible() {
        // Text at the bottom of the window, too little room above as well.
        let tall = CardLayout.floatingOrigin(width: 280, height: 590, left: 50, top: 1500, bottom: 1590,
                                             visible: visible, textWidth: 800)
        #expect(tall.y == 1000 + 8)
        let below = CardLayout.floatingOrigin(width: 280, height: 100, left: 50, top: 1050, bottom: 1580,
                                              visible: visible, textWidth: 800)
        #expect(below.y == 1600 - 100 - 8)
    }

    @Test func floatingStaysInsideTheTextColumn() {
        let right = CardLayout.floatingOrigin(width: 280, height: 100, left: 700, top: 1100, bottom: 1120,
                                              visible: visible, textWidth: 800)
        #expect(right.x == 800 - 280 - 8)
        let left = CardLayout.floatingOrigin(width: 280, height: 100, left: 2, top: 1100, bottom: 1120,
                                             visible: visible, textWidth: 800)
        #expect(left.x == 8)
        let narrow = CardLayout.floatingOrigin(width: 280, height: 100, left: 50, top: 1100, bottom: 1120,
                                               visible: visible, textWidth: 200)
        #expect(narrow.x == 8)
    }

    @Test func theCommentButtonIsCentredAboveTheSelection() {
        let origin = CardLayout.adderOrigin(width: 98, height: 32, left: 100, right: 300, top: 1200, bottom: 1220,
                                            visible: visible, textWidth: 800)
        #expect(origin == CGPoint(x: 200 - 49, y: 1200 - 8 - 32))
    }

    @Test func theCommentButtonGoesBelowWithNoRoomAbove() {
        let origin = CardLayout.adderOrigin(width: 98, height: 32, left: 100, right: 300, top: 1020, bottom: 1040,
                                            visible: visible, textWidth: 800)
        #expect(origin.y == 1040 + 8)
    }

    @Test func theCommentButtonStaysInsideTheTextColumn() {
        let right = CardLayout.adderOrigin(width: 98, height: 32, left: 760, right: 800, top: 1200, bottom: 1220,
                                           visible: visible, textWidth: 800)
        #expect(right.x == 800 - 98 - 8)
        let left = CardLayout.adderOrigin(width: 98, height: 32, left: 0, right: 10, top: 1200, bottom: 1220,
                                          visible: visible, textWidth: 800)
        #expect(left.x == 8)
    }
}
