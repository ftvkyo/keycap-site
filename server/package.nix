# SPDX-License-Identifier: MPL-2.0
#
# keycap-server, the render and evaluation server behind keycap.
# For `callPackage`.
{
  lib,
  rustPlatform,
  liberation_ttf,
  vulkan-loader,
}:
let
  manifest = (lib.importTOML ./Cargo.toml).package;
in
rustPlatform.buildRustPackage {
  pname = manifest.name;
  inherit (manifest) version;

  # The prelude beside the server, which the tests load.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./printers
      ./src
      ./docs
      ./tests
      ../prelude
    ];
  };
  sourceRoot = "source/server";

  cargoHash = "sha256-d9doPrj5Cue9LRyGPmKZRzeRb5BwNvAmDj5eOVhKBgQ=";

  # text()'s default font, OpenSCAD's, built into the binary.
  env.KEYCAP_SERVER_FONT = "${liberation_ttf}/share/fonts/truetype/LiberationSans-Regular.ttf";

  # wgpu loads libvulkan.so.1 with dlopen, which the binary's RUNPATH serves;
  # added after fixup, which would drop it as unused.
  postFixup = ''
    patchelf --add-rpath ${lib.makeLibraryPath [ vulkan-loader ]} $out/bin/${manifest.name}
  '';

  meta = {
    inherit (manifest) description;
    license = lib.licenses.mpl20;
    mainProgram = manifest.name;
    # fidget's JIT compiles for x86-64 and AArch64.
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
