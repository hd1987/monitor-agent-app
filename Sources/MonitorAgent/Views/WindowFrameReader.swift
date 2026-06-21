import AppKit
import SwiftUI

struct WindowFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        FrameReportingView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FrameReportingView else { return }
        view.onChange = onChange
        view.reportFrame()
    }
}

private final class FrameReportingView: NSView {
    var onChange: (CGRect) -> Void

    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame() {
        guard let superview else { return }
        let frame = convert(bounds, to: nil)
        let superviewFrame = superview.convert(superview.bounds, to: nil)
        let resolvedFrame = frame.isEmpty ? superviewFrame : frame
        DispatchQueue.main.async {
            self.onChange(resolvedFrame)
        }
    }
}
