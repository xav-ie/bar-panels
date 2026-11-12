// bar-panels-previews <dir>: the README's pictures, drawn by the library itself.
//
// Each sample panel is built with the real BarPanel, HoverRow and ToggleSwitch,
// shown over a mock desktop (glass shows what's behind it, and captured on its
// own it would come out flat), captured with screencapture, and cut back out
// along its rounded corners as <dir>/<name>.png. screencapture only sees what's
// on screen, so each sample flashes in the screen's bottom-left corner.

import AppKit
import BarPanels

/// A panel whose content is whatever the sample builds.
final class Sample: BarPanel {
  var rows: (Sample) -> (items: [NSView], inset: [NSView], footer: Int) = { _ in ([], [], 0) }
  override func buildContent() {
    let content = rows(self)
    show(content.items, inset: content.inset, footer: content.footer)
  }
}

func symbol(_ name: String) -> NSImage? {
  NSImage(systemSymbolName: name, accessibilityDescription: nil)
}

func action(_ row: HoverRow) -> HoverRow {
  row.onClick = {}  // a row that does something, so keyboard focus can land on it
  return row
}

/// A Wi-Fi menu: a title switch, checkmark rows with icons and locks, a
/// section, a disclosure row and a settings footer.
func wifi(expanded: Bool) -> (Sample) -> ([NSView], [NSView], Int) {
  { _ in
    let known = BarPanel.sectionTitle("Known Networks")
    let hotspot = BarPanel.sectionTitle("Personal Hotspot")
    var items: [NSView] = [
      action(HoverRow("Wi-Fi", toggle: ("preview.wifi", true), title: true)),
      separatorBox(), known,
      action(
        HoverRow("Home", icon: symbol("wifi"), mark: .check(true), accessory: symbol("lock.fill"))),
      action(
        HoverRow(
          "Office", icon: symbol("wifi"), mark: .check(false), accessory: symbol("lock.fill"))),
      hotspot,
      action(HoverRow("Phone", icon: symbol("personalhotspot"), mark: .check(false))),
      separatorBox(),
      action(HoverRow("Other Networks", expanded: expanded)),
    ]
    if expanded {
      items += [
        action(HoverRow("Café Guest", icon: symbol("wifi"), mark: .check(false))),
        action(
          HoverRow(
            "Library", icon: symbol("wifi.exclamationmark"), mark: .check(false),
            accessory: symbol("lock.fill"))),
      ]
    }
    items += [separatorBox(), action(HoverRow("Wi-Fi Settings…"))]
    return (items, [known, hotspot], 2)
  }
}

/// A Sound menu: a title, an accent slider, checkmark rows, a pending switch
/// (a spinner) and a settings footer.
func sound(_: Sample) -> ([NSView], [NSView], Int) {
  let title = BarPanel.title("Sound")
  let slider = accentSlider(value: 0.6, min: 0, max: 1, target: nil, action: nil)
  slider.frame = NSRect(x: 0, y: 0, width: INSET_W, height: ROW_H)
  let output = BarPanel.sectionTitle("Output")
  let items: [NSView] = [
    title, slider, separatorBox(), output,
    action(HoverRow("MacBook Pro Speakers", icon: symbol("laptopcomputer"), mark: .check(true))),
    action(HoverRow("Headphones", icon: symbol("headphones"), mark: .check(false))),
    action(HoverRow("Living Room", icon: symbol("airplayaudio"), mark: .busy)),
    note("Switching to Living Room…"),
    separatorBox(), action(HoverRow("Sound Settings…")),
  ]
  return (items, [title, slider, output, items[7]], 2)
}

