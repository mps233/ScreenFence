import CoreGraphics
import Foundation

/// All values use the same global Quartz coordinate space as CGEvent.location.
/// The upper endpoints are kept inside the display, never on the next display.
public struct FenceRegion: Equatable {
    public let bounds: CGRect
    public let edgeInset: CGFloat

    public init?(bounds: CGRect, edgeInset: CGFloat = 1) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width >= 1, bounds.size.height >= 1,
              bounds.maxX.isFinite, bounds.maxY.isFinite,
              edgeInset.isFinite, edgeInset > 0 else { return nil }
        self.bounds = bounds
        self.edgeInset = min(edgeInset, bounds.width / 2, bounds.height / 2)
    }

    public var maximumX: CGFloat { bounds.maxX - edgeInset }
    public var maximumY: CGFloat { bounds.maxY - edgeInset }

    public func contains(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite &&
        point.x >= bounds.minX && point.x <= maximumX &&
        point.y >= bounds.minY && point.y <= maximumY
    }

    public func constrain(_ point: CGPoint) -> CGPoint {
        // No relative displacement is accumulated. Movement back into the
        // region is accepted on its very first event.
        CGPoint(
            x: min(max(point.x, bounds.minX), maximumX),
            y: min(max(point.y, bounds.minY), maximumY)
        )
    }
}

public enum FenceEventFilter {
    /// Preserve the original event, deltas, buttons, pressure and modifiers.
    /// Dropping a whole event at one boundary would also drop tangential motion.
    @discardableResult
    public static func constrain(_ event: CGEvent, to region: FenceRegion) -> Bool {
        let point = event.location
        guard point.x.isFinite, point.y.isFinite else { return false }
        let corrected = region.constrain(point)
        guard corrected != point else { return false }
        event.location = corrected
        return true
    }
}
