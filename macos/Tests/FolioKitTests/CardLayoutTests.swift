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
        #expect(stacked.extent == (96 + 50 + 6 as CGFloat))
    }

    @Test func aCardThatWouldOverlapIsPushedDownSixBelowTheOneAbove() {
        let stacked = CardLayout.stack([card(100, order: 1, height: 80), card(120, order: 2, height: 30)], end: 1000)
        #expect(stacked.placed.map { $0.top } == [96, 96 + 80 + 6] as [CGFloat])
    }

    @Test func aCardWithRoomStaysAtItsAnchor() {
        let stacked = CardLayout.stack([card(100, order: 1, height: 20), card(300, order: 2)], end: 1000)
        #expect(stacked.placed.map { $0.top } == [96, 296] as [CGFloat])
    }

    @Test func cardsAreStackedInDocumentOrder() {
        // Given out of order: the one earlier in the document goes first, whatever its anchor's top.
        let stacked = CardLayout.stack([card(100, order: 5), card(200, order: 2)], end: 1000)
        #expect(stacked.placed.map { $0.index } == [1, 0])
        #expect(stacked.placed.map { $0.top } == [196, 196 + 50 + 6] as [CGFloat])
    }

    @Test func aCardNotFoundInTheDocumentIsParkedAfterTheText() {
        let stacked = CardLayout.stack([card(nil), card(100, order: 3)], end: 400)
        #expect(stacked.placed.map { $0.index } == [1, 0])
        #expect(stacked.placed.map { $0.top } == [96, 396] as [CGFloat])
    }

    @Test func nothingToStackReachesNowhere() {
        let stacked = CardLayout.stack([], end: 400)
        #expect(stacked.placed.isEmpty)
        #expect(stacked.extent == 0)
    }

    // MARK: inline

    func inline(_ end: Int?, bottom: CGFloat = 100, next: CGFloat = 110, order: Int = 0, height: CGFloat = 50) -> CardLayout.InlineCard {
        CardLayout.InlineCard(row: end.map { CardLayout.Row(end: $0, bottom: bottom, next: next) }, order: order, height: height)
    }

    @Test func anInlineCardSitsEightBelowItsRow() {
        let laid = CardLayout.inline([inline(40)], end: 1000)
        #expect(laid.placed.map { $0.top } == [108])
        // The text after the row starts 14 below the card: 108 + 50 + 14 = 172, where it started at 110.
        #expect(laid.room == [40: 62])
        #expect(laid.extent == 158)
    }

    @Test func cardsUnderOneRowStackSixApartInDocumentOrder() {
        let laid = CardLayout.inline([inline(40, order: 9, height: 30), inline(40, order: 3, height: 20)], end: 1000)
        #expect(laid.placed.map { $0.index } == [1, 0])
        #expect(laid.placed.map { $0.top } == [108, 108 + 20 + 6] as [CGFloat])
        #expect(laid.room == [40: 108 + 20 + 6 + 30 + 14 - 110])
    }

    @Test func eachRowGetsItsOwnRoom() {
        let laid = CardLayout.inline([inline(90, bottom: 300, next: 310, order: 50), inline(40, order: 10)], end: 1000)
        #expect(laid.placed.map { $0.index } == [1, 0])
        #expect(laid.placed.map { $0.top } == [108, 308] as [CGFloat])
        #expect(laid.room == [40: 62, 90: 62])
    }

    @Test func aRowWithRoomEnoughOfItsOwnGetsNoMore() {
        // A tall gap after the row already (the end of a code block, say): no room is added.
        let laid = CardLayout.inline([inline(40, next: 200, height: 20)], end: 1000)
        #expect(laid.room == [40: 0])
    }

    @Test func anInlineCardNotFoundIsParkedAfterTheText() {
        let laid = CardLayout.inline([inline(nil, height: 30), inline(nil, height: 40), inline(40)], end: 500)
        #expect(laid.placed.map { $0.index } == [2, 0, 1])
        #expect(laid.placed.map { $0.top } == [108, 508, 508 + 30 + 6] as [CGFloat])
        #expect(laid.room == [40: 62])
        #expect(laid.extent == 508 + 30 + 6 + 40)
    }

    @Test func noInlineCardsLeaveNoRoom() {
        let laid = CardLayout.inline([], end: 500)
        #expect(laid.placed.isEmpty)
        #expect(laid.room.isEmpty)
        #expect(laid.extent == 0)
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
        #expect(tall.y == (1000 + 8 as CGFloat))
        let below = CardLayout.floatingOrigin(width: 280, height: 100, left: 50, top: 1050, bottom: 1580,
                                              visible: visible, textWidth: 800)
        #expect(below.y == (1600 - 100 - 8 as CGFloat))
    }

    // MARK: revealing

    private func reveal(_ anchor: (CGFloat, CGFloat), card: (CGFloat, CGFloat)? = nil) -> CGFloat {
        CardLayout.revealDelta(anchor: (anchor.0, anchor.1), card: card.map { ($0.0, $0.1) },
                               visible: visible, topMargin: 40, bottomMargin: 24)
    }

    @Test func revealingWhatIsInViewDoesNotScroll() {
        #expect(reveal((1100, 1120), card: (1090, 1300)) == 0)
    }

    @Test func revealKeepsClearOfTheToolbarBlur() {
        // Visible from 1000, margin 40: a line at 1020 is under the blur, so scroll up by 20.
        #expect(reveal((1020, 1040)) == -20)
    }

    @Test func revealScrollsDownToTheBottomMargin() {
        #expect(reveal((1590, 1610)) == (1610 - (1600 - 24) as CGFloat))
    }

    @Test func revealFollowsTheCardWhenBothFit() {
        // The text is in view, its card in the pane is below the window: scroll down to show the card.
        #expect(reveal((1100, 1120), card: (1100, 1700)) == 0)   // too tall together: the text wins
        #expect(reveal((1500, 1520), card: (1500, 1640)) == (1640 - (1600 - 24) as CGFloat))
    }

    @Test func revealOfATallAnchorShowsItsTop() {
        #expect(reveal((1700, 2400)) == (1700 - 1040 as CGFloat))
    }

    @Test func floatingStaysInsideTheTextColumn() {
        let right = CardLayout.floatingOrigin(width: 280, height: 100, left: 700, top: 1100, bottom: 1120,
                                              visible: visible, textWidth: 800)
        #expect(right.x == (800 - 280 - 8 as CGFloat))
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
        #expect(origin.y == (1040 + 8 as CGFloat))
    }

    @Test func theCommentButtonStaysInsideTheTextColumn() {
        let right = CardLayout.adderOrigin(width: 98, height: 32, left: 760, right: 800, top: 1200, bottom: 1220,
                                           visible: visible, textWidth: 800)
        #expect(right.x == (800 - 98 - 8 as CGFloat))
        let left = CardLayout.adderOrigin(width: 98, height: 32, left: 0, right: 10, top: 1200, bottom: 1220,
                                          visible: visible, textWidth: 800)
        #expect(left.x == 8)
    }
}
