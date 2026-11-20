set shell := ["bash", "-euo", "pipefail", "-c"]

# Build the Emacs package.
build:
    @nix-build --no-out-link -A package default.nix

# Run the ERT suite against the package built from the working tree.
test:
    emacs=$(nix-build --no-out-link -A emacs default.nix) && \
      "$emacs/bin/emacs" --batch -l test/keycap-tests.el -f ert-run-tests-batch-and-exit

# Write the manual to OUT, its reference from the working tree's prelude, docs and server: Org for
# Info, or with BACKEND html, for the site.
manual OUT BACKEND="texinfo": server-build
    emacs=$(nix-build --no-out-link -A emacs default.nix) && \
      "$emacs/bin/emacs" --batch -L . -L doc -l keycap-reference \
        --eval '(setq keycap-server-program (expand-file-name "server/target/release/keycap-server"))' \
        --eval '(keycap-reference-write "doc/keycap.org" "{{ OUT }}" (quote {{ BACKEND }}))'

# Build the server with cargo, into server/target/release, without a full package build.
server-build:
    nix-shell -A serverShell default.nix --run 'cargo build --release --manifest-path server/Cargo.toml'

# Run the server's test suite against the working tree.
server-test *ARGS:
    nix-shell -A serverShell default.nix --run 'cargo test --release --manifest-path server/Cargo.toml {{ ARGS }}'

# Measure what each shape and function costs, into server/target/fuzz/costs.md.
costs *ARGS: server-build
    nix-shell -A serverShell default.nix --run 'python3 server/fuzz costs {{ ARGS }}'

# Load random programs, valid or each with a mistake, and shrink what misbehaves to a repro.
fuzz *ARGS: server-build
    nix-shell -A serverShell default.nix --run 'python3 server/fuzz fuzz {{ ARGS }}'

# Build the site into ./result-site.
site:
    nix-build -A site -o result-site

# Publish the site into site/public with the checkouts beside this one, and serve it.
site-preview *ARGS:
    site/tools/preview.sh {{ ARGS }}
