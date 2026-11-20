# The brochure and the poster, as PDFs with their fonts embedded.
# `nix-build print` leaves them in ./result.
let
  site = import ../. { };
  inherit (site) sources keycap-server keycap-source;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;

  ##########
  # Inputs #
  ##########

  python = pkgs.python3.withPackages (ps: [ ps.pillow ]);
  typst = pkgs.typst.withPackages (ps: [ ps.tiaoma ]);
  # Maple Mono, the site's font, with every weight for print.
  fonts = pkgs.maple-mono.NL-TTF;

  ############
  # Pictures #
  ############

  # Every model, rendered on the CPU so that the same pins give the same
  # bytes; OpenSCAD's on Mesa's software renderer.
  renders =
    pkgs.runCommand "keycap-print-renders"
      {
        nativeBuildInputs = [
          python
          pkgs.openscad-unstable
        ];
        # For text() of installed fonts, by name.
        FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ site.legend-font ]; };
        __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
        KEYCAP_DIR = keycap-source;
        KEYCAP_DESIGNS_DIR = sources.keycap-designs;
        OPENSCAD_DIR = sources.openscad;
      }
      ''
        export HOME=$TMPDIR
        python3 ${./render.py} ${keycap-server}/bin/keycap-server ${keycap-source}/prelude ${./pictures.json} $out
      '';

  # The site's editor frames, made by its own ob-keycap from the front
  # page's block and screenshot in Chromium, on the CPU.
  site-src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../content/index.org
      ../static/style.css
      ../tools/ob-keycap.el
      ../tools/ppm2png.py
    ];
  };
  frames =
    pkgs.runCommand "keycap-print-frames"
      {
        nativeBuildInputs = [
          site.emacs
          python
        ];
        # Chromium's fallback, for any character the site's fonts lack.
        FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ fonts ]; };
      }
      ''
        export HOME=$TMPDIR
        mkdir pages
        cp ${site-src}/static/style.css pages
        cp ${./shoot.css} pages/shoot.css
        mkdir pages/fonts
        for face in Regular Italic Bold; do
          ln -s ${site.fonts}/share/fonts/woff2/MapleMonoNL-$face.ttf.woff2 pages/fonts/MapleMonoNL-$face.woff2
        done
        emacs --batch -l ${./frames.el} ${site-src} ${keycap-source}/examples pages
        python3 ${./shoot.py} ${pkgs.chromium}/bin/chromium pages $out
      '';

  pictures = pkgs.symlinkJoin {
    name = "keycap-print-pictures";
    paths = [
      renders
      frames
    ];
  };

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./common.typ
      ./brochure.typ
      ./poster.typ
      ./print.tmTheme
    ];
  };
in

pkgs.runCommand "keycap-print"
  {
    nativeBuildInputs = [ typst ];
    # For watch.sh.
    passthru = { inherit fonts pictures typst; };
  }
  ''
    cp -r ${src} print
    chmod -R u+w print
    cd print
    ln -s ${pictures} pictures

    compile() {
      typst compile --ignore-system-fonts --font-path ${fonts}/share/fonts "$@"
    }
    mkdir $out
    compile brochure.typ $out/brochure-a5.pdf
    compile --input layout=sheet brochure.typ $out/brochure-a4-sheet.pdf
    compile poster.typ $out/poster-a4.pdf
  ''
