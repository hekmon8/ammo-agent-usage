import Foundation

public enum IslandPlacement {
    /// Public NSScreen auxiliary areas define the camera gap. Text lives in the wings.
    public static func notchFrame(screen: CGRect, camera: CGRect, wingWidth: CGFloat = 112) -> CGRect {
        let width = min(screen.width, camera.width + wingWidth * 2)
        let height = max(32, camera.height + 4)
        let x = min(max(screen.minX, camera.midX - width / 2), screen.maxX - width)
        return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
    }
    /// Below the menu and camera region; screen coordinates may be negative.
    public static func frame(screen: CGRect, visible: CGRect, safeAreaTop: CGFloat, size: CGSize) -> CGRect {
        let width = min(size.width, visible.width)
        let top = min(visible.maxY, screen.maxY - max(0, safeAreaTop)) - 8
        return CGRect(x: visible.midX - width / 2, y: max(visible.minY, top - size.height), width: width, height: min(size.height, max(0, top - visible.minY)))
    }

    /// Keeps every island state attached to the same top-center anchor while its
    /// panel changes size. Notched screens may occupy the public top auxiliary
    /// regions; other screens remain below the visible menu-bar boundary.
    public static func topCenteredFrame(
        screen: CGRect,
        visible: CGRect,
        safeAreaTop: CGFloat,
        size: CGSize,
        attachesToScreenTop: Bool
    ) -> CGRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(screen.minX, screen.midX - width / 2), screen.maxX - width)
        let top = attachesToScreenTop
            ? screen.maxY
            : min(visible.maxY, screen.maxY - max(0, safeAreaTop)) - 8
        let y = max(screen.minY, top - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
