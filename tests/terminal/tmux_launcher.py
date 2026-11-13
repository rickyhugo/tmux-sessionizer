import os
import sys


def main(real_tmux, socket):
    args = sys.argv[1:]
    if args[:2] != ["-L", socket] or (
        len(args) > 2 and (not args[2] or args[2].startswith("-"))
    ):
        print("Expected tmux -L FIXTURE_SOCKET [COMMAND ...]", file=sys.stderr)
        return 2
    os.execv(real_tmux, [real_tmux, "-L", socket, "-f", os.devnull, *args[2:]])
