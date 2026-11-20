# keycap's site

The website of [keycap](https://tangled.org/rei.gay/keycap), an Emacs IDE for [fidget](https://github.com/mkeeter/fidget) models, at [keycap.rei.gay](https://keycap.rei.gay/).
Its pages are Org, published to plain HTML by Emacs; every picture on them is rendered by keycap during the build.

## Building

```sh
nix-build          # the site, in ./result
```

The first build renders every picture on the CPU, about 6 minutes on 16 cores.
A build can start from the last one's renders, and render only the pictures whose inputs changed:

```sh
nix-build -A all                                              # the site in ./result, its renders in ./result-cache
nix-build -A all --arg frameCache "$(readlink result-cache)"  # the same, from the last build's renders
```

A render is kept under the hash of everything that makes it, so the site is the same, byte for byte, with any cache or none.

## Without Nix

With keycap's server built (`just server-build` in keycap), htmlize and nix-mode installed, and rhai-ts-mode's grammar (`M-x rhai-ts-mode-install-grammar`):

```sh
KEYCAP_DIR=../keycap \
KEYCAP_FONTS=../MapleMonoNL-Woff2 \
KEYCAP_FONTS_LICENCE=../MapleMonoNL-Woff2/LICENSE.txt \
emacs --batch -L ../keycap -L ../rhai-ts-mode \
  --eval '(setq keycap-server-program (expand-file-name "../keycap/server/target/release/keycap-server"))' \
  --load publish.el
```

It writes the site into `public/`.
`KEYCAP_FONTS` is `MapleMonoNL-Woff2.zip` from [Maple Mono's releases](https://github.com/subframe7536/maple-font/releases), unzipped.
`KEYCAP_DESIGNS_DIR=../keycap-designs` adds the designs to the gallery.

## Contributing

- `content/` is the pages; a tutorial step is a `keycap` block, its header arguments listed at the top of `tools/ob-keycap.el`.
  With `tools/` on the `load-path` and `(require 'ob-keycap)`, `C-c C-c` on a block renders it in Emacs.
- The gallery and the manual are written into `content/` by the build: the manual from keycap's `doc/keycap.org`, which is where to fix it.
- `#+review:` and `#+begin_human` mark what a person has read or written, as `publish.el`'s Review section describes.
- `tools/preview.sh` publishes into `public/` and serves it on http://localhost:8000, rendering on the GPU when there is one.
  `--root ..` publishes with the keycap, keycap-designs and rhai-ts-mode checkouts beside this one instead of the pins, keycap's server built first; `--dev`, which needs `--root`, publishes again after an edit and reloads the page.
- `NPINS_OVERRIDE_keycap=../keycap nix-build` builds with a keycap checkout instead of the pin, and so do `NPINS_OVERRIDE_rhai_ts_mode` and `NPINS_OVERRIDE_keycap_designs`, with underscores for dashes.
  A checkout is copied to the store without `.git` and `target/`, so keycap's `server/target` stays out.
- A commit is one change, its subject the area and what the change makes, as in `git log`, with an `Assisted-by:` trailer when an AI helped write it.
- Issues and patches go to [tangled](https://tangled.org/rei.gay/keycap-site).

## Publishing

`.tangled/workflows/pages.yml` builds the site on the spindle on each push to `main`, and pushes it to the `gh-pages` branch of the GitHub mirror, which GitHub Pages serves.
`.tangled/workflows/mirror.yml` keeps the mirror's `main` and tags up to date.

## Licence

The site's code (`publish.el`, `tools/`, `static/`, `default.nix`) is GPL-3.0-or-later (`LICENSE`).
Its text, in `content/` and `print/`, is CC BY-SA 4.0 (`content/LICENSE`); the tutorial's code is 0BSD, so it may be used without attribution.
