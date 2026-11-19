# SPDX-License-Identifier: MPL-2.0

"""keycap-server driven headlessly: requests one at a time, each with a
deadline, the server started again once it dies or hangs."""

import json
import os
import selectors
import subprocess
import tempfile
import time


class Died(Exception):
    """The server exited, or was killed for missing a deadline: `why` is
    `panic` or `timeout`, `detail` the end of its stderr."""

    def __init__(self, why, detail):
        super().__init__(f"{why}: {detail}")
        self.why = why
        self.detail = detail


class Server:
    def __init__(self, binary, prelude, threads=None, budget=None):
        self.command = [binary, "--prelude", prelude]
        if threads:
            self.command += ["--threads", str(threads)]
        if budget:
            self.command += ["--gpu-budget", str(budget)]
        self.process = None
        self.stderr = None
        self.next = 0
        self.frame = os.path.join(tempfile.gettempdir(), f"keycap-fuzz-{os.getpid()}.ppm")

    def start(self):
        # The last server's stderr is kept until then, for `log`.
        if self.stderr:
            self.stderr.close()
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
        )
        self.buffer = b""

    def stop(self):
        if self.process:
            self.process.kill()
            self.process.wait()
            self.process = None

    def log(self, lines=6):
        """The end of the server's stderr."""
        self.stderr.seek(0)
        text = self.stderr.read().decode(errors="replace")
        return "\n".join(text.strip().splitlines()[-lines:])

    def call(self, request, timeout=60.0):
        """The reply to `request`, past an export's progress, and the wall
        time it took in milliseconds."""
        if not self.process:
            self.start()
        self.next += 1
        line = json.dumps(dict(request, id=self.next)).encode() + b"\n"
        start = time.perf_counter()
        try:
            self.process.stdin.write(line)
            self.process.stdin.flush()
        except BrokenPipeError:
            return self.died("panic")
        deadline = start + timeout
        while True:
            reply = self.read(deadline)
            if reply.get("id") == self.next and "progress" not in reply:
                return reply, (time.perf_counter() - start) * 1e3

    def read(self, deadline):
        while b"\n" not in self.buffer:
            selector = selectors.DefaultSelector()
            selector.register(self.process.stdout, selectors.EVENT_READ)
            left = deadline - time.perf_counter()
            if left <= 0 or not selector.select(left):
                selector.close()
                return self.died("timeout")
            selector.close()
            chunk = os.read(self.process.stdout.fileno(), 1 << 16)
            if not chunk:
                return self.died("panic")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def died(self, why):
        self.stop()
        raise Died(why, self.log())

    # --- Measurements ---

    def peak_mb(self):
        """The server's peak resident memory since `reset_peak`."""
        with open(f"/proc/{self.process.pid}/status") as status:
            for line in status:
                if line.startswith("VmHWM"):
                    return round(int(line.split()[1]) / 1024, 1)

    def cpu_seconds(self):
        """The processor time the server has used, its threads' together."""
        with open(f"/proc/{self.process.pid}/stat") as stat:
            fields = stat.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")

    def reset_peak(self):
        if not self.process:
            self.start()
        with open(f"/proc/{self.process.pid}/clear_refs", "w") as refs:
            refs.write("5")

    def load(self, source, timeout=60.0):
        return self.call({"op": "load", "source": source, "path": None}, timeout)

    def render(self, width, height, backend, view, timeout=120.0, **extra):
        request = dict(
            op="render", output=self.frame, width=width, height=height,
            backend=backend, view=view, **extra,
        )
        return self.call(request, timeout)

    def pixels(self):
        """The last frame's pixels, as bytes of RGB."""
        with open(self.frame, "rb") as f:
            data = f.read()
        # P6\n<w> <h>\n255\n
        header_end = 0
        for _ in range(3):
            header_end = data.index(b"\n", header_end) + 1
        return data[header_end:]


def errors(reply):
    return [d for d in reply.get("diagnostics", []) if d.get("severity") == "error"]


def script_location(diagnostic):
    """The innermost (line, column) of `diagnostic` in the script itself,
    past the frames in the prelude and imported files."""
    for at in [diagnostic] + diagnostic.get("trace", []):
        if "file" not in at and at.get("line"):
            return at["line"], at["column"]
    return None
