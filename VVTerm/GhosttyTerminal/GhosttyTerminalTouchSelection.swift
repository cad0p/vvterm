#if os(iOS)
import UIKit

enum TerminalTouchSelectionStyle {
    static let tintColor = UIColor(red: 0.90, green: 0.73, blue: 0.26, alpha: 1)
    static let highlightColor = tintColor.withAlphaComponent(0.40)
}

enum TerminalTouchSelectionHandleKind {
    case start
    case end
}

final class TerminalTouchSelectionHandleView: UIView {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    let kind: TerminalTouchSelectionHandleKind

    private let stemView = UIView()
    private let knobView = UIView()

    init(kind: TerminalTouchSelectionHandleKind) {
        self.kind = kind
        super.init(frame: .zero)

        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false

        stemView.isUserInteractionEnabled = false
        knobView.isUserInteractionEnabled = false

        addSubview(stemView)
        addSubview(knobView)

        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let knobDiameter: CGFloat = 18
        let stemWidth: CGFloat = 4
        let stemHeight = max(bounds.height - knobDiameter, 10)
        let stemX = (bounds.width - stemWidth) / 2
        let knobX = (bounds.width - knobDiameter) / 2

        switch kind {
        case .start:
            knobView.frame = CGRect(
                x: knobX,
                y: 0,
                width: knobDiameter,
                height: knobDiameter
            )
            stemView.frame = CGRect(
                x: stemX,
                y: knobDiameter / 2,
                width: stemWidth,
                height: stemHeight
            )
        case .end:
            stemView.frame = CGRect(
                x: stemX,
                y: 0,
                width: stemWidth,
                height: stemHeight
            )
            knobView.frame = CGRect(
                x: knobX,
                y: stemHeight,
                width: knobDiameter,
                height: knobDiameter
            )
        }

        stemView.layer.cornerRadius = stemWidth / 2
        knobView.layer.cornerRadius = knobDiameter / 2
    }

    private func updateColors() {
        stemView.backgroundColor = tintColor
        knobView.backgroundColor = tintColor
        knobView.layer.borderWidth = 0
        knobView.layer.shadowColor = UIColor.black.withAlphaComponent(0.24).cgColor
        knobView.layer.shadowOpacity = 1
        knobView.layer.shadowRadius = 5
        knobView.layer.shadowOffset = CGSize(width: 0, height: 2)
    }
}

final class TerminalTouchSelectionOverlayView: UIView {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let highlightLayer = CAShapeLayer()
    let startHandle = TerminalTouchSelectionHandleView(kind: .start)
    let endHandle = TerminalTouchSelectionHandleView(kind: .end)

    override init(frame: CGRect) {
        super.init(frame: frame)

        isOpaque = false
        backgroundColor = .clear

        highlightLayer.fillColor = TerminalTouchSelectionStyle.highlightColor.cgColor
        highlightLayer.strokeColor = nil
        highlightLayer.lineWidth = 0
        layer.addSublayer(highlightLayer)

        startHandle.tintColor = TerminalTouchSelectionStyle.tintColor
        endHandle.tintColor = TerminalTouchSelectionStyle.tintColor
        startHandle.isHidden = true
        endHandle.isHidden = true
        addSubview(startHandle)
        addSubview(endHandle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlightLayer.frame = bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedInset: CGFloat = -22
        if !startHandle.isHidden && startHandle.frame.insetBy(dx: expandedInset, dy: expandedInset).contains(point) {
            return true
        }
        if !endHandle.isHidden && endHandle.frame.insetBy(dx: expandedInset, dy: expandedInset).contains(point) {
            return true
        }
        return false
    }

    func clear() {
        highlightLayer.path = nil
        startHandle.isHidden = true
        endHandle.isHidden = true
    }

    func update(rects: [CGRect], startAnchor: CGPoint?, endAnchor: CGPoint?) {
        guard !rects.isEmpty, let startAnchor, let endAnchor else {
            clear()
            return
        }

        let path = UIBezierPath()
        for rect in rects {
            let verticalInset = max(rect.height * 0.14, 1.5)
            let adjustedRect = rect.insetBy(dx: 0, dy: verticalInset).integral
            path.append(UIBezierPath(rect: adjustedRect))
        }
        highlightLayer.path = path.cgPath

        let handleSize = CGSize(width: 34, height: 34)
        startHandle.bounds = CGRect(origin: .zero, size: handleSize)
        endHandle.bounds = CGRect(origin: .zero, size: handleSize)
        startHandle.center = CGPoint(x: startAnchor.x, y: startAnchor.y - handleSize.height / 2)
        endHandle.center = CGPoint(x: endAnchor.x, y: endAnchor.y + handleSize.height / 2)
        startHandle.isHidden = false
        endHandle.isHidden = false
    }
}

final class TerminalTouchSelectionLoupeView: UIView {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private let chromeView = UIView()
    private let contentContainer = UIView()
    private let shadowView = UIView()
    private var snapshotView: UIView?

