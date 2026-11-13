#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
[[ $(uname -s) == Linux ]] || {
	echo "Linux is required." >&2
	exit 2
}
output=${1:-.audit/linux}
mkdir -p "$output"
output=$(realpath "$output")
source_sha=${TMS_SOURCE_SHA:-$(git rev-parse HEAD)}
export TMS_TEST_CROSS_DEVICE_DIR=${TMS_TEST_CROSS_DEVICE_DIR:-/dev/shm}
export TMS_TEST_ALLOW_UNSUPPORTED_XATTR=0

command -v mise >/dev/null
[[ $(zig version) == 0.17.1 ]]
[[ $(jj --version) == "jj 0.38.0"* ]]
[[ $(tmux -V) == "tmux 3.8" ]]
[[ $(python3 --version) == "Python 3.14.7" ]]
[[ $(stat -c %d .) != $(stat -c %d "$TMS_TEST_CROSS_DEVICE_DIR") ]]
[[ -w $TMS_TEST_CROSS_DEVICE_DIR ]]

{
	printf 'source=%s\n' "$source_sha"
	date -u +%FT%TZ
	uname -a
	cat /etc/os-release
	mise --version
	zig version
	jj --version
	tmux -V
	python3 --version
	git --version
	id
	stat -f -c '%T %d' . "$TMS_TEST_CROSS_DEVICE_DIR"
	stat -c '%d %n' . "$TMS_TEST_CROSS_DEVICE_DIR"
} | tee "$output/environment.log"

failed=()
: >"$output/status.txt"
run() {
	local name=$1 status
	shift
	printf '\nRunning %s\n' "$name"
	if "$@" 2>&1 | tee "$output/$name.log"; then
		status=0
	else
		status=$?
		failed+=("$name")
	fi
	last_status=$status
	printf '%s=%s\n' "$name" "$status" | tee -a "$output/status.txt"
}

run process zig test src/process.zig -lc
run non-utf8 zig test -lc --dep config --dep process -Mroot=src/repos.zig \
	-I vendor/tomlc17 -cflags -std=c17 -- vendor/tomlc17/tomlc17.c \
	-Mconfig=src/config.zig -Mprocess=src/process.zig \
	--test-filter "non UTF8 ordinary filename"
run modules zig build test -j2 --summary all
run harness-compat python3 -m unittest discover -s tests/compat -p 'test_*.py'
run harness-terminal python3 -m unittest discover -s tests/terminal -p 'test_*.py'
run packaging python3 -m unittest discover -s tests/packaging -p 'test_*.py'
run adapters python3 src/app/check.py --real-tmux
run picker-regressions python3 src/picker/regression-pty.py
run build zig build -j2 -Doptimize=ReleaseFast --summary all
if ((last_status == 0)); then
	run cli-errors python3 src/cli/error_check.py --bin zig-out/bin/tms
	run repository-regressions python3 src/app/review_check.py --binary zig-out/bin/tms
	run terminal python3 scripts/terminal_checks.py --binary zig-out/bin/tms \
		--require-improvements --output "$output/terminal"
	run compat python3 scripts/compat.py --jj --bin zig-out/bin/tms \
		--oracle zig-out/bin/tms-oracle --artifacts "$output/compat"
	sha256sum zig-out/bin/tms zig-out/bin/tms-oracle | tee "$output/binaries.sha256"
fi

if ((${#failed[@]})); then
	printf 'Failed checks: %s\n' "${failed[*]}" >&2
	exit 1
fi
