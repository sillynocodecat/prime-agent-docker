#!/usr/bin/env python3
"""Drive an interactive Prime Agent TUI (inside a container) through a pty.

usage: tui.py --log FILE [--cols N --rows N] STEP... -- COMMAND...
steps:
  expect:REGEX[:TIMEOUT]   wait until the ANSI-stripped output matches REGEX
  send:TEXT                write TEXT (\\r = Enter, \\x04 = Ctrl-D, \\x03 = Ctrl-C)
  sleep:SECONDS
  eof                      wait for the child to exit (timeout 60 s)
Exit status 0 when every step succeeds, 1 on an expect timeout, 2 otherwise.
"""
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]|\x1b[=>]|[\x00-\x08\x0b-\x1f\x7f]")

def strip(b):
    return ANSI.sub("", b.decode("utf-8", "replace"))

def main():
    args = sys.argv[1:]
    log = None; cols, rows = 120, 40
    steps = []
    while args and args[0] != "--":
        a = args.pop(0)
        if a == "--log": log = args.pop(0)
        elif a == "--cols": cols = int(args.pop(0))
        elif a == "--rows": rows = int(args.pop(0))
        else: steps.append(a)
    if not args or args[0] != "--": print("missing -- COMMAND", file=sys.stderr); return 2
    cmd = args[1:]
    out = open(log, "wb") if log else open(os.devnull, "wb")
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    buf = b""; text = ""; alive = True; status = None

    def pump(timeout):
        nonlocal buf, text, alive, status
        r, _, _ = select.select([fd], [], [], timeout)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                alive = False
                return False
            out.write(chunk); out.flush()
            buf += chunk
            text = strip(buf)
            return True
        return False

    rc = 0
    for step in steps:
        kind, _, rest = step.partition(":")
        if kind == "expect":
            pat, _, to = rest.rpartition(":")
            if not pat or not to.replace(".", "").isdigit():
                pat, to = rest, "60"
            deadline = time.time() + float(to)
            rx = re.compile(pat, re.S)
            start = len(text)
            matched = False
            while time.time() < deadline:
                if rx.search(text[max(0, start - 200):]):
                    matched = True; break
                if not alive: break
                pump(min(0.5, max(0, deadline - time.time())))
            print(f"[tui] expect {pat!r}: {'ok' if matched else 'TIMEOUT'}", file=sys.stderr, flush=True)
            if not matched:
                rc = 1; break
        elif kind == "send":
            data = rest.encode().decode("unicode_escape").encode("latin-1")
            os.write(fd, data)
            print(f"[tui] sent {rest!r}", file=sys.stderr, flush=True)
        elif kind == "sleep":
            end = time.time() + float(rest)
            while time.time() < end:
                pump(min(0.5, end - time.time()))
        elif kind == "eof":
            end = time.time() + 60
            while alive and time.time() < end:
                pump(0.5)
            print(f"[tui] eof: {'exited' if not alive else 'STILL RUNNING'}", file=sys.stderr, flush=True)
            if alive: rc = 1
        else:
            print(f"unknown step {step}", file=sys.stderr); rc = 2; break
    # drain briefly, then reap
    end = time.time() + 1.0
    while alive and time.time() < end:
        pump(0.2)
    if alive:
        try: os.kill(pid, signal.SIGHUP)
        except ProcessLookupError: pass
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    out.close()
    tail = text[-1500:]
    print("[tui] tail:\n" + tail, file=sys.stderr, flush=True)
    return rc

if __name__ == "__main__":
    sys.exit(main())
