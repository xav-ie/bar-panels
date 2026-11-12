// The look shared by the panels: sizes, the scrim behind the rows, the glass
// backdrop, and the small helpers rows use.

import AppKit

public let PANEL_W: CGFloat = 280
public let PANEL_RADIUS: CGFloat = 16
public let PANEL_PAD: CGFloat = 6
public let ROW_W = PANEL_W - PANEL_PAD * 2
public let ROW_H: CGFloat = 24
public let SEP_H: CGFloat = 9
/// Where titles, sliders and notes start and how wide they run: in line with
/// the text inside the rows.
public let INSET_X: CGFloat = 14
public let INSET_W = PANEL_W - INSET_X * 2

/// Text and glyphs that are secondary (section titles, notes, values,
/// chevrons). The system's secondary gray all but vanishes on glass, so it's
/// the label color, dimmed, resolved for whichever appearance draws it.
public let SECONDARY_TEXT = NSColor(name: "BarPanelsSecondaryText") { appearance in
  (isDark(appearance) ? NSColor.white : NSColor.black).withAlphaComponent(0.65)
}

// Outside of drawing, .cgColor resolves against NSAppearance.current, which here
// is the light default no matter what the panel is actually showing — so resolve
// the appearance explicitly instead of leaning on dynamic colors.
public func isDark(_ appearance: NSAppearance) -> Bool {
  appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

public func checkImage(_ on: Bool) -> NSImage? {
  on ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
}

public func separatorBox() -> NSBox {
  let v = NSBox(frame: NSRect(x: 0, y: 0, width: ROW_W, height: 1))
  v.boxType = .separator
  return v
}

// Top-down layout so the app list reads like a menu, plus the scrim behind the
// rows: .clear glass alone leaves label text unreadable over a bright app behind
// the panel. tintColor can't fix it (it lightens, never darkens), so this puts a
// translucent wash between the glass and the rows — dark and see-through like a
// notification banner, glass edge and refraction intact. It follows the system
// appearance so it stays behind whatever labelColor resolves to.
public final class PanelBackground: NSView {
  override public var isFlipped: Bool { true }

  override public init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = PANEL_RADIUS
    layer?.masksToBounds = true
    applyScrim()
  }
  public required init?(coder: NSCoder) { fatalError() }

  // A CGColor is a snapshot, so unlike the labels it won't restyle itself when
  // the system flips between Light and Dark. Re-resolve it when told to.
  override public func viewDidChangeEffectiveAppearance() { applyScrim() }

  // The glass rebuilds its material, and with it the stock settings, when
  // it's first displayed, on every resize, key change and appearance flip.
  // So every display cycle, after AppKit has laid out and drawn and before
  // Core Animation commits the frame, put ours back if they're gone: the
  // frame on screen never shows the stock ones.
  private var glassGuard: CFRunLoopObserver?
  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let glassGuard { CFRunLoopRemoveObserver(CFRunLoopGetMain(), glassGuard, .commonModes) }
    glassGuard = nil
    guard window != nil else { return }
    // Core Animation commits at order 2,000,000; AppKit's display cycle runs
    // just before it.
    let observer = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999
    ) { [weak self] _, _ in
      // The glass IS the window's contentView; its backdrop layer is a sibling
      // of ours, not an ancestor, so patch from the top of the tree.
      guard let window = self?.window, window.isVisible, let glass = window.contentView else {
        return
      }
      tuneGlass(glass)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    glassGuard = observer
  }

  private func applyScrim() {
    // Soft grays rather than black and white, so over a page of the same shade
    // the panel still reads as a panel rather than a blank patch of the page.
    let scrim = NSColor(white: isDark(effectiveAppearance) ? 0.15 : 0.85, alpha: 1)
    layer?.backgroundColor = scrim.withAlphaComponent(0.65).cgColor
  }
}

// The glass's own settings for what shows through it (picked side by side
// over a dark terminal and a bright page): blurred enough that text behind the
// panel turns to soft shapes, and a little more saturated than stock so the
// colors behind still read as glass under the tint.
public let GLASS_BLUR = 6.0
public let GLASS_SATURATION = 1.4

