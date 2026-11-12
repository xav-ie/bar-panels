import AppKit

/// Keyboard focus on a control inside a panel (a slider, a button): a 2pt
/// outline 3pt outside it, in the label color. Focused rows show their
/// highlight instead. Drawn by the panel rather than AppKit, whose focus ring
/// only shows on buttons and sliders with the system's Keyboard navigation
/// setting on. Never hit-tested.
final class FocusRing: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.borderWidth = 2
    isHidden = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.borderColor = NSColor.labelColor.cgColor }

  func show(around view: NSView, in container: NSView) {
    let r = view.convert(view.bounds, to: container).insetBy(dx: -3, dy: -3)
    frame = r
    layer?.cornerRadius = min(r.height / 2, 8)
    isHidden = false
    needsDisplay = true
  }
}
