"""Run a command with its own pseudo-terminal, as an interactive claude has one, and relay its output."""
import os
import sys

pid, fd = os.forkpty()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:  # Linux reports the child closing the terminal as EIO
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
