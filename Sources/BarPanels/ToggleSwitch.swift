// An on/off switch for panel rows. Checkmarks are for picking one of several
// options; a setting that is just on or off gets this. Drawn with layers rather
// than NSSwitch, which a non-key panel (all of ours) draws gray.

import AppKit

public final class ToggleSwitch: NSView {
  public static let size = NSSize(width: 28, height: 16)

  /// Last state shown per key, and when it last changed. Rows are rebuilt on
  /// every change, so a fresh switch starts where the previous one for the
  /// same setting was and slides; one rebuilt mid-slide carries on with it.
  private static var shown: [String: (on: Bool, from: Bool, changed: CFTimeInterval)] = [:]
  static let slideDuration: CFTimeInterval = 0.25

  private let track = CALayer()
  private let knob = CALayer()
  private let on: Bool
  /// The slide to run once on screen: from which state, and when it began.
  private var slide: (from: Bool, began: CFTimeInterval)?

  public init(key: String, on: Bool) {
    self.on = on
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    wantsLayer = true
    let h = Self.size.height
    track.frame = bounds
    track.cornerRadius = h / 2
    knob.bounds = NSRect(x: 0, y: 0, width: h - 4, height: h - 4)
    knob.cornerRadius = (h - 4) / 2
    knob.backgroundColor = NSColor.white.cgColor
    knob.shadowOpacity = 0.25
    knob.shadowRadius = 1
    knob.shadowOffset = CGSize(width: 0, height: -0.5)
    layer?.addSublayer(track)
    layer?.addSublayer(knob)

    let now = CACurrentMediaTime()
    let last = Self.shown[key]
    if let last, last.on != on {
      slide = (last.on, now)
      Self.shown[key] = (on, last.on, now)
    } else if let last, last.from != on, now - last.changed < Self.slideDuration {
      slide = (last.from, last.changed)  // rebuilt mid-slide
    } else {
      Self.shown[key] = (on, on, last?.changed ?? 0)
    }
    setFinal()
  }
  public required init?(coder: NSCoder) { fatalError() }

  // Animate only once in a window: before that, the starting state was never
  // drawn, so there'd be nothing on screen to slide from.
  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, let slide else { return }
    self.slide = nil
    let begin = slide.began
    let move = CABasicAnimation(keyPath: "position")
    move.fromValue = NSValue(point: knobCenter(slide.from))
    move.toValue = NSValue(point: knobCenter(on))
    let tint = CABasicAnimation(keyPath: "backgroundColor")
    tint.fromValue = trackColor(slide.from)
    tint.toValue = trackColor(on)
    for (layer, animation) in [(knob, move), (track, tint)] {
      animation.duration = Self.slideDuration
      animation.beginTime = begin  // in the past when carrying on a slide
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animation.fillMode = .backwards
      layer.add(animation, forKey: "slide")
    }
  }

  private func knobCenter(_ on: Bool) -> CGPoint {
    let h = Self.size.height
    return CGPoint(x: on ? Self.size.width - h / 2 : h / 2, y: h / 2)
  }

  private func trackColor(_ on: Bool) -> CGColor {
    // Resolve the dynamic colors against this view's appearance; outside
    // drawing, .cgColor would resolve against the light default.
    var c: CGColor = NSColor.clear.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      c = (on ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
    }
    return c
  }

  /// The model values: where the switch ends up, without animating there.
  private func setFinal() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    knob.position = knobCenter(on)
    track.backgroundColor = trackColor(on)
    CATransaction.commit()
  }

  override public func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    setFinal()
  }
}
