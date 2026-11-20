#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Screenshot the built site's pages with a headless Firefox.
# usage: tools/pageshots.sh SITE_DIR OUT_DIR [light]
set -euo pipefail

site=$(realpath "$1")
out=$2
scheme=${3:-dark}
mkdir -p "$out"

profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
# The colour scheme the pages see, and no first-run noise.
cat > "$profile/user.js" <<EOF
user_pref("layout.css.prefers-color-scheme.content-override", $([[ $scheme == light ]] && echo 1 || echo 0));
user_pref("ui.systemUsesDarkTheme", $([[ $scheme == light ]] && echo 0 || echo 1));
user_pref("browser.shell.checkDefaultBrowser", false);
EOF

shoot() {
  local page=$1 name=$2 height=${3:-2400}
  firefox --headless --no-remote --profile "$profile" \
    --window-size "1280,$height" --screenshot "$out/$name-$scheme.png" "file://$site/$page" > /dev/null 2>&1
}

shoot index.html index
shoot tutorial/index.html tutorial
shoot tutorial/01-first-model.html tutorial-01 4000
shoot tutorial/07-closed-forms.html tutorial-07 4000
shoot manual/index.html manual 3000
shoot gallery.html gallery 4000
shoot install.html install
shoot about.html about
