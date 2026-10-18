import Foundation

/// Width calculations shared by the manager view and its regression tests.
public enum ManagerLayout {
    /// Keep a width captured while the window was larger from overflowing its current detail area.
    public static func fittingTableWidth(measuredWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let available = max(0, availableWidth)
        guard measuredWidth.isFinite else { return available }
        return min(max(0, measuredWidth), available)
    }
}
