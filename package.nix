# SPDX-License-Identifier: GPL-3.0-or-later
#
# keycap as an Emacs package, its server, prelude and manual at store paths.
# For `epkgs.callPackage`, with `rhai-ts-mode` the package from its own repository.
{
  lib,
  melpaBuild,
  callPackage,
  rhai-ts-mode,
  # ELPA's Org, for the manual: Emacs 30.2's Org 9.7.11 cuts Texinfo
  # definitions' names at their first `_'.
  org,
  keycap-server ? callPackage ./server/package.nix { },
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
      -L ${org}/share/emacs/site-lisp/elpa/org-${org.version} -L . \
      -l doc/keycap-reference.el \
      --eval '(keycap-reference-write "doc/keycap.org" "keycap.org" (quote texinfo))'
    emacs --batch -L ${org}/share/emacs/site-lisp/elpa/org-${org.version} keycap.org \
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
