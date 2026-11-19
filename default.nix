# SPDX-License-Identifier: GPL-3.0-or-later

let
  sources = import ./npins;
  pkgs = import sources.nixpkgs { };
  epkgs = pkgs.emacsPackagesFor pkgs.emacs-pgtk;
in
rec {
  # package.nix's defaults, built with these pins whatever Emacs it is for.
  server = pkgs.callPackage ./server/package.nix { };
  inherit (epkgs) org;

  package = epkgs.callPackage ./package.nix { };

  # An Emacs with the package, for the tests.
  emacs = epkgs.emacsWithPackages [ package ];

  # cargo and rustc for the server, with the Vulkan loader its GPU rendering opens, and Python
  # for its fuzzer.
  serverShell = pkgs.mkShell {
    packages = [
      pkgs.cargo
      pkgs.python3
      pkgs.rustc
    ];
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
  };
}
