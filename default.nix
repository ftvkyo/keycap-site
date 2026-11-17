# SPDX-License-Identifier: GPL-3.0-or-later

let
  sources = import ./npins;
  pkgs = import sources.nixpkgs { };
  epkgs = pkgs.emacsPackagesFor pkgs.emacs-pgtk;
in
rec {
  server = pkgs.callPackage ./server/package.nix { };

  rhai-ts-mode = epkgs.callPackage "${sources.rhai-ts-mode}/package.nix" { };

  package = epkgs.callPackage ./package.nix {
    inherit rhai-ts-mode;
    keycap-server = server;
  };

  # An Emacs with the package, for the tests.
  emacs = epkgs.emacsWithPackages [ package ];

  # cargo and rustc for the server, with the Vulkan loader its GPU rendering opens.
  serverShell = pkgs.mkShell {
    packages = [
      pkgs.cargo
      pkgs.rustc
    ];
    LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
  };
}