/// The mock desktop behind a sample: a soft gradient in the sample's appearance.
final class Desktop: NSView {
  var dark = true
  override func draw(_ dirtyRect: NSRect) {
    let (a, b) =
      dark
      ? (
        NSColor(srgbRed: 0.23, green: 0.25, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
      )
      : (
        NSColor(srgbRed: 0.91, green: 0.93, blue: 0.97, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.80, blue: 0.88, alpha: 1)
      )
    NSGradient(colors: [a, b])?.draw(in: bounds, relativeCenterPosition: NSPoint(x: -0.6, y: 0.8))
  }
}

func capture(_ panel: NSPanel, to path: String) {
  let frame = panel.frame
  // screencapture's -R is in points from the top left of the main screen.
  let top = NSScreen.screens[0].frame.maxY - frame.maxY
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  p.arguments = [
    "-x", "-R", "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", path,
  ]
  try? p.run()
  p.waitUntilExit()
  roundCorners(path, radius: PANEL_RADIUS * panel.backingScaleFactor)
}

/// Make everything outside the panel's rounded rectangle transparent.
func roundCorners(_ path: String, radius: CGFloat) {
  let url = URL(fileURLWithPath: path) as CFURL
  guard
    let image = CGImageSourceCreateWithURL(url, nil).flatMap({
      CGImageSourceCreateImageAtIndex($0, 0, nil)
    }),
    let ctx = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return }
  let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
  ctx.clip()
  ctx.draw(image, in: rect)
  guard let out = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(dest, out, nil)
  CGImageDestinationFinalize(dest)
}

/// Extend each image downward with transparency to the tallest one's height.
func padToTallest(_ paths: [String]) {
  let images = paths.map { path in
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap {
      CGImageSourceCreateImageAtIndex($0, 0, nil)
    }
  }
  let height = images.compactMap { $0?.height }.max() ?? 0
  for (path, image) in zip(paths, images) {
    guard let image, image.height < height,
      let ctx = CGContext(
        data: nil, width: image.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    // CoreGraphics' origin is the bottom left: the image goes at the top.
    ctx.draw(
      image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
    guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
  }
}

let dir = CommandLine.arguments.dropFirst().first ?? "."
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let desktop = Desktop()
let backdrop = NSWindow(
  contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
backdrop.contentView = desktop
backdrop.level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)

let samples:
  [(name: String, dark: Bool, rows: (Sample) -> ([NSView], [NSView], Int), focus: String?)] = [
    ("wifi-dark", true, wifi(expanded: false), nil),
    ("wifi-light", false, wifi(expanded: false), nil),
    ("sound-dark", true, sound, nil),
    ("sound-light", false, sound, nil),
    ("keyboard", true, wifi(expanded: true), "Other Networks"),
  ]
for s in samples {
  let panel = Sample(toggle: Notification.Name("bar-panels.previews"))
  panel.panel.sharingType = .readOnly  // panels hide from capture by default
  panel.panel.appearance = NSAppearance(named: s.dark ? .darkAqua : .aqua)
  panel.rows = { s.rows($0) }
  panel.buildContent()
  if let focus = s.focus {
    func find(_ v: NSView) -> HoverRow? {
      (v as? HoverRow).flatMap { $0.title == focus ? $0 : nil }
        ?? v.subviews.lazy.compactMap(find).first
    }
    panel.setKeyboardFocus(panel.panel.contentView.flatMap(find))
  }
  panel.panel.setFrameOrigin(NSPoint(x: 40, y: 80))
  desktop.dark = s.dark
  desktop.needsDisplay = true
  backdrop.setFrame(panel.panel.frame.insetBy(dx: -40, dy: -40), display: true)
  backdrop.orderFrontRegardless()
  panel.panel.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(0.8))
  capture(panel.panel, to: "\(dir)/\(s.name).png")
  panel.panel.orderOut(nil)
}
backdrop.orderOut(nil)
// The README shows Wi-Fi and Sound side by side, and lines images up at their
// bottoms: as tall as each other, they line up at the top too.
padToTallest(["wifi-dark", "wifi-light", "sound-dark", "sound-light"].map { "\(dir)/\($0).png" })
