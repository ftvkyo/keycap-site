# SPDX-License-Identifier: GPL-3.0-or-later
#
# The site: Org pages published to HTML by a batch Emacs, nothing else.
# `nix-build` leaves it in ./result; any static file server can host it.
let
  sources = import ./npins;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;

  ##########
  # Inputs #
  ##########

  # A graphical Emacs, used in batch: without image support, keycap's preview
  # does not compile cleanly.
  epkgs = pkgs.emacsPackagesFor pkgs.emacs-pgtk;
  rhai-ts-mode = epkgs.callPackage "${sources.rhai-ts-mode}/package.nix" { };
  keycap = epkgs.callPackage "${sources.keycap}/package.nix" {
    inherit rhai-ts-mode;
    keycap-server = (import sources.keycap).server;
  };

  # Code blocks are highlighted by rhai-ts-mode, with its patched grammar.
  emacs = epkgs.emacsWithPackages [
    epkgs.htmlize
    keycap
  ];

  # Maple Mono, the infra's own font, without ligatures.
  fonts = pkgs.maple-mono.NL-Woff2;

  # Its licence, which the OFL asks to travel with the served faces; the
  # package leaves it in the release's zip.
  fonts-licence = pkgs.runCommand "maple-mono-licence" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -p ${fonts.src} LICENSE.txt > $out
  '';

  # The faces the models' text() names, each alone from its nerd-fonts release
  # rather than the whole family: the keycaps' legends in Iosevka NF Light,
  # the whistle port's label in JetBrains Mono NF Bold.
  legend-font = pkgs.runCommand "legend-fonts" { } ''
    mkdir -p $out/share/fonts
    tar -xJf ${pkgs.nerd-fonts.iosevka.src} -C $out/share/fonts IosevkaNerdFont-Light.ttf
    tar -xJf ${pkgs.nerd-fonts.jetbrains-mono.src} -C $out/share/fonts JetBrainsMonoNerdFont-Bold.ttf
  '';

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./publish.el
      ./content
      ./static
      ./tools/ob-keycap.el
      ./tools/ppm2png.py
    ];
  };
in

pkgs.runCommand "keycap-site"
  {
    nativeBuildInputs = [
      emacs
      pkgs.python3
    ];
    # For text() of installed fonts, by name.
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ legend-font ]; };
    # For tools/preview.sh and print/.
    passthru = {
      inherit
        emacs
        fonts
        fonts-licence
        legend-font
        sources
        ;
    };
  }
  ''
    cp -r ${src} site
    chmod -R u+w site
    cd site

    KEYCAP_DIR=${sources.keycap} \
    KEYCAP_DESIGNS_DIR=${sources.keycap-designs} \
    KEYCAP_FONTS=${fonts}/share/fonts/woff2 \
    KEYCAP_FONTS_LICENCE=${fonts-licence} \
      emacs --batch --load publish.el

    python3 ${./tools/check-links.py} public
    cp -r public $out
  ''
