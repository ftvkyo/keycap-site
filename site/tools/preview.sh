#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Publish the site into public/ without nix-build, and serve it on localhost.
# usage: tools/preview.sh [--root DIR] [--no-serve|--dev] [PORT]
#
# --root DIR publishes with the checkouts DIR/keycap, DIR/keycap-designs and
# DIR/rhai-ts-mode instead of the pins: keycap's elisp, prelude, manual and
# examples as they are, and its server as `just server-build`, run first,
# leaves it.  Without --root, everything comes from the pins.
# --dev serves with tools/dev.py instead: it publishes again what an edit
# changed, and the open pages reload.  It needs --root, whose keycap and
# keycap-designs it watches; a change to rhai-ts-mode needs a restart.
# Frames render on the GPU when there is one, and each render is kept in
# ~/.cache/keycap-site by its hash, so only the steps that changed render
# again.
set -euo pipefail

root=
serve=1
dev=0
while (($#)); do
  case $1 in
    --root) root=$(realpath "$2"); shift 2 ;;
    --no-serve) serve=0; shift ;;
    --dev) dev=1; shift ;;
    *) break ;;
  esac
done
port=${1:-8000}

if ((dev)) && [[ -z $root ]]; then
  echo "preview.sh: --dev needs --root, the directory of the checkouts it watches" >&2
  exit 1
fi

site=$(realpath "$(dirname "$0")/..")

checkout=()
watch=()
if [[ -n $root ]]; then
  for repo in keycap keycap-designs rhai-ts-mode; do
    [[ -d $root/$repo ]] || { echo "preview.sh: no $repo checkout in $root" >&2; exit 1; }
  done
  keycap=$root/keycap
  designs=$root/keycap-designs
  (cd "$keycap" && just server-build)
  checkout=(
    --eval "(add-to-list 'load-path \"$keycap\")"
    --eval "(setq keycap-server-program \"$keycap/server/target/release/keycap-server\")"
  )
  watch=(--watch "$keycap" --watch "$designs")
  # keycap is on the load path, so the site's Emacs goes without it; its
  # rhai-ts-mode, with the grammar, is built from the checkout.
  export NPINS_OVERRIDE_rhai_ts_mode=$root/rhai-ts-mode
  emacs=$(nix-build --no-out-link -A emacs-checkout "$site")
else
  keycap=$(nix-instantiate --eval --raw -A sources.keycap.outPath "$site")
  designs=$(nix-instantiate --eval --raw -A sources.keycap-designs.outPath "$site")
  emacs=$(nix-build --no-out-link -A emacs "$site")
fi
fonts=$(nix-build --no-out-link -A fonts "$site")
fonts_licence=$(nix-build --no-out-link -A fonts-licence "$site")

cd "$site"
export KEYCAP_DIR=$keycap
export KEYCAP_DESIGNS_DIR=$designs
export KEYCAP_FONTS=$fonts/share/fonts/woff2
export KEYCAP_FONTS_LICENCE=$fonts_licence
export KEYCAP_BACKEND=gpu
export KEYCAP_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/keycap-site
publish=("$emacs/bin/emacs" --batch "${checkout[@]}" --load publish.el)

if ((dev)); then
  export KEYCAP_DEV=1
fi
rm -rf public
"${publish[@]}"

if ((dev)); then
  exec python3 tools/dev.py --port "$port" "${watch[@]}" -- "${publish[@]}"
fi

python3 tools/check-links.py public

if ((serve)); then
  python3 -m http.server --bind 127.0.0.1 --directory public "$port"
fi
