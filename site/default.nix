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
  keycap = epkgs.callPackage "${sources.keycap}/package.nix" {
    inherit rhai-ts-mode;
    keycap-server = (import sources.keycap).server;
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
      pkgs.oxipng
      pkgs.pngquant
      pkgs.python3
    ];
    # The renders this build used, from frameCache or new, for the next one.
    outputs = [
      "out"
      "cache"
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
      emacs --batch --load publish.el

    python3 ${./tools/check-links.py} public

    # The frames are most of the site's weight.  A palette of 256 colours
    # halves them with no difference to the eye, and oxipng takes the rest
    # it can without loss; both give the same bytes on every build.
    find public -name '*.png' -exec pngquant --speed 1 --strip --force --ext .png {} +
    find public -name '*.png' -exec oxipng -q -o 4 --strip safe {} +

    cp -r public $out
  ''
