# SPDX-License-Identifier: GPL-3.0-or-later
#
# keycap as an Emacs package, its server, prelude and manual at store paths.
# For `epkgs.callPackage`, with `rhai-ts-mode` the package from its own repository.
{
  lib,
  trivialBuild,
  callPackage,
  rhai-ts-mode,
  # ELPA's Org, for the manual: Emacs 30.2's Org 9.7.11 cuts Texinfo
  # definitions' names at their first `_'.
  org,
  keycap-server ? callPackage ./server/package.nix { },
}:
trivialBuild {
  pname = "keycap";
  version = "0.1";

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
    emacs --batch -L ${org}/share/emacs/site-lisp/elpa/org-${org.version} -L . \
      -l doc/keycap-reference.el \
      --eval '(keycap-reference-write "doc/keycap.org" "keycap.org" (quote texinfo))'
    emacs --batch -L ${org}/share/emacs/site-lisp/elpa/org-${org.version} keycap.org \
      --eval "(require 'ox-texinfo)" \
      --eval "(setq org-export-use-babel nil)" \
      -f org-texinfo-export-to-texinfo
    makeinfo --no-split --output=keycap.info keycap.texi
  '';

  # The manual, and the autoloads trivialBuild does not write: without them
  # `.keycap' and `.fidget' files open in keycap-mode only once it is loaded.
  postInstall = ''
    install -Dm644 keycap.info $out/share/info/keycap.info
    install-info $out/share/info/keycap.info $out/share/info/dir
    emacs --batch --eval \
      "(loaddefs-generate \"$LISPDIR\" \"$LISPDIR/keycap-autoloads.el\")"
  '';

  passthru.server = keycap-server;

  meta.license = lib.licenses.gpl3Plus;
}
