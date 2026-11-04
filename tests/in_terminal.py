"""Run a command with its own pseudo-terminal, as an interactive agent has one, and relay its output.

With --close-after N, close the terminal after N seconds and exit at once, without waiting for the
command: what a terminal window does when you close it, or when the terminal app quits."""
import os
import sys
import select
import time

args = sys.argv[1:]
close_after = None
if args[0] == "--close-after":
    close_after = float(args[1])
    args = args[2:]

pid, fd = os.forkpty()
if pid == 0:
    os.execv(args[0], args)

deadline = time.time() + close_after if close_after is not None else None
while True:
    timeout = None if deadline is None else max(0, deadline - time.time())
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:  # the deadline passed
        os.close(fd)
        os._exit(0)
    try:
        data = os.read(fd, 4096)
    except OSError:  # Linux reports the child closing the terminal as EIO
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
