import AppKit

// A menu-like row: hover-highlights, whole row is clickable. Left slot shows a
// checkmark (revealed), a ⚠ (agent not injected), or nothing (actions/header).
public final class HoverRow: NSView {
  public enum Mark {
    case check(Bool)
    case partial  // an app with only some of its windows revealed
    case busy  // a switch to this row is in flight
    case warning, none
  }

  public var onClick: (() -> Void)?
  /// The row's title, which identifies it across a panel's rebuilds.
  public let title: String
  /// Disabled rows don't take keyboard focus.
  public let isEnabled: Bool
  /// A disclosure row (it shows or hides the rows under it): whether it's
  /// open, or nil for any other row. Right and left open and close it.
  public let expanded: Bool?
  /// Keyboard focus, which the panel sets while the keyboard drives it: then
  /// the focused row is highlighted rather than the one under the pointer.
  /// nil while the pointer drives the panel.
  public var focused: Bool? {
    didSet { applyHighlight() }
  }
  private let label = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let mark = NSImageView()
  private var track: NSTrackingArea?
  private var hovered = false

  public init(
    _ title: String, icon: NSImage? = nil, subtitle: String? = nil, mark m: Mark = .none,
    iconTint: NSColor = .labelColor, enabled: Bool = true, indent: CGFloat = 0,
    accessory: NSImage? = nil, expanded: Bool? = nil, toggle: (key: String, on: Bool)? = nil,
    title isTitle: Bool = false, detail: String? = nil
  ) {
    self.title = title
    isEnabled = enabled
    self.expanded = expanded
    super.init(frame: NSRect(x: 0, y: 0, width: ROW_W, height: ROW_H))
    wantsLayer = true
    layer?.cornerRadius = PANEL_RADIUS - PANEL_PAD  // concentric with the panel's corners

    // A title row (a panel's own on/off switch) reads like the panel titles:
    // their font and their left edge. A switch row's mark (a spinner) sits by
    // its switch; only a row that can be checked keeps the check column, so
    // actions ("Wi-Fi Settings…") line up with the titles, not the checkmarks.
    var x: CGFloat = 8 + indent
    var right: CGFloat = 8
    if let toggle { right += ToggleSwitch.size.width + 6 }
    let bySwitch = toggle != nil
    let checkColumn: Bool
    switch m {
    case .none: checkColumn = false
    default: checkColumn = !bySwitch
    }
    let markX = bySwitch ? ROW_W - right - 13 : x
    if bySwitch { right += 13 + 6 }
    mark.frame = NSRect(x: markX, y: (ROW_H - 13) / 2, width: 13, height: 13)
    mark.contentTintColor = .labelColor
    switch m {
    case .check(let on):
      mark.image = checkImage(on)
    case .partial:
      mark.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
    case .warning:
      mark.contentTintColor = .systemOrange
      mark.image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
    case .busy:
      // The full-size spinner drawn a little over the mark's size: the small
      // one's thin spokes all but vanish on glass.
      let spinner = NSProgressIndicator(frame: mark.frame.insetBy(dx: -1, dy: -1))
      spinner.style = .spinning
      spinner.controlSize = .regular
      spinner.startAnimation(nil)
      addSubview(spinner)
    case .none:
      break
    }
    addSubview(mark)
    if checkColumn { x += 20 }

    if let icon {
      icon.size = NSSize(width: 16, height: 16)
      let iv = NSImageView(frame: NSRect(x: x, y: (ROW_H - 16) / 2, width: 16, height: 16))
      iv.image = icon
      // Symbols are templates: drawn in this color, not the glass's vibrancy.
      iv.contentTintColor = enabled ? iconTint : SECONDARY_TEXT
      addSubview(iv)
      x += 22
    }

    let font =
      isTitle ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 12)
    let attr = NSMutableAttributedString(string: title, attributes: [.font: font])
    if let sub = subtitle {
      attr.append(
        NSAttributedString(
          string: "  — \(sub)",
          attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange,
          ]))
    }
    label.attributedStringValue = attr
    label.textColor = enabled ? .labelColor : SECONDARY_TEXT
    label.lineBreakMode = .byTruncatingTail
    // A trailing glyph (a lock, a disclosure chevron), right-aligned.
    let chevron = expanded.map {
      NSImage(
        systemSymbolName: $0 ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }
    if let accessory = chevron ?? accessory {
      let av = NSImageView(
        frame: NSRect(x: ROW_W - 8 - 12, y: (ROW_H - 12) / 2, width: 12, height: 12))
      av.image = accessory
      av.contentTintColor = SECONDARY_TEXT
      addSubview(av)
      right += 18
    }
    // An on/off setting: a switch on the right, the whole row toggles it.
    if let toggle {
      let sw = ToggleSwitch(key: toggle.key, on: toggle.on)
      let size = ToggleSwitch.size
      sw.setFrameOrigin(NSPoint(x: ROW_W - 8 - size.width, y: (ROW_H - size.height) / 2))
      addSubview(sw)
    }
    // A value on the right ("8 s"), which can change without a rebuild.
    if let detail {
      detailLabel.stringValue = detail
      detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      detailLabel.textColor = SECONDARY_TEXT
      detailLabel.alignment = .right
      detailLabel.frame = NSRect(x: ROW_W - right - 60, y: (ROW_H - 16) / 2, width: 60, height: 16)
      addSubview(detailLabel)
      right += 64
    }
    label.frame = NSRect(x: x, y: (ROW_H - 16) / 2, width: ROW_W - x - right, height: 16)
    addSubview(label)

    setAccessibilityElement(true)
    setAccessibilityRole(toggle != nil ? .checkBox : .button)
    setAccessibilityLabel(title)
    setAccessibilityEnabled(enabled)
    if let toggle { setAccessibilityValue(toggle.on) }
    if let expanded { setAccessibilityExpanded(expanded) }
    if case .check(let on) = m { setAccessibilitySelected(on) }
  }
  public required init?(coder: NSCoder) { fatalError() }

  public func setChecked(_ on: Bool) { mark.image = checkImage(on) }
  public func setDetail(_ text: String) { detailLabel.stringValue = text }
  override public func accessibilityPerformPress() -> Bool {
    onClick?()
    return onClick != nil
  }

  override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = track { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
    addTrackingArea(t)
    track = t
  }
  // Panels rebuild their rows on every change, and a fresh row only hears
  // mouseEntered once the pointer moves: pick up the hover it was born under,
  // so the highlight doesn't drop out under a resting pointer.
  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncHover()
  }

  /// Highlight exactly when the pointer is over the row now. Rows that slid
  /// under or out from under a resting pointer heard no enter or exit, so a
  /// panel calls this once its rows settle.
  public func syncHover() {
    guard let w = window else { return }
    hovered = bounds.contains(pointerInRow(w))
    applyHighlight()
  }

  /// The pointer in this row's coordinates, from where it is now: an event's
  /// own window location goes stale while the panel resizes under it.
  private func pointerInRow(_ w: NSWindow) -> NSPoint {
    convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
  }
  override public func mouseEntered(with event: NSEvent) {
    hovered = true
    applyHighlight()
  }
  override public func mouseExited(with event: NSEvent) {
    hovered = false
    applyHighlight()
  }
  // Same CGColor-snapshot problem as the scrim: repaint on an appearance flip.
  override public func viewDidChangeEffectiveAppearance() { applyHighlight() }

  // Liquid Glass highlights are colorless — a wash, not an accent-filled
  // slab, so the glass underneath still reads through. Light in Dark Mode, dark
  // in Light Mode.
  private func applyHighlight() {
    guard focused ?? hovered else {
      layer?.backgroundColor = NSColor.clear.cgColor
      return
    }
    // Light Mode's gray tint shows a dark wash far more than Dark Mode's black
    // shows a light one, so it's fainter there.
    let dark = isDark(effectiveAppearance)
    layer?.backgroundColor =
      (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.3 : 0.12).cgColor
  }
  // Act on the press. A panel resizes itself every frame while it animates, and
  // AppKit drops a release that comes in meanwhile, so a click acted on at
  // release couldn't interrupt an expand or collapse.
  override public func mouseDown(with event: NSEvent) { onClick?() }
}
