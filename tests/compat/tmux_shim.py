import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(os.environ["TMS_COMPAT_ROOT"])
    args = sys.argv[1:]
    with (root / "tmux-argv.jsonl").open("a") as log:
        log.write(json.dumps(args) + "\n")
    if len(args) < 2 or args[0] != "-L" or (len(args) > 2 and args[2].startswith("-")):
        print("Expected tmux -L SOCKET [COMMAND ...]", file=sys.stderr)
        return 2
    args = args[2:]
    if not args or args[0] in ("attach", "attach-session", "switch-client"):
        target = args[args.index("-t") + 1] if "-t" in args else None
        (root / "client.json").write_text(
            json.dumps({"command": args[0] if args else "tmux", "target": target})
        )
        return 0
    if args[0] == "send-keys":
        with (root / "keys.jsonl").open("a") as log:
            log.write(json.dumps(args[1:]) + "\n")
    command = [
        os.environ["TMS_REAL_TMUX"],
        "-f",
        str(root / "tmux.conf"),
        "-L",
        os.environ["TMS_COMPAT_SOCKET"],
        *args,
    ]
    return subprocess.call(command)


if __name__ == "__main__":
    raise SystemExit(main())
