# Screenshots

The site's pictures are made by the build; nothing here runs in it.

`hero.el` takes one real screenshot of keycap: the knob example and its preview, in Emacs with the infra's configuration, written to `content/images/site/hero.png`.
It runs in the infra's headless rig, from an infra checkout whose Emacs has keycap:

```sh
just niri headless hero
NIRI_TRY_NAME=hero RIG_NAME=hero KEYCAP_DIR=~/src/keycap just emacs rig ~/src/keycap-site/tools/shots/hero.el
```

The front page shows a composed frame of the same example; to show the screenshot instead, replace that block in `content/index.org` with a link to the image.
Optimise the image with `oxipng` before committing it.
