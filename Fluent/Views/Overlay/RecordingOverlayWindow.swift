import SwiftUI
import AppKit

class RecordingOverlayWindow: NSPanel {
    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        // Configure as floating panel
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true

        // Don't become key window - keeps focus on user's app
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false

        // Host SwiftUI view
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = self.frame
        self.contentView = hostingView

        // Position window
        positionOnScreen()
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.visibleFrame
        let position = SettingsService.shared.settings.overlayPosition

        var x: CGFloat
        var y: CGFloat

        switch position {
        case .topCenter:
            x = screenFrame.midX - self.frame.width / 2
            y = screenFrame.maxY - self.frame.height - 50
        case .topLeft:
            x = screenFrame.minX + 50
            y = screenFrame.maxY - self.frame.height - 50
        case .topRight:
            x = screenFrame.maxX - self.frame.width - 50
            y = screenFrame.maxY - self.frame.height - 50
        case .bottomCenter:
            x = screenFrame.midX - self.frame.width / 2
            y = screenFrame.minY + 50
        case .bottomLeft:
            x = screenFrame.minX + 50
            y = screenFrame.minY + 50
        case .bottomRight:
            x = screenFrame.maxX - self.frame.width - 50
            y = screenFrame.minY + 50
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func updatePosition() {
        positionOnScreen()
    }
}
