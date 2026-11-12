// A panel that drops down from a status-bar item, standing in for a menu:
// hidden from screen capture, opened under the item by a notification (an
// app's CLI posts it), closed on a click outside or a swallowed bar click. It
// lays its rows out top-down on glass and animates every change to them, and
// talks to a bundled helper over JSON lines. It takes the keyboard while
// open: arrows and Tab move focus over its rows and controls, Space and Return
// act, Escape closes.

import AppKit

/// From a status bar that swallows clicks on its items (sketchybar-hoverd does,
/// so they don't reveal the native menu bar): such a click never reaches the
/// panels' click-outside monitors, so it's announced here instead and closes
/// them the same way.
/// ponytail: still named for screenshare-ui, where the panels started; renamed
/// when this library is published.
public let BAR_CLICKED = Notification.Name("com.x.screenshare-ui.bar-clicked")

/// SCREENSHARE_UI_CAPTURABLE=1 lets screenshots and recordings see the menu
/// panels (the bar panels and the Screenshare Mode panel), to check their
/// layout and animations; otherwise they're hidden from capture like the rest.
public let menuPanelSharingType: NSWindow.SharingType =
  ProcessInfo.processInfo.environment["SCREENSHARE_UI_CAPTURABLE"] == "1" ? .readOnly : .none

/// SCREENSHARE_UI_DEMO=1: panels show fixed, made-up data (networks, outputs)
/// instead of the system's, and changes land after a short delay without
/// touching anything, so recordings of them are the same every time.
public let demoMode = ProcessInfo.processInfo.environment["SCREENSHARE_UI_DEMO"] == "1"

open class BarPanel: NSObject {
  public let panel: NSPanel = KeyPanel(
    contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: 40),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  /// Keyboard focus, by the key that identifies its view across rebuilds
  /// (see focusTargets()). Shown only once a key is pressed, and dropped as
  /// soon as the pointer moves, like a menu.
  private var focusKey: String?
  private var focusIndex = 0
  private var keyboardActive = false
  private let ring = FocusRing(frame: .zero)
  private var clickMonitor: Any?
  private var pressMonitor: Any?
  private var lastMonitorClose: Date?  // when a click outside last closed the panel
  /// Open from the user's point of view: set on the click, cleared on the click
  /// that closes it, while the panel itself may still be fading in or out.
  public private(set) var isOpen = false
  /// Bumped on every open and close, so a late animation completion or ready
  /// check from an earlier one doesn't act on the current one.
  private var generation = 0
  /// The glass and its scrim stay for the panel's life; content updates swap
  /// what's inside, so they can crossfade.
  private var host: PanelBackground?
  private var content: PanelContent?

  static let openDuration = 0.24
  static let closeDuration = 0.12
  static let fadeDuration = 0.18
  /// A content change moves the panel's edge on a damped spring, driven per
  /// frame: window resizes ignore custom timing curves, so a curve alone can't
  /// make them bounce. Rows moving down ride the same spring, so the ones
  /// below a change travel with the bottom edge; rows moving up stop at their
  /// place, so they don't run into the row above. Growing overshoots ~7%;
  /// shrinking is firmer (~1%).
  static let springOmega = 18.0
  static let growDamping = 0.65
  static let shrinkDamping = 0.82
  static let springLength = 0.6
  private var spring: Timer?
  /// The window's frame has one owner: it hangs at `hangX`/`hangTop` (under the
  /// bar item), `riseOffset` above that while it drops in on opening, and
  /// `shownHeight` tall. Opening animates only the offset and a content change
  /// only the height, each on its own timer, and both go through applyFrame(),
  /// so the two compose instead of overwriting each other's window frame.
  private var hangX: CGFloat = 0
  private var hangTop: CGFloat = 0
  private var riseOffset: CGFloat = 0
  private var shownHeight: CGFloat = 40
  private var rise: Timer?
  /// Content replaced by a change whose animation hasn't settled yet. Changes
  /// often come in bursts (AirPlay speakers are found one at a time), each
  /// cutting the last short: what it was fading out keeps fading from where it
  /// is, and all of it goes once the last change settles.
  private var retiring: [PanelContent] = []
  /// Where each content view was last put, by layout or by the spring. A panel
  /// may reuse a view across rebuilds (the Sound slider) and reset its frame
  /// while building, so its current frame says nothing about where it shows.
  private var placed: [ObjectIdentifier: NSPoint] = [:]
  /// How far above its place the panel starts as it fades in.
  static let openRise: CGFloat = 6
  /// How long an open waits for `isReady` before showing anyway.
  static let readyTimeout = 0.15