// Stock glass blurs the backdrop at inputBlurRadius 10 (on a half-scale
// backdrop) while its window isn't key, which smears whatever is behind the
// panel into mush, and at 0.75 while it is, which leaves it plain to read
// through the panel's rows. Nothing on NSGlassEffectView exposes either
// setting, so we reach into its layer tree and rebuild the private
// `glassBackground` CAFilter with ours, copying every other input verbatim.
// Mutating the committed filter in place does nothing (it's already handed to
// the render server) — it has to be built fresh and reassigned.
// ponytail: private CoreAnimation API; a macOS update can rename the filter or
// its inputs. It fails soft — no filter found means stock glass, nothing worse.
/// Cheap when the settings are already ours. Returns whether there was a glass
/// filter.
@discardableResult
public func tuneGlass(_ view: NSView) -> Bool {
  let ours: [String: Double] = [
    "inputBlurRadius": GLASS_BLUR, "inputFaceColorMatrixSaturation": GLASS_SATURATION,
  ]
  guard let root = view.layer,
    let filterClass = NSClassFromString("CAFilter") as? NSObject.Type
  else { return false }

  var found = false
  func visit(_ layer: CALayer) {
    defer { layer.sublayers?.forEach(visit) }
    guard String(describing: type(of: layer)) == "CABackdropLayer",
      let filters = (layer as NSObject).value(forKey: "filters") as? [NSObject]
    else { return }
    var rebuilt: [NSObject] = []
    for filter in filters {
      if "\(filter)" == "glassBackground",
        ours.allSatisfy({ filter.value(forKey: $0.key) as? Double == $0.value })
      {
        found = true  // already ours: nothing to rebuild
        return
      }
      guard "\(filter)" == "glassBackground",
        let fresh = (filterClass as AnyObject).perform(
          NSSelectorFromString("filterWithName:"), with: "glassBackground")?
          .takeUnretainedValue() as? NSObject,
        let inputs = filter.perform(NSSelectorFromString("inputKeys"))?
          .takeUnretainedValue() as? [String]
      else {
        rebuilt.append(filter)
        continue
      }
      for key in inputs where ours[key] == nil {
        if let v = filter.value(forKey: key) { fresh.setValue(v, forKey: key) }
      }
      for (key, value) in ours { fresh.setValue(value, forKey: key) }
      rebuilt.append(fresh)
      found = true
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    (layer as NSObject).setValue(rebuilt, forKey: "filters")
    CATransaction.commit()
  }
  visit(root)
  return found
}

// Liquid Glass (macOS 26 NSGlassEffectView), resolved at RUNTIME: the nixpkgs
// Swift SDK predates the class, so we can't name it at compile time. Falls
// back to the old vibrancy material on anything older.
//
// style 1 = .clear. The default (.regular, 0) lays a heavy scrim over the
// backdrop and reads like plain vibrancy; .clear lets the colors behind
// actually come through. Verified side by side against a test pattern.
public func glassBackdrop(_ frame: NSRect, _ content: NSView) -> NSView {
  if let cls = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
    let glass = cls.init() as? NSView
  {
    glass.frame = frame
    glass.setValue(1, forKey: "style")
    glass.setValue(PANEL_RADIUS, forKey: "cornerRadius")
    glass.setValue(content, forKey: "contentView")
    return glass
  }
  let vev = NSVisualEffectView(frame: frame)
  vev.material = .menu
  vev.state = .active
  vev.blendingMode = .behindWindow
  vev.wantsLayer = true
  vev.layer?.cornerRadius = 8
  vev.layer?.masksToBounds = true
  vev.addSubview(content)
  return vev
}

/// Secondary text that wraps across the panel, sized to fit, for a status
/// line or an explanation under a row.
public func note(_ text: String) -> NSTextField {
  let t = NSTextField(wrappingLabelWithString: text)
  t.font = .systemFont(ofSize: 11)
  t.textColor = SECONDARY_TEXT
  t.preferredMaxLayoutWidth = INSET_W
  let h = t.sizeThatFits(NSSize(width: INSET_W, height: .greatestFiniteMagnitude)).height
  t.frame = NSRect(x: 0, y: 0, width: INSET_W, height: (h + 6).rounded(.up))
  return t
}

/// A panel draws a slider's fill gray whenever it isn't key (as it fades out,
/// say), and trackFillColor doesn't change that, so draw the bar ourselves: the
/// system accent up to the knob, at the stock track's size. The knob is still
/// AppKit's.
public final class AccentSliderCell: NSSliderCell {
  override public func drawBar(inside rect: NSRect, flipped: Bool) {
    let h: CGFloat = 6
    let bar = NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
    var fill = bar
    fill.size.width = max(h, bar.width * CGFloat((doubleValue - minValue) / (maxValue - minValue)))
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()
  }
}

/// A slider in the panels' look (see AccentSliderCell).
public func accentSlider(
  value: Double, min: Double, max: Double, target: AnyObject?, action: Selector?
) -> NSSlider {
  let s = NSSlider()
  s.cell = AccentSliderCell()  // before the rest: a new cell starts from defaults
  s.minValue = min
  s.maxValue = max
  s.doubleValue = value
  s.target = target
  s.action = action
  return s
}
