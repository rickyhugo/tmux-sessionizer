#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
	echo "Usage: mise run install -- [PREFIX]" >&2
	exit 2
fi

prefix=${1:-"$HOME/.local"}
cd "$(dirname "$0")/.."
test -x zig-out/bin/tms
mkdir -p "$prefix/bin"
install -m 755 zig-out/bin/tms "$prefix/bin/tms"
python3 scripts/package.py notices --dest "$prefix/share/licenses/tms"
printf 'Installed %s/bin/tms. Add %s/bin to PATH.\n' "$prefix" "$prefix"
