#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Publish the site into public/ without nix-build, and serve it on localhost.
# usage: tools/preview.sh [--no-serve|--dev] [PORT]
#
# --dev serves with tools/dev.py instead: it publishes again what an edit
# changed, and the open pages reload.
# Frames render on the GPU when there is one, and each render is kept in
# ~/.cache/keycap-site by its hash, so only the steps that changed render
# again.  KEYCAP_DIR=CHECKOUT publishes with a keycap checkout instead of
# the pinned keycap: its elisp, prelude, manual and examples, and its
# server as `just server-build` leaves it.  KEYCAP_DESIGNS_DIR does the same
# for keycap-designs.
set -euo pipefail

serve=1
dev=0
case ${1:-} in
  --no-serve) serve=0; shift ;;
  --dev) dev=1; shift ;;
esac
port=${1:-8000}

site=$(realpath "$(dirname "$0")/..")
emacs=$(nix-build --no-out-link -A emacs "$site")
fonts=$(nix-build --no-out-link -A fonts "$site")
fonts_licence=$(nix-build --no-out-link -A fonts-licence "$site")

checkout=()
watch=()
if [[ -n ${KEYCAP_DIR:-} ]]; then
  keycap=$(realpath "$KEYCAP_DIR")
  watch+=(--watch "$keycap")
  checkout=(
    --eval "(add-to-list 'load-path \"$keycap\")"
    --eval "(setq keycap-server-program \"$keycap/server/target/release/keycap-server\")"
  )
else
  keycap=$(nix-instantiate --eval --raw -A sources.keycap.outPath "$site")
fi

[[ -z ${KEYCAP_DESIGNS_DIR:-} ]] || watch+=(--watch "$(realpath "$KEYCAP_DESIGNS_DIR")")
designs=${KEYCAP_DESIGNS_DIR:-$(nix-instantiate --eval --raw -A sources.keycap-designs.outPath "$site")}

cd "$site"
export KEYCAP_DIR=$keycap
export KEYCAP_DESIGNS_DIR=$(realpath "$designs")
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
