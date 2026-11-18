# SPDX-License-Identifier: GPL-3.0-or-later
#
# keycap as an Emacs package, its server, prelude and manual at store paths.
# For `epkgs.callPackage`; besides Emacs, what it needs comes from keycap's
# pins unless passed.
{
  lib,
  melpaBuild,
  callPackage,
  rhai-ts-mode ? callPackage "${(import ./npins).rhai-ts-mode}/package.nix" { },
  # Built with keycap's pinned nixpkgs, whose Rust is new enough for fidget.
  # One built with the system's nixpkgs, where its Rust is 1.95 or later,
  # loads a Vulkan driver built against the same glibc.
  keycap-server ? (import ./default.nix).server,
  # ELPA's Org from keycap's pinned nixpkgs, for the manual: Emacs 30.2's
  # Org 9.7.11 cuts Texinfo definitions' names at their first `_', and an
  # older nixpkgs' ELPA tarball can be gone from elpa.gnu.org. Compiled by
  # another Emacs, it is only loaded while building.
  manualOrg ? (import ./default.nix).org,
}:
let
  # keycap, its server and its prelude are one version, which keycap.el's
  # header says too.
  inherit ((lib.importTOML ./server/Cargo.toml).package) version;
in
# melpaBuild installs under site-lisp/elpa, where package.el activates it:
# its autoloads hold the `.keycap' and `.fidget' associations.
melpaBuild {
  pname = "keycap";
  inherit version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./keycap.el
      ./keycap-describe.el
      ./keycap-preview.el
      ./doc/keycap.org
      ./doc/keycap-reference.el
    ];
  };

  packageRequires = [ rhai-ts-mode ];

  turnCompilationWarningToError = true;

  postPatch = ''
    substituteInPlace keycap.el \
      --replace-fail '(defcustom keycap-server-program "keycap-server"' \
                     '(defcustom keycap-server-program "${keycap-server}/bin/keycap-server"' \
      --replace-fail '(expand-file-name "prelude" keycap--directory)' \
                     '"${./prelude}"' \
      --replace-fail '(expand-file-name "keycap.info" keycap--directory)' \
                     "\"$out/share/info/keycap.info\""
  '';

  # The manual, from Org to Info, its reference written from the server's
  # docs first.
  postBuild = ''
    emacs --batch -f package-activate-all \
      -L ${manualOrg}/share/emacs/site-lisp/elpa/org-${manualOrg.version} -L . \
      -l doc/keycap-reference.el \
      --eval '(keycap-reference-write "doc/keycap.org" "keycap.org" (quote texinfo))'
    emacs --batch -L ${manualOrg}/share/emacs/site-lisp/elpa/org-${manualOrg.version} keycap.org \
      --eval "(require 'ox-texinfo)" \
      --eval "(setq org-export-use-babel nil)" \
      -f org-texinfo-export-to-texinfo
    makeinfo --no-split --output=keycap.info keycap.texi
  '';

  postInstall = ''
    install -Dm644 keycap.info $out/share/info/keycap.info
    install-info $out/share/info/keycap.info $out/share/info/dir
  '';

  passthru.server = keycap-server;

  meta.license = lib.licenses.gpl3Plus;
}