  /// `toggle` is the notification `screenshare-ui <panel> [x]` posts.
  public init(toggle: Notification.Name) {
    super.init()
    panel.sharingType = menuPanelSharingType
    panel.isFloatingPanel = true  // before .level: it resets the level to .floating
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true  // what sets a light panel apart from a white page
    panel.acceptsMouseMovedEvents = true
    (panel as? KeyPanel)?.owner = self

    DistributedNotificationCenter.default().addObserver(
      forName: toggle, object: nil, queue: .main
    ) { [weak self] note in
      let x = (note.object as? String).flatMap(Double.init).map { CGFloat($0) }
      self?.togglePanel(anchorX: x)
    }
    // A bar click the status bar swallowed, which the click monitor can't see.
    DistributedNotificationCenter.default().addObserver(
      forName: BAR_CLICKED, object: nil, queue: .main
    ) { [weak self] _ in self?.dismiss() }
  }

  // Subclass hooks.
  open func willOpen() {}
  open func didClose() {}
  open func buildContent() {}
  /// Whether there's enough to show yet: an open waits for this (briefly) so
  /// the panel doesn't appear half-empty and jump as its data lands.
  open var isReady: Bool { true }

  public func togglePanel(anchorX: CGFloat?) {
    if isOpen {
      closePanel()
      return
    }
    // Clicking the bar item to DISMISS also trips our global click monitor,
    // which closes the panel a beat before this toggle arrives. Don't
    // immediately reopen in that case.
    if let t = lastMonitorClose, Date().timeIntervalSince(t) < 0.3 {
      lastMonitorClose = nil
      return
    }
    openPanel(anchorX: anchorX)
  }

