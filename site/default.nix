# SPDX-License-Identifier: GPL-3.0-or-later
#
# The site: Org pages published to HTML by a batch Emacs, nothing else.
# `nix-build` leaves it in ./result; any static file server can host it.
#
# frameCache is a directory of renders that a build left in its `cache`
# output: a frame whose hash is there is taken from it, not rendered again.
{
  frameCache ? null,
}:

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
  keycap-server = (import sources.keycap).server;
  keycap = epkgs.callPackage "${sources.keycap}/package.nix" {
    inherit rhai-ts-mode keycap-server;
  };

  # Code blocks are highlighted by rhai-ts-mode, with its patched grammar,
  # and the install page's Nix by nix-mode.
  emacs = epkgs.emacsWithPackages [
    epkgs.htmlize
    epkgs.nix-mode
    keycap
  ];

  # Maple Mono, the infra's own font, without ligatures.
  fonts = pkgs.maple-mono.NL-Woff2;

  # Its licence, which the OFL asks to travel with the served faces; the
  # package leaves it in the release's zip.
  fonts-licence = pkgs.runCommand "maple-mono-licence" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -p ${fonts.src} LICENSE.txt > $out
  '';

  # The faces the models' text() names, each alone from the nerd-fonts
  # repository rather than its family's release (84 MB for Iosevka), the
  # same files as v3.4.0's: the keycaps' legends in Iosevka NF Light, the
  # whistle port's label in JetBrains Mono NF Bold.
  nerd-font =
    path: hash:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.4.0/patched-fonts/${path}";
      inherit hash;
    };
  legend-font = pkgs.runCommand "legend-fonts" { } ''
    mkdir -p $out/share/fonts
    cp ${nerd-font "Iosevka/IosevkaNerdFont-Light.ttf" "sha256-/xUh3JcanrAfEh+ThywzoQrq57gfgWfUi28lwDU7zFE="} \
      $out/share/fonts/IosevkaNerdFont-Light.ttf
    cp ${nerd-font "JetBrainsMono/Ligatures/Bold/JetBrainsMonoNerdFont-Bold.ttf" "sha256-6C4np/N8mgoTzE5BdQOhScagKAWGkwdy0uvtgDFZyGQ="} \
      $out/share/fonts/JetBrainsMonoNerdFont-Bold.ttf
  '';

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./publish.el
      ./content
      ./static
      ./tools/keycap-site-gallery.el
      ./tools/keycap-site-manual.el
      ./tools/ob-keycap.el
      ./tools/ppm2png.py
    ];
  };
in

pkgs.runCommand "keycap-site"
  {
    nativeBuildInputs = [
      emacs
      pkgs.oxipng
      pkgs.pngquant
      (pkgs.python3.withPackages (ps: [
        ps.brotli
        ps.fonttools
      ]))
    ];
    # The renders this build used, from frameCache or new, for the next one.
    outputs = [
      "out"
      "cache"
    ];
    # For text() of installed fonts, by name.
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ legend-font ]; };
    # For tools/preview.sh, print/ and pages.yml.
    passthru = {
      inherit
        emacs
        fonts
        fonts-licence
        keycap-server
        legend-font
        sources
        ;
    };
  }
  ''
    mkdir frame-cache
    ${lib.optionalString (frameCache != null) ''
      cp -r ${frameCache}/. frame-cache
      chmod -R u+w frame-cache
    ''}

    cp -r ${src} site
    chmod -R u+w site
    cd site

    KEYCAP_DIR=${sources.keycap} \
    KEYCAP_DESIGNS_DIR=${sources.keycap-designs} \
    KEYCAP_FONTS=${fonts}/share/fonts/woff2 \
    KEYCAP_FONTS_LICENCE=${fonts-licence} \
    KEYCAP_CACHE=$NIX_BUILD_TOP/frame-cache \
    KEYCAP_CACHE_OUT=$cache \
    KEYCAP_COMPRESS=1 \
      emacs --batch --load publish.el

    python3 ${./tools/subset-fonts.py} public
    python3 ${./tools/check-links.py} public

    cp -r public $out
  ''
