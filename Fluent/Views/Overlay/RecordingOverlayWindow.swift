import SwiftUI
import AppKit

/// A transparent panel of fixed size that the overlay pill floats in.
///
/// The panel never resizes with its content. When it did, it sized itself to whatever the pill
/// looked like the moment it appeared and then grew only to the pill's *minimum* size, where the
/// clock Text collapses to zero width. Resizing also moved the pill off center, since a window
/// grows from its origin, and clipped the pill's shadow. Now SwiftUI lays the pill out at its
/// natural size and pins it to the edge the user chose; transparent pixels let clicks through.
class RecordingOverlayWindow: NSPanel {
    /// Wide enough for the longest one-line status message; height fits the two-line preview.
    private static let canvasSize = NSSize(width: 560, height: 140)
    /// Room around the pill for its shadow (radius 8, offset 4).
    private static let shadowMargin: CGFloat = 16
    /// Distance from the pill to the screen's edge.
    private static let screenInset: CGFloat = 50

    private let position: AppSettings.OverlayPosition

    init<Content: View>(contentView: Content) {
        position = SettingsService.shared.settings.overlayPosition

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        // Configure as floating panel
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        // The pill draws its own shadow. A window shadow is traced from the canvas once and
        // goes stale when the pill changes size inside it.
        self.hasShadow = false
        self.isMovableByWindowBackground = true

        // Don't become key window - keeps focus on user's app
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false

        // Host SwiftUI view, pinned to the chosen edge of the canvas
        let root = contentView
            .padding(Self.shadowMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(for: position))
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []  // the content must not resize the window
        hostingView.frame = NSRect(origin: .zero, size: Self.canvasSize)
        self.contentView = hostingView

        // Position window
        positionOnScreen()
    }

    private static func alignment(for position: AppSettings.OverlayPosition) -> Alignment {
        switch position {
        case .topCenter: return .top
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomCenter: return .bottom
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    /// Places the canvas so the pill's outer edge sits `screenInset` from the screen's edge.
    private func positionOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.visibleFrame
        let size = Self.canvasSize
        let edgeOffset = Self.screenInset - Self.shadowMargin

        let left = screenFrame.minX + edgeOffset
        let centerX = screenFrame.midX - size.width / 2
        let right = screenFrame.maxX - edgeOffset - size.width
        let top = screenFrame.maxY - edgeOffset - size.height
        let bottom = screenFrame.minY + edgeOffset

        let origin: NSPoint
        switch position {
        case .topCenter: origin = NSPoint(x: centerX, y: top)
        case .topLeft: origin = NSPoint(x: left, y: top)
        case .topRight: origin = NSPoint(x: right, y: top)
        case .bottomCenter: origin = NSPoint(x: centerX, y: bottom)
        case .bottomLeft: origin = NSPoint(x: left, y: bottom)
        case .bottomRight: origin = NSPoint(x: right, y: bottom)
        }

        self.setFrameOrigin(origin)
    }

    func updatePosition() {
        positionOnScreen()
    }
}
