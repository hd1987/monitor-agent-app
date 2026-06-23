import CoreGraphics

enum ActivityTokenChartLayout {
    static let drawerHeight: CGFloat = 190
    static let chartHeight: CGFloat = 128
    static let defaultTooltipWidth: CGFloat = 120

    static func tooltipXOffset(anchorX: CGFloat, tooltipWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let proposedOffset = anchorX - tooltipWidth / 2
        let maxOffset = max(0, availableWidth - tooltipWidth)
        return min(max(0, proposedOffset), maxOffset)
    }
}
