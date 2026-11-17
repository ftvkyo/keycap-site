#!/usr/bin/env bash
# Recompile a PDF whenever its source changes, to work on the layout.
# usage: print/watch.sh brochure|poster [TYPST ARGS...]
#
# The pictures come from the Nix build, linked as print/pictures; the PDF
# is written beside its source.
set -euo pipefail

print=$(realpath "$(dirname "$0")")
name=$1
shift

nix-build "$print" -A pictures -o "$print/pictures"
typst=$(nix-build --no-out-link "$print" -A typst)
fonts=$(nix-build --no-out-link "$print" -A fonts)

exec "$typst/bin/typst" watch --ignore-system-fonts --font-path "$fonts/share/fonts" "$@" \
  "$print/$name.typ" "$print/$name.pdf"
