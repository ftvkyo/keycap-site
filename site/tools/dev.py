# SPDX-License-Identifier: GPL-3.0-or-later
"""Serve public/ and publish it again when a source changes; the open pages reload.

usage: dev.py [--port PORT] [--watch DIR]... -- PUBLISH COMMAND...

Watches content/, static/, tools/, publish.el and each DIR, site/ apart.  An edit of Org
pages alone publishes only those, with KEYCAP_ONLY; any other edit publishes
everything again, which keycap's render cache makes cheap.  Pages are sent
with no-cache, and tell the browser to reload over Server-Sent Events.
"""

import argparse
import os
import shutil
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

site = Path(__file__).resolve().parent.parent

# Written by publish.el itself, which must not start another round.
generated = [site / "content" / "gallery", site / "content" / "manual", site / "content" / "field.html"]
skipped = {".git", ".claude", "target", "node_modules", "__pycache__"}

SCRIPT = """\
const events = new EventSource("/__reload");
let opened = false;
events.onopen = () => { if (opened) location.reload(); opened = true; };
events.onmessage = (e) => {
  if (e.data === "reload") location.reload();
  else if (!document.title.startsWith("[build failed] ")) document.title = "[build failed] " + document.title;
};
"""


def scan(roots):
    """The modification time of every file under ROOTS."""
    seen = {}
    for root in roots:
        if root.is_file():
            seen[root] = root.stat().st_mtime_ns
            continue
        for directory, names, files in os.walk(root):
            names[:] = [n for n in names if n not in skipped and Path(directory, n) not in generated and Path(directory, n) != site]
            for name in files:
                path = Path(directory, name)
                if path in generated:
                    continue
                try:
                    seen[path] = path.stat().st_mtime_ns
                except FileNotFoundError:
                    pass
    return seen


class Reloads:
    """What the open pages are told: a counter and the last message."""

    def __init__(self):
        self.condition = threading.Condition()
        self.count = 0
        self.message = ""

    def send(self, message):
        with self.condition:
            self.count += 1
            self.message = message
            self.condition.notify_all()


reloads = Reloads()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(site / "public"), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_GET(self):
        if self.path == "/__dev.js":
            body = SCRIPT.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/__reload":
            self.events()
        else:
            super().do_GET()

    def events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        seen = reloads.count
        try:
            self.wfile.write(b": open\n\n")
            self.wfile.flush()
            while True:
                with reloads.condition:
                    if not reloads.condition.wait_for(lambda: reloads.count != seen, timeout=15):
                        line = b": keepalive\n\n"
                    else:
                        seen = reloads.count
                        line = f"data: {reloads.message}\n\n".encode()
                self.wfile.write(line)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def publish(command, changed):
    """Publish again for the files CHANGED; whether it worked."""
    environment = dict(os.environ)
    inside = lambda path, directory: directory in path.parents
    if all(p.exists() and ((inside(p, site / "content") and p.suffix == ".org")
                           or (inside(p, site / "static") and p.suffix in {".css", ".js"})) for p in changed):
        environment["KEYCAP_ONLY"] = ":".join(str(p) for p in changed)
    elif (site / "public").exists():
        # The files copied from the store are read-only, and cannot be written over.
        shutil.rmtree(site / "public")
    started = time.monotonic()
    ok = subprocess.run(command, cwd=site, env=environment).returncode == 0
    what = "only " + ", ".join(p.name for p in changed) if "KEYCAP_ONLY" in environment else "everything"
    print(f"{'published' if ok else 'FAILED, publishing'} {what} in {time.monotonic() - started:.1f} s", flush=True)
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--watch", action="append", default=[], type=Path)
    parser.add_argument("command", nargs="+")
    arguments = parser.parse_args()

    roots = [site / "content", site / "static", site / "tools", site / "publish.el", *arguments.watch]
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"http://localhost:{arguments.port}/, watching for edits", flush=True)

    known = scan(roots)
    while True:
        time.sleep(0.5)
        now = scan(roots)
        if now == known:
            continue
        time.sleep(0.3)
        now = scan(roots)
        changed = sorted(p for p in now.keys() | known.keys() if now.get(p) != known.get(p))
        known = now
        reloads.send("reload" if publish(arguments.command, changed) else "failed")


try:
    main()
except KeyboardInterrupt:
    pass