    private let magnification: CGFloat = 1.85
    private let focusAnchorYRatio: CGFloat = 0.30

    override init(frame: CGRect) {
        super.init(frame: frame)

        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = false

        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.withAlphaComponent(0.38).cgColor
        shadowView.layer.shadowOpacity = 1
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
        addSubview(shadowView)

        chromeView.backgroundColor = UIColor.black.withAlphaComponent(0.94)
        chromeView.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        chromeView.layer.borderWidth = 1
        chromeView.clipsToBounds = true
        addSubview(chromeView)

        contentContainer.backgroundColor = .clear
        contentContainer.clipsToBounds = true
        chromeView.addSubview(contentContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadowView.frame = bounds
        chromeView.frame = bounds
        chromeView.layer.cornerRadius = bounds.width / 2
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width / 2).cgPath
        contentContainer.frame = chromeView.bounds
    }

    func hideLoupe() {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        isHidden = true
    }

    func update(
        from sourceView: UIView,
        focusPoint: CGPoint,
        in containerBounds: CGRect,
        safeAreaInsets: UIEdgeInsets
    ) {
        let diameter = min(max(containerBounds.width * 0.36, 118), 146)
        bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
        setNeedsLayout()
        layoutIfNeeded()

        let margin: CGFloat = 12
        let xInset = safeAreaInsets.left + bounds.width / 2 + margin
        let maxX = containerBounds.width - safeAreaInsets.right - bounds.width / 2 - margin
        let yInset = safeAreaInsets.top + bounds.height / 2 + margin
        let maxY = containerBounds.height - safeAreaInsets.bottom - bounds.height / 2 - margin

        var center = CGPoint(x: focusPoint.x + bounds.width * 0.42, y: focusPoint.y - bounds.height * 0.34)
        if center.y < yInset {
            center.y = min(focusPoint.y + bounds.height * 0.34, maxY)
        }
        center.x = min(max(center.x, xInset), maxX)
        center.y = min(max(center.y, yInset), maxY)
        self.center = center

        let sampleSize = CGSize(width: bounds.width / magnification, height: bounds.height / magnification)
        var sampleRect = CGRect(
            x: focusPoint.x - sampleSize.width / 2,
            y: focusPoint.y - sampleSize.height / 2,
            width: sampleSize.width,
            height: sampleSize.height
        ).integral

        sampleRect.origin.x = min(max(sampleRect.origin.x, 0), max(containerBounds.width - sampleRect.width, 0))
        sampleRect.origin.y = min(max(sampleRect.origin.y, 0), max(containerBounds.height - sampleRect.height, 0))

        let snapshot = sourceView.resizableSnapshotView(
            from: sampleRect,
            afterScreenUpdates: false,
            withCapInsets: .zero
        )

        snapshotView?.removeFromSuperview()
        snapshotView = snapshot

        guard let snapshot else {
            isHidden = true
            return
        }

        snapshot.bounds = CGRect(origin: .zero, size: sampleRect.size)
        snapshot.transform = CGAffineTransform(scaleX: magnification, y: magnification)
        snapshot.center = CGPoint(
            x: contentContainer.bounds.midX,
            y: contentContainer.bounds.height * focusAnchorYRatio
        )
        contentContainer.addSubview(snapshot)
        isHidden = false
    }
}
#endif
