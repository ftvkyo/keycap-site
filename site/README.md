# keycap's site

The website of [keycap](https://tangled.org/rei.gay/keycap), an Emacs IDE for modelling with [fidget](https://github.com/mkeeter/fidget)'s signed distance fields, at [keycap.rei.gay](https://keycap.rei.gay/).
Plain HTML and CSS, written in Org and published by Emacs; one small script, `copy.js`, adds a copy button to each code block.

## Building

```sh
nix-build          # the site, in ./result
```

To look at it, open `result/index.html`, or serve it: `python3 -m http.server -d result`.

The stylesheet, the script and the fonts are published as `style.<hash>.css` and so on, from the hash of their content, so a changed one is fetched at once and an unchanged one cached for good.
The rendered pictures already have the hash of their source in their names.
GitHub Pages sends pages with `Cache-Control: max-age=600`, ten minutes, so an updated page may take that long to show; the pages' own URLs are not hashed, so they are the only thing that can lag.

Every picture is rendered by the build, on the CPU, in one keycap-server: about 370 s on 16 cores.

A build can start from an earlier one's renders, and render only the frames whose inputs changed:

```sh
nix-build -A all                                              # the site in ./result, its renders in ./result-cache
nix-build -A all --arg frameCache "$(readlink result-cache)"  # the same, from the last build's renders
```

`frameCache` is a directory of renders; the `cache` output, `result-cache`, holds the renders the build used, from `frameCache` or new, and no others, so a frame no page shows any more drops out.
A render is kept under the hash of everything that makes it -- keycap-server, the script and the files it imports, the view -- so the site comes out the same, byte for byte, with any cache or none.
So is each script's evaluation, until a file it imports changes: a block whose frame is cached evaluates nothing.
With every frame cached, the build takes about 35 s on 6 cores.

A pipeline keeps the `cache` output in a directory that persists between runs and passes it back in:

```sh
mkdir -p "$CACHE"                                             # an absolute path; empty on the first run
nix-build -A all --arg frameCache "$CACHE"
rm -rf "$CACHE" && cp -r --no-preserve=mode result-cache/. "$CACHE"
```

## Changing the tutorial

Each step of the tutorial is a `keycap` source block in its page, and its picture is made from it, so there is nothing else to update.

```sh
tools/preview.sh            # the site in public/, served on http://localhost:8000
```

`preview.sh` renders on the GPU and keeps every render in `~/.cache/keycap-site`, so a second run only renders the steps I changed.
With `KEYCAP_DIR=~/src/keycap` it uses a keycap checkout instead of the pin (its server from `just server-build`), for trying the tutorial against keycap changes before pinning them.

```sh
tools/preview.sh --dev      # the same, and the pages reload by themselves after an edit
```

`--dev` serves with `tools/dev.py` (Python's standard library and the same batch Emacs) and watches `content/`, `static/`, `tools/`, `publish.el` and, when they are set, the `KEYCAP_DIR` and `KEYCAP_DESIGNS_DIR` checkouts.
An edit of Org pages (or `style.css`, `copy.js`) publishes only those; any other edit publishes everything again, which the render cache makes cheap.
Then the open pages reload over Server-Sent Events, with the scroll kept; a failed build is only said in the terminal and in the tab's title.
Everything is served with `Cache-Control: no-cache`, so no force refresh is needed.
The reload script and the plain asset names exist only with `KEYCAP_DEV`, never in `nix-build`.

How the blocks work:

- The blocks of one `:model` add up in order, and a block's last `draw` replaces the last `draw` so far, as the text tells the reader.
  `:replace NAME` edits a `fn` where it is defined; `:after FILE` starts from the model where another page leaves it.
- Each block shows its code and a frame: the script so far beside its preview, with `:view`, `:camera`, `:slice`, `:bounds` and `:probe`.
- A block without code shows a moment between steps: the model as it is, or with `:typed TEXT`, the next step typed up to TEXT; `:at "TEXT|"` puts point, `:change OLD NEW` makes a typo, `:nudge N` presses `C-c C-n`, `:wheel N` turns the shifted wheel over the digit before point.
- The mouse: `:probe` over a 2D view's slice, with its reading in the header, `:pointer X Y` anywhere on the image; `:menu` opens the preview's menu at the mouse (`context`) or a header word's (`view`, `camera`, `slice`).
  `:show` completion, eldoc, describe or export adds what keycap shows then.
- The build fails on any diagnostic a block doesn't `:expect` (error or warning), with the block's line in its page.
- `:save FILE` is a file beside the scripts (the SKÅDIS module), `:open FILE` one of keycap's examples, `:frame no` the image alone.
- The full list is at the top of `tools/ob-keycap.el`.

In Emacs, `C-c C-c` on a block renders it and inserts a link to the image; `org-display-inline-images` shows it, and `C-c C-v k` removes the results before committing.
That needs `tools/` on the `load-path`, `(require 'ob-keycap)`, and `ob-keycap-examples-directory` set for `:open`.

Without Nix, `KEYCAP_DIR=CHECKOUT emacs --batch --load publish.el` writes `public/`, with keycap and htmlize installed.
`KEYCAP_DESIGNS_DIR` adds my designs to the gallery; without it the gallery has only the examples.

## Marking who wrote what

Most of the text is drafted by an AI, and the pages say what a person has read.

- A page's `#+review:` is `draft`, `reviewed YYYY-MM-DD` or `reviewed YYYY-MM-DD by NAME`; under its title, a badge says "Drafted with AI, not yet reviewed", or a quiet line "Reviewed DATE" or "Reviewed by NAME, DATE".
  Without the keyword a page is a draft.
- A heading's `:REVIEW:` property takes the same values and marks that section, overriding the page's; the mark is a small badge under the heading.
- `#+begin_human` ... `#+end_human` is a box labelled "Written by hand", for a person's own words in the middle of drafted text; `#+begin_human NAME` labels it "Written by NAME".
- The manual's pages and the gallery's are generated, so they only have the page mark, always a draft.
  Marking one entry would take a `Reviewed: DATE` line in its doc in keycap, which `publish.el` would turn into a `:REVIEW:` property on the entry's heading; it is not built.

## Layout

```
content/           the pages, in Org; the tutorial's code is in its keycap blocks
  gallery/         written by publish.el from the models, not committed
  manual/          written by publish.el from keycap's manual, not committed
static/            style.css, copy.js and the icon
npins/             keycap, rhai-ts-mode, keycap-designs and openscad (for print/), pinned
publish.el         the Org projects, the page frame and the anchors
default.nix        the build: keycap, Emacs, the font, the frame cache
tools/             keycap-site-gallery.el and keycap-site-manual.el, the gallery and the manual's pages;
                   ob-keycap.el and ppm2png.py (the frames), subset-fonts.py, preview.sh, dev.py, check-links.py, field.py, shots/
print/             the brochure and the poster, in Typst; see its README
```

- The manual is keycap's own (`doc/keycap.org` in keycap's repository), published as `manual/`; fix it there, not here.
  Its reference is written from keycap-server's docs by keycap's `doc/keycap-reference.el`, as for Info: entries are fixed in the files that describe them, the prelude's `///` comments and the server's `docs/*.toml`.
  It is split into a page per chapter, with an index page of the contents, functions, keys and concepts, which also keeps the anchors of the single page it once was (`keycap-site-manual-retired-anchors` for entries since merged).
  Each function that makes a shape gets a picture of its example: the code block in its entry, or else the first `Example:` of its doc that is not a value; easings and steps get their graph (`keycap-site-manual-plots`); an example that makes no shape shows its value.
  An entry's parts, `Notes:`, `See also:`, `References:` and `From OpenSCAD:`, and its `Example:` with a caption and then a code block, are boxes, the example's with its picture; every entry is headed by its signatures, set out by keycap as `C-c C-d` sets them out.
  Each entry has a strip in the colour of its kind, which the file that describes it declares, and a label of that and where it comes from; the legend is at the end of Reading signatures.
- The gallery is generated from two sources: keycap's `examples/`, a section of their own, and my designs (the `keycap-designs` pin), a section with a subsection per directory of the repository: `keycaps/` first, then the groups of ports of my designs made for one thing.
  A source or group with no models is left out.
  Each model gets a page with its opening comment, renders, files and source, under `gallery/` as it is laid out in its repository (`gallery/designs/<group>/<design>.html`); its files are published as `examples/` and `designs/`.
  A model's `// view: camera 120 30` lines (settings apart by commas: `camera AZIMUTH ELEVATION` or `front`/`right`/`top`/`iso`, `shaded`/`heightmap`/`sdf`/`mono`, `slice AXIS [OFFSET]`) replace its default renders, the first also its card's; a manual example's ` [view: ...]` at the end of its `Example:` line does the same for its picture.
  Each card and page says who made the model (`keycap-site-author`, or `keycap-site-examples-author` for an example that is not a port); every card marks a port with an icon, the page's a link to the original on GitHub, and links to the model on Printables if it is there (`keycap-site-printables`, by its page in the gallery).
  A port's original is in its row of `PORTS.md`, a keycap's in its opening comment, an example's in `keycap-site-example-originals`.
  A port's page shows its row of `PORTS.md`, whatever columns that has, the keycaps' too, and the cryptodancer's some of its legends (`keycap-site-keycaps-legends`); an example's opening comment says how it compares with its original in one line.
  Imports resolve as in Emacs: `keycap.rhai` beside the keycaps, `keycap/<name>` from the pinned keycap's prelude.
- The site's colours are the infra's: Ayu Dark, Ayu Light for light schemes; the frames take the infra's Emacs theme; the font is Maple Mono, served from the site.

## Keeping it in step with keycap

```sh
npins update keycap rhai-ts-mode              # the manual, the examples, the server
nix-build                                     # every frame rendered again
```

My designs are pinned the same way; as they land on keycap-designs' main:

```sh
npins update keycap-designs                   # the designs' section, as main has it
nix-build
```

A design written against a newer keycap (a new prelude function, a `keycap/<name>` module) fails the build until keycap is updated too: `npins update keycap keycap-designs`.

The build fails on any diagnostic in the tutorial's code that a block doesn't `:expect`, naming the block's line in its page.

## Publishing

The repository lives on knot (tangled), and the site at `keycap.rei.gay`, served by GitHub Pages from the `gh-pages` branch of a GitHub mirror.
Both are pushed by tangled CI, on the spindle at `spindle.rei.gay`; GitHub runs nothing.

- `.tangled/workflows/mirror.yml` pushes `main` and the tags to GitHub after every push to them.
- `.tangled/workflows/pages.yml` builds the site on each push to `main`, or when run by hand, and replaces `gh-pages` with one commit of `result/`, a `CNAME` and `.nojekyll`.
  The build is reproducible and that commit's names and dates come from the source commit, so an unchanged site is not pushed at all, and a changed one uploads only the changed files.

To set it up:

1. Create the repository on tangled.org on the `knot.rei.gay` knot, then push to the SSH address its page shows:

   ```sh
   git remote add origin <the repository's SSH address>
   git push -u origin main
   ```

2. In the repository's Settings > Pipelines, select the `spindle.rei.gay` spindle, and add the secret `GITHUB_MIRROR_TOKEN`: a fine-grained GitHub token for the mirror with Contents read and write.
   The first push also needs Workflows read and write, since its history adds and removes a GitHub workflow; it can be dropped afterwards.
3. Create an empty GitHub repository, push to the knot so both workflows run, then in the GitHub repository's settings set Pages' source to "Deploy from a branch", `gh-pages`, `/ (root)`, and its custom domain to `keycap.rei.gay`.
4. At the DNS host of `rei.gay`, point `keycap` at GitHub with a `CNAME` to `<owner>.github.io`, and verify `rei.gay` in the GitHub account's Pages settings (a `TXT` record), so no other account can claim the name.
   Then tick "Enforce HTTPS".

Any repository can publish Pages under its own custom domain, so the GitHub repository can belong to the personal account: with a custom domain set, it is served at `keycap.rei.gay`, not under `ftvkyo.me`.
An organisation is only worth it to keep the project's GitHub presence apart from the personal account.

Codeberg Pages, Netlify or any static host work the same way: build, then upload `result/`.
All links are relative, so the site also works under a sub-path.

## Licence

The site's code (`publish.el`, `tools/`, `static/`, `default.nix`) is GPL-3.0-or-later (`LICENSE`).
Its text, in `content/` and `print/`, is CC BY-SA 4.0 (`content/LICENSE`); the tutorial's code is 0BSD, so it may be used without attribution.
keycap's Emacs package and manual are GPL-3.0-or-later, its server and prelude MPL-2.0 and its examples 0BSD; keycap-designs is CC BY-SA 4.0.
