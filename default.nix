{
  lib,
  stdenv,
  swift,
}:
# BarPanels as a Swift module: lib/libBarPanels.a and lib/BarPanels.swiftmodule.
# An app builds against it with `swiftc -I <out>/lib -L <out>/lib -lBarPanels`
# and `import BarPanels`.
stdenv.mkDerivation {
  pname = "bar-panels";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./Sources;
  };
  nativeBuildInputs = [ swift ];
  buildPhase = ''
    runHook preBuild
    swiftc -O -parse-as-library -module-name BarPanels \
      -emit-library -static -o libBarPanels.a \
      -emit-module -emit-module-path BarPanels.swiftmodule \
      Sources/BarPanels/*.swift
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    cp libBarPanels.a BarPanels.swiftmodule $out/lib/
    runHook postInstall
  '';
  meta = {
    description = "Drop-down panels for status-bar items, hidden from screen capture";
    platforms = lib.platforms.darwin;
    license = lib.licenses.mit;
  };
}