  public func openPanel(anchorX: CGFloat?) {
    isOpen = true
    generation += 1
    keyboardActive = false
    focusKey = nil
    let opening = generation
    willOpen()
    clickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in self?.dismiss() }
    // A press on a row runs it, found by where the pointer is now. AppKit sends
    // the second press of a double click to the view that took the first, and
    // that row has already been replaced by the change the first press made, so
    // a quick second click (collapsing what was just expanded) went nowhere.
    pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      guard let self, event.window === panel, let row = rowUnderPointer() else { return event }
      row.onClick?()
      return nil
    }
    let deadline = Date().addingTimeInterval(Self.readyTimeout)
    func presentWhenReady() {
      guard isOpen, generation == opening else { return }
      if isReady || Date() >= deadline {
        present(anchorX: anchorX)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { presentWhenReady() }
      }
    }
    presentWhenReady()
  }

  /// Fade in under the bar item, dropping the last few points into place.
  private func present(anchorX: CGFloat?) {
    content?.removeFromSuperview()
    content = nil  // a fresh open shows its content outright, not crossfaded
    buildContent()
    let scr = NSScreen.main ?? NSScreen.screens.first!
    var x = anchorX ?? (scr.frame.maxX - panel.frame.width - 8)
    // sketchybar reports the item's x in device pixels on a retina display.
    if x > scr.frame.width { x /= scr.backingScaleFactor }
    x = min(max(scr.frame.minX + 4, x), scr.frame.maxX - panel.frame.width - 4)
    hangX = x
    hangTop = scr.visibleFrame.maxY - 2
    riseOffset = Self.openRise
    applyFrame()
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    // Key, without activating the app: keys come here, not to the app behind.
    panel.makeKey()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.openDuration
      panel.animator().alphaValue = 1
    }
    rise?.invalidate()
    let began = Date()
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let elapsed = Date().timeIntervalSince(began)
      let done = elapsed >= Self.openDuration * 2
      riseOffset =
        done ? 0 : Self.openRise * (1 - Self.springProgress(elapsed, damping: Self.growDamping))
      applyFrame()
      if done {
        timer.invalidate()
        rise = nil
      }
    }
    RunLoop.main.add(t, forMode: .common)
    rise = t
  }

  /// Put the window where it hangs, at its height, snapped to the pixel grid.
  private func applyFrame() {
    let scale = panel.backingScaleFactor
    let height = (shownHeight * scale).rounded() / scale
    panel.setFrame(
      NSRect(x: hangX, y: hangTop + riseOffset - height, width: PANEL_W, height: height),
      display: true)
    panel.invalidateShadow()  // a clear window's shadow follows its drawn shape
  }

  /// A click elsewhere: close, and remember it so the toggle the same click
  /// may be about to send doesn't reopen us.
  private func dismiss() {
    guard isOpen else { return }
    lastMonitorClose = Date()
    closePanel()
  }

  public func closePanel() {
    isOpen = false
    generation += 1
    let closing = generation
    for m in [clickMonitor, pressMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
    clickMonitor = nil
    pressMonitor = nil
    keyboardActive = false
    didClose()
    guard panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.closeDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      // Reopened meanwhile: that open owns the panel now.
      guard let self, generation == closing else { return }
      panel.orderOut(nil)
      panel.alphaValue = 1
    }
  }

  /// The row under the pointer in what's shown now (hidden rows, stood in for
  /// by their successors, don't count).
  private func rowUnderPointer() -> HoverRow? {
    guard let root = panel.contentView else { return nil }
    let p = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
    var v = root.hitTest(root.superview?.convert(p, from: nil) ?? p)
    while let view = v, !(view is HoverRow) { v = view.superview }
    return v as? HoverRow
  }

  // MARK: Keyboard

  /// A key pressed while the panel is open; true if it was handled. Arrows and
  /// Tab move focus, Space and Return act on it, right and left open and
  /// close a focused disclosure row or nudge a focused slider, Escape and ⌘W
  /// close. Panels can override to add keys,
  /// calling super for the rest.
  open func handleKey(_ e: NSEvent) -> Bool {
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 53: closePanel()  // Escape
    case 13 where e.modifierFlags.contains(.command): closePanel()  // ⌘W
    case 48: moveFocus(shift ? -1 : 1)  // Tab
    case 125: moveFocus(1)  // down
    case 126: moveFocus(-1)  // up
    case 49, 36, 76:  // Space, Return, Enter
      guard keyboardActive, let v = focusedView() else { return false }
      activate(v)
    case 123, 124:  // left, right
      let right = e.keyCode == 124
      guard keyboardActive else { return false }
      switch focusedView() {
      case let row as HoverRow where row.expanded == !right:
        row.onClick?()
      case let s as NSSlider:
        s.doubleValue += (s.maxValue - s.minValue) / 20 * (right ? 1 : -1)
        s.sendAction(s.action, to: s.target)
      default: return false
      }
    default: return false
    }
    return true
  }

  /// Show keyboard focus on `view` (a row, or a control inside one), as if
  /// it had been reached with the arrows; nil drops it.
  public func setKeyboardFocus(_ view: NSView?) {
    let target = view.flatMap { v in focusTargets().first { $0.view === v } }
    keyboardActive = target != nil
    focusKey = target?.key
    showFocus()
  }

  /// The pointer moved or pressed: it drives the panel again.
  fileprivate func pointerTookOver() {
    guard keyboardActive else { return }
    keyboardActive = false
    showFocus()
    content?.rows.compactMap { $0 as? HoverRow }.forEach { $0.syncHover() }
  }

  /// What can take focus in the current content, top to bottom: rows that do
  /// something, and enabled controls inside the other views. Each is keyed by
  /// its row's key (stable across rebuilds), plus its place within the row.
  private func focusTargets() -> [(key: String, view: NSView)] {
    guard let content else { return [] }
    var out: [(String, NSView)] = []
    for (key, view, _) in Self.keyed(content.rows) where !view.isHidden {
      if let row = view as? HoverRow {
        if row.isEnabled, row.onClick != nil { out.append((key, row)) }
        continue
      }
      var controls: [NSControl] = []
      func visit(_ v: NSView) {
        if let c = v as? NSControl, !(c is NSTextField), !(c is NSLevelIndicator) {
          if c.isEnabled, !c.isHiddenOrHasHiddenAncestor { controls.append(c) }
          return
        }
        v.subviews.forEach(visit)
      }
      visit(view)
      // Reading order within the view: top to bottom, then left to right.
      let frame = { (c: NSControl) in c.convert(c.bounds, to: view) }
      controls.sort { a, b in
        let fa = frame(a)
        let fb = frame(b)
        return abs(fa.midY - fb.midY) < 6
          ? fa.minX < fb.minX : (fa.midY < fb.midY) == view.isFlipped
      }
      for (i, c) in controls.enumerated() { out.append(("\(key)/\(i)", c)) }
    }
    return out
  }

  private func focusedView() -> NSView? {
    focusTargets().first { $0.key == focusKey }?.view
  }

  private func moveFocus(_ step: Int) {
    let targets = focusTargets()
    guard !targets.isEmpty else { return }
    let current =
      targets.firstIndex { $0.key == focusKey }
      // Gone in a rebuild: carry on from where it was.
      ?? (focusKey == nil ? nil : min(focusIndex, targets.count - 1) - (step > 0 ? 1 : 0))
    let next: Int
    if keyboardActive, let current {
      next = (current + step + targets.count) % targets.count
    } else {
      // The first key press shows focus: on the row under the pointer if
      // there is one, else at the top or bottom.
      let hovered = rowUnderPointer().flatMap { row in targets.firstIndex { $0.view === row } }
      next = hovered ?? (step > 0 ? 0 : targets.count - 1)
    }
    focusKey = targets[next].key
    keyboardActive = true
    showFocus()
    NSAccessibility.post(element: targets[next].view, notification: .focusedUIElementChanged)
  }

  private func activate(_ v: NSView) {
    switch v {
    case let row as HoverRow: row.onClick?()
    case let s as NSSwitch:
      s.state = s.state == .on ? .off : .on
      s.sendAction(s.action, to: s.target)
    case let c as NSControl: c.performClick(nil)  // buttons, checkboxes, popups
    default: break
    }
  }

  /// Highlight the focused row or ring the focused control; while the
  /// pointer drives the panel, rows go back to following it.
  private func showFocus() {
    let targets = focusTargets()
    let i = keyboardActive ? targets.firstIndex { $0.key == focusKey } : nil
    if let i { focusIndex = i }
    let focused = i.map { targets[$0].view }
    for row in content?.rows.compactMap({ $0 as? HoverRow }) ?? [] {
      row.focused = keyboardActive ? row === focused : nil
    }
    if let control = focused, !(control is HoverRow), let host = ring.superview {
      ring.show(around: control, in: host)
    } else {
      ring.isHidden = true
    }
  }

  // MARK: Content

  public static func title(_ text: String) -> NSTextField {
    let t = NSTextField(labelWithString: text)
    t.font = .systemFont(ofSize: 13, weight: .semibold)
    t.textColor = .labelColor
    t.frame = NSRect(x: 0, y: 0, width: PANEL_W - 28, height: ROW_H)
    return t
  }

  public static func sectionTitle(_ text: String) -> NSTextField {
    let t = NSTextField(labelWithString: text)
    t.font = .systemFont(ofSize: 11, weight: .semibold)
    t.textColor = SECONDARY_TEXT
    t.frame = NSRect(x: 0, y: 0, width: PANEL_W - 28, height: ROW_H)
    return t
  }

  /// A title with a secondary value on the right ("Battery    77%").
  public static func title(_ text: String, detail: String) -> NSView {
    let v = NSView(frame: NSRect(x: 0, y: 0, width: PANEL_W - 28, height: ROW_H))
    let t = title(text)
    v.addSubview(t)
    let d = NSTextField(labelWithString: detail)
    d.font = .systemFont(ofSize: 13)
    d.textColor = SECONDARY_TEXT
    d.alignment = .right
    d.frame = v.bounds
    v.addSubview(d)
    return v
  }

  /// Lay `items` out top-down and show them on the glass. Rows span the
  /// panel's padding; `inset` views (titles, sliders) line up with the text
  /// inside the rows. Separators (NSBox) get a SEP_H slot; everything else
  /// its own height (ROW_H for rows and titles, more for a wrapping note).
  ///
  /// On an open panel the change animates like a list: rows are matched to the
  /// previous content by what they say, so a kept row slides from its old place
  /// to its new one, a new row fades in where it lands and a gone one fades out
  /// where it was, while the panel resizes with its top edge under the bar.
  /// The last `footer` items (a separator and a settings row) travel with the
  /// panel's bottom edge, and the rows above are cut off where they start.
  public func show(_ items: [NSView], inset: [NSView] = [], footer: Int = 0) {
    // Before anything is re-parented: a view shown before and again now (the
    // Sound slider) moves into the new content below.
    let before = ((content?.rows).map(Self.keyed) ?? []).map { entry in
      var frame = entry.frame
      if let at = placed[ObjectIdentifier(entry.view)] { frame.origin = at }
      return (key: entry.key, view: entry.view, frame: frame)
    }
    placed = [:]

    let insetIDs = Set(inset.map(ObjectIdentifier.init))
    let slot = { (v: NSView) in v is NSBox ? SEP_H : v.frame.height > 0 ? v.frame.height : ROW_H }
    let height = PANEL_PAD * 2 + items.reduce(0) { $0 + slot($1) }
    let next = PanelContent(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: height))
    let bodyCount = items.count - footer
    var y = PANEL_PAD
    for (i, v) in items.enumerated() {
      let sep = v is NSBox
      let at = NSPoint(
        x: insetIDs.contains(ObjectIdentifier(v)) ? INSET_X : PANEL_PAD,
        y: sep ? y + (SEP_H - 1) / 2 : y)
      if i == bodyCount { next.footerTop = y }
      v.setFrameOrigin(at)
      placed[ObjectIdentifier(v)] = at
      if i < bodyCount {
        next.body.addSubview(v)
      } else {
        next.addSubview(v)
        next.footer.append(v)
      }
      y += slot(v)
    }
    if footer == 0 { next.footerTop = height }
    next.setEdge(next.footerTop)

    let host = hostView(height: height)
    host.addSubview(next)
    host.addSubview(ring)  // over the content
    let previous = content
    content = next

    guard let previous, panel.isVisible else {
      previous?.removeFromSuperview()
      shownHeight = height
      applyFrame()
      showFocus()
      return
    }

    var was = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var moves: [(NSView, NSPoint, NSPoint)] = []
    // Every fade starts from the opacity on screen now, so a row that was
    // mid-fade when this change cut in carries on rather than popping.
    var fadeIn: [(NSView, CGFloat)] = []
    for (key, view, _) in Self.keyed(next.rows) {
      if let old = was.removeValue(forKey: key) {
        moves.append((view, old.frame.origin, view.frame.origin))
        view.setFrameOrigin(old.frame.origin)
        placed[ObjectIdentifier(view)] = old.frame.origin
        if old.view !== view {
          view.alphaValue = old.view.alphaValue
          old.view.isHidden = true  // its successor stands in
        }
        if view.alphaValue < 1 { fadeIn.append((view, view.alphaValue)) }
      } else {
        view.alphaValue = 0
        fadeIn.append((view, 0))
      }
    }
    retiring.append(previous)
    let fadeOut: [(NSView, CGFloat)] = retiring.flatMap(\.rows)
      .filter { !$0.isHidden && $0.alphaValue > 0 }
      .map { ($0, $0.alphaValue) }
    // The footer's top edge, where its separator's slot starts, as it moves.
    let separator = next.footer.first
    let edge = {
      separator.map { $0.frame.minY - (SEP_H - 1) / 2 } ?? next.footerTop
    }
    // Where the edge starts, before the first frame draws: laid out, the new
    // content's edge is already at its end.
    next.setEdge(edge())
    retiring.forEach { $0.setEdge(edge()) }

    let from = shownHeight
    runSpring(
      damping: height >= from ? Self.growDamping : Self.shrinkDamping,
      { p, fade in
        let lerp = { (a: CGFloat, b: CGFloat, t: CGFloat) in a + (b - a) * t }
        self.shownHeight = lerp(from, height, p)
        self.applyFrame()
        for (view, start, to) in moves {
          // Down, a row rides the edge's bounce; up, it stops at its place, so
          // the footer coming up on a collapse never runs into the row above.
          let t = to.y < start.y ? min(p, 1) : p
          let at = NSPoint(x: lerp(start.x, to.x, t), y: lerp(start.y, to.y, t))
          view.setFrameOrigin(at)
          self.placed[ObjectIdentifier(view)] = at
        }
        for (view, from) in fadeIn { view.alphaValue = from + (1 - from) * fade }
        for (view, from) in fadeOut { view.alphaValue = from * (1 - fade) }
        let e = edge()
        next.setEdge(e)
        self.retiring.forEach { $0.setEdge(e) }
        self.showFocus()
      },
      settled: { [weak self] in
        guard let self else { return }
        retiring.forEach { $0.removeFromSuperview() }
        retiring = []
        content.map { $0.setEdge($0.footerTop) }
        content?.rows.compactMap { $0 as? HoverRow }.forEach { $0.syncHover() }
        showFocus()
      })
    showFocus()
  }

  /// Damped-spring progress at `t` seconds: 0 → 1, overshooting a little.
  private static func springProgress(_ t: Double, damping z: Double) -> CGFloat {
    let w = springOmega
    let wd = w * (1 - z * z).squareRoot()
    return CGFloat(1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t)))
  }

  /// Run `step(progress, fade)` every frame until the spring settles, then
  /// `settled`. A new change cuts the running one short and starts from
  /// wherever things are, so nothing jumps; only the last one settles.
  private func runSpring(
    damping: Double, _ step: @escaping (CGFloat, CGFloat) -> Void,
    settled: @escaping () -> Void
  ) {
    spring?.invalidate()
    let began = Date()
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let elapsed = Date().timeIntervalSince(began)
      let done = elapsed >= Self.springLength
      step(
        done ? 1 : Self.springProgress(elapsed, damping: damping),
        CGFloat(min(1, elapsed / Self.fadeDuration)))
      if done {
        timer.invalidate()
        spring = nil
        settled()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    spring = t
  }

  /// Each view with what identifies it across rebuilds: a row's or label's
  /// text, its kind otherwise, numbered when the same one repeats (separators).
  private static func keyed(_ views: [NSView]) -> [(key: String, view: NSView, frame: NSRect)] {
    var seen: [String: Int] = [:]
    return views.map { v in
      let base: String
      switch v {
      case _ where v.identifier != nil: base = "id:\(v.identifier!.rawValue)"
      case let row as HoverRow: base = "row:\(row.title)"
      case let text as NSTextField: base = "text:\(text.stringValue)"
      case is NSBox: base = "separator"
      case is NSSlider: base = "slider"
      default:
        let text = v.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
        base = "view:\(text)"
      }
      seen[base, default: 0] += 1
      return ("\(base)#\(seen[base]!)", v, v.frame)
    }
  }

  /// The glass and scrim, made once and then resized with the panel.
  private func hostView(height: CGFloat) -> PanelBackground {
    if let host { return host }
    let frame = NSRect(x: 0, y: 0, width: PANEL_W, height: height)
    let h = PanelBackground(frame: frame)
    h.autoresizingMask = [.width, .height]
    let glass = glassBackdrop(frame, h)
    glass.autoresizingMask = [.width, .height]
    shownHeight = height
    panel.contentView = glass  // h keeps the glass softened (see PanelBackground)
    host = h
    return h
  }

  public static func openSettings(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
  }
}

