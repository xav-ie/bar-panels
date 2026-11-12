{
  description = "BarPanels — drop-down panels for status-bar items, hidden from screen capture";

  # No inputs: build it from your own nixpkgs (the overlay, or callPackage on
  # default.nix), the same nixpkgs (and so Swift) as the app that links it.
  outputs = _: {
    overlays.default = final: _prev: {
      bar-panels = final.callPackage ./default.nix { };
    };
  };
}
