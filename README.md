# BarPanels

Drop-down panels for status-bar items (sketchybar), standing in for menus: a
`BarPanel` opens under its item when its app's CLI posts a notification, is
hidden from screen capture, closes on a click outside or a swallowed bar click,
and animates every change to its rows (list-matched slides and fades, a damped
spring on its height, a footer clipping the list above it).

Local for now; used by screenshare-ui and virtual-headset.

Build: `callPackage ./default.nix { }` (or the flake's overlay) gives
`lib/libBarPanels.a` and `lib/BarPanels.swiftmodule`; link with
`swiftc -I <out>/lib -L <out>/lib -lBarPanels` and `import BarPanels`.