/// Top-down layout for panel content, like PanelBackground.
open class FlippedView: NSView {
  override open var isFlipped: Bool { true }
}

/// One version of a panel's content: the body rows, and the footer rows (a
/// separator and a settings row) under them. The body is cut off at the
/// footer's top edge, so nothing draws past that line while it moves.
final class PanelContent: FlippedView {
  let body = FlippedView()
  var footer: [NSView] = []
  /// Where the footer starts once laid out (the bottom, without one).
  var footerTop: CGFloat = 0

  var rows: [NSView] { body.subviews + footer }

  override init(frame: NSRect) {
    super.init(frame: frame)
    body.frame = bounds
    body.wantsLayer = true
    body.layer?.masksToBounds = true
    addSubview(body)
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Cut the body off at `edge`, in this view's top-down coordinates.
  func setEdge(_ edge: CGFloat) {
    body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, edge))
  }
}

/// A bundled helper (Contents/Helpers/<name>) that reports state as one JSON
/// line per change on stdout and takes commands on stdin; it exits when its
/// stdin closes, so `stop()` ends it.
public final class HelperProcess {
  public init() {}

  private var process: Process?
  private var input: FileHandle?

  public static func url(_ name: String) -> URL? {
    let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(name)")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  /// Start it unless running; `onLine` gets each stdout line on the main queue.
  public func start(_ name: String, _ arguments: [String], onLine: @escaping (Data) -> Void) {
    guard process == nil, let url = Self.url(name) else { return }
    let p = Process()
    p.executableURL = url
    p.arguments = arguments
    let stdin = Pipe()
    let stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    var buffer = Data()
    stdout.fileHandleForReading.readabilityHandler = { h in
      let chunk = h.availableData
      guard !chunk.isEmpty else {
        h.readabilityHandler = nil
        return
      }
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<nl])
        buffer.removeSubrange(buffer.startIndex...nl)
        DispatchQueue.main.async { onLine(line) }
      }
    }
    do {
      try p.run()
      process = p
      input = stdin.fileHandleForWriting
    } catch {
      FileHandle.standardError.write(
        "screenshare-ui: \(name) failed: \(error)\n".data(using: .utf8)!)
    }
  }

  public func send(_ command: String) {
    input?.write((command + "\n").data(using: .utf8)!)
  }

  public func stop() {
    try? input?.close()
    input = nil
    process = nil
  }

  /// Run a one-shot helper command; `done` gets its exit status on the main queue.
  public static func run(_ name: String, _ arguments: [String], done: @escaping (Int32) -> Void) {
    guard let url = url(name) else { return done(-1) }
    let p = Process()
    p.executableURL = url
    p.arguments = arguments
    p.terminationHandler = { p in DispatchQueue.main.async { done(p.terminationStatus) } }
    do { try p.run() } catch { done(-1) }
  }
}

/// The panel's window: it can take the keyboard (a borderless panel can't by
/// default) and hands keys to its BarPanel before the views see them.
final class KeyPanel: NSPanel {
  weak var owner: BarPanel?
  override var canBecomeKey: Bool { true }
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .keyDown where owner?.handleKey(event) == true: return
    case .mouseMoved, .leftMouseDown, .rightMouseDown: owner?.pointerTookOver()
    default: break
    }
    super.sendEvent(event)
  }
}
