/// Where a window has been, for Back and Forward: going somewhere new drops what was ahead, as in a
/// browser or Finder. A place that goes away (a file taken out of the set) is dropped from the history.
public struct NavigationHistory<Place: Equatable>: Equatable {
    /// The place on screen; nil once it has gone away, until the next visit.
    public private(set) var current: Place?
    /// The places behind, the nearest last.
    public private(set) var back: [Place] = []
    /// The places ahead, the nearest last.
    public private(set) var forward: [Place] = []

    public init(_ start: Place? = nil) {
        current = start
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Going to `place`: the place on screen goes behind and what was ahead is dropped. Going to the place on
    /// screen changes nothing.
    public mutating func visit(_ place: Place) {
        guard place != current else { return }
        if let current { back.append(current) } else if back.last == place { back.removeLast() }
        forward = []
        current = place
    }

    /// One step back: the place to show, nil when there is none.
    public mutating func goBack() -> Place? {
        guard let place = back.popLast() else { return nil }
        if let current { forward.append(current) }
        current = place
        return place
    }

    /// One step forward: the place to show, nil when there is none.
    public mutating func goForward() -> Place? {
        guard let place = forward.popLast() else { return nil }
        if let current { back.append(current) }
        current = place
        return place
    }

    /// Drops the places that went away. Two steps that would show the same place in a row become one.
    public mutating func remove(where gone: (Place) -> Bool) {
        if let place = current, gone(place) { current = nil }
        back = Self.collapsed(back.filter { !gone($0) })
        forward = Self.collapsed(forward.filter { !gone($0) })
        if let current {
            if back.last == current { back.removeLast() }
            if forward.last == current { forward.removeLast() }
        }
    }

    private static func collapsed(_ places: [Place]) -> [Place] {
        var result: [Place] = []
        for place in places where result.last != place { result.append(place) }
        return result
    }
}
