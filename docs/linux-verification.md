# Linux verification

This report checks the behavior-preserving Zig rewrite on native Linux.
The run uses real Git, jj, tmux, PTYs, and a second filesystem.
It does not change compatibility goldens or test assertions.

## Review-fix process verification

The full repaired source at `6a16a34` passed all 13 verification steps in
`/work-review-final`. It used `git archive`, the pinned toolchain, and the
unprivileged `verifier` account. Results:

- 131 module tests passed; eight expected skips.
- 29 process tests passed; three Darwin-only skips. Both real cross-device
  fixtures passed with xattrs required.
- 32 harness/packaging tests, 56 CLI diagnostic cases, 45 completion cases,
  and 35 repository/session scenarios passed.
- 42 stored command cases, 25 ranking vectors, 21 strict PTY/popup scenarios,
  and 16 focused picker scenarios passed.

Evidence: `.audit/linux-review-final.log` and the container's
`/work-review-final/.audit/linux-review-final`.
Executable SHA-256:
`c3c83998b75d9fa92350964cbc69fe780f4582b1772bedbd7ba6cb780ca20674`.

The process changes at `05adc93` passed in `/work-review-process` in the
native aarch64 Ubuntu container. The source was transferred with `git archive`
and tested as the unprivileged `verifier` user with pinned Zig 0.17.1.

All 24 applicable process tests passed; three Darwin-only cases skipped.
Both actual cross-device fixtures passed with xattr support required.
The new checks cover closed stdin, descriptor flags, setup-failure rollback,
allocation failure with remapping allocators, and cancellation with child reaping.
Evidence: `.audit/review-process-linux.log`.

The follow-up at `1daa7c9` also passed in `/work-review-process-kill`:
29 tests passed and three Darwin-only cases skipped. This run includes
SIGTERM-resistant child cleanup after allocation failure, capture cancellation,
EOF wait cancellation, and inherited-stream cancellation. Both cross-device
fixtures still passed with xattr support required.
Evidence: `.audit/review-process-kill-linux.log`.

The earlier hosted x86_64 Nix failure exposed a fault-injection defect:
successful remaps bypassed the allocator's allocation-failure counter.
The repaired injector disables resize/remap, and infinite-output helpers have
timeouts. Native x86_64 execution of the repair remains a hosted-check gate.

## Final integration verification

The coordinator reran `scripts/linux-check.sh` against `3ad4fda` in
`/work-final`, using the same native aarch64 VM and pinned tools below.
All ten script steps returned zero. The tested application source also matches
the Rust-retirement commit `6c4daab`: SHA-256 comparison checked 72 build,
source, and vendor files against the running containers.

| Check | Result |
| --- | --- |
| Process suite | 18 passed; three Darwin-only skips |
| Cross-device content and metadata fixtures | Both passed |
| Non-UTF-8 filename fixture | Passed |
| Module suite | 97 passed; eight expected skips |
| Repository suite | All 31 passed |
| Compatibility and terminal harnesses | All 22 passed |
| Command adapters | All 23 passed, plus real comma-session PTY |
| Focused picker regressions | All nine passed |
| Command compatibility | All 42 passed |
| Stored ranking vectors | All 25 passed |
| Strict PTY and popup scenarios | All 21 passed |

The eight module skips are three Darwin-specific process cases and five app
fixtures that require the fake process adapter. No Linux metadata case skipped.
The script sets `TMS_TEST_ALLOW_UNSUPPORTED_XATTR=0`; xattr or ACL fixture
failures cannot silently pass.

Release executable SHA-256:
`c210ba0ab3cf25dceea4213aa2749bfab1fe9ba30a4738f320ff10e8f0db946d`.
Oracle SHA-256:
`92cb0fc64d2c1497c6f21c92d92f00a5a758709aa5497ab537121f4afd494d4c`.

Logs and transcripts are retained in `.audit/linux-final` both in the
integration checkout and the container. The top-level transcript is
`.audit/linux-final.log`; `.audit/final-source.sha256` records source hashes.
Earlier runs below are historical and include differences now fixed.

## Source and environment

The initial source is `4e46c618c075c0d208383cd0e982d0cc15b45c1a`.
The process-stage source is `0285a64c9f5bf93fa2121ffff195c37b64e9210d`.
That commit adds process fixes from `a6358adc79fdfa5f1c891e5c1e60214b689ddc12`.
The final source is `2c7ca907e36357ba3f1b5fe060548cfd7caf9daa`.
It also adds picker fixes from `1369083779ea696000178b02dac6826dfec5d063`.
SHA-256 checks confirm that every tracked file in each Linux copy matches its source commit.
The verification script and this report are additional files.

The run date is 2026-11-13.

| Item | Observed value |
| --- | --- |
| VM | Colima `tms-zig-check`, Apple Virtualization, native aarch64 |
| Resources | 2 CPUs, 4 GiB RAM, 20 GiB data disk |
| Kernel | `6.8.0-117-generic`, Ubuntu, aarch64 |
| Container | Ubuntu 24.04.5 LTS |
| Image digest | `ubuntu@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5` |
| mise | 2026.11.7 |
| Zig | 0.17.1 |
| jj | `0.38.0-2508982cde5c7e4db0933e0b6469f9e778e71e28` |
| tmux | 3.8 |
| Python | 3.14.7 |
| Git | 2.56.0, built from the kernel.org source archive |
| Source filesystem | `/work`, overlayfs, device 47 |
| Destination filesystem | `/dev/shm`, tmpfs, device 60 |

mise installed the four requested pinned tools without version substitutions.
The updated process checks run as the unprivileged `verifier` user.
The source is copied into the container rather than tested on a macOS shared filesystem.
The only host bind mount is the verification worktree, read-only at `/input`.

## Initial results

The initial run used Git 2.43.0 from Ubuntu.

| Check | Result |
| --- | --- |
| Process tests | 16 passed, no skips |
| Non-UTF-8 filename fixture | Passed, no skip |
| Module tests | 86 passed, five skipped, one failed |
| ReleaseFast build | Passed |
| Strict PTY and popup checks | All 21 passed |
| Command compatibility | 40 of 42 passed |
| Stored ranking vectors | All 25 passed |

The module failure is the fixture that requires relative Git worktree metadata.
Git 2.43.0 accepts `worktree.useRelativePaths` as configuration but writes an absolute `gitdir` path.
The fixture fails at `src/repos/tests.zig:217`, before the tested resolver runs.
The updated run uses Git 2.56.0.
No fixture was weakened for the older Git version.

The two command failures are the known `invalid-toml` diagnostic and `jj-workspaces` completion differences.
The invalid-TOML output is `(line 2) missing value` instead of Rust's detailed array diagnostic.
The jj completion output adds `linked` and `project` before `--help`.

## Pre-final results

| Check | Result |
| --- | --- |
| Process tests | 18 passed, one Darwin-only skip |
| Non-UTF-8 filename fixture | Passed, no skip |
| Module tests, fresh cache | 94 passed, six skipped, zero failures |
| Compatibility harness tests | Six passed |
| Terminal driver tests | 16 passed |
| Adapter checks | 23 passed, plus the real comma-session PTY check |
| Focused picker PTY regressions | All seven passed |
| ReleaseFast build | Passed |
| Strict PTY and popup checks | All 21 passed |
| Command compatibility | 40 of 42 passed, the same two known differences |
| Stored ranking vectors | All 25 passed |

The module skips are the Darwin-only ACL fixture and five app fixtures that require the fake process adapter.
All 31 repository tests pass with Git 2.56.0.
The real non-UTF-8 fixture creates both a `0xff` filename and a `0xff` directory.
It exercises discovery and exclusion behavior rather than returning a platform skip.

The optimized `tms` SHA-256 is `526374537a09217c5c08eeddbf6a7457ca770d76696f40e46aaa8903cd743694`.
The ranking oracle SHA-256 is `464c4c44d2d79bde44754ae8bff16da1ff5f23ec60c410ab58eb0df64bb05d65`.
The executable reports `tmux-sessionizer 0.6.1`.

The seven focused checks cover fragmented invalid UTF-8, buffered double Escape, saturated-output signal cleanup, partial output, and Arabic, Lisu, and Hebrew layouts.
The full strict suite separately verifies real tmux popup and attached-client behavior.

The updated standalone process run reports 18 passed, one skipped, zero failed.
Only the inherited-Darwin-ACL fixture skips on Linux.

Both actual cross-device fixtures pass:

- `native move crosses devices when a writable second filesystem is available`.
- `native move preserves metadata and ACLs across a real device boundary`.

The coordinator independently reran the process suite in the retained container.
It passed 18 tests with only the Darwin ACL fixture skipped. A separate rerun of
the non-UTF-8 filename fixture also passed.

The first fixture verifies that native rename returns `CrossDevice` before calling `movePath`.
The second covers contents, hardlinks, symlinks, FIFO kind, ownership, permissions, timestamps, xattrs, and Linux ACLs.
The failed-publication fixture also passes with a nonempty `0500` directory and an outside symlink target.

## Recorded setup

The dedicated profile reused Colima's cached VM image.
The start command was:

```sh
	colima start tms-zig-check --activate=false --cpus 2 --memory 4 --disk 20 \
		--mount /Users/hugo.englund/personal/tms-zig-linux-check \
		--ssh-config=false --binfmt=false
```

Docker commands use `--context colima-tms-zig-check`.
The user's default profile remains stopped.
The global Docker context remains `default`.
The dedicated VM and `tms-zig-linux-check` container remain available for follow-up validation.

The Ubuntu container has these system prerequisites:

```sh
	apt-get install -y ca-certificates curl git xz-utils libevent-2.1-7t64 \
		libncursesw6 locales procps attr acl build-essential libssl-dev \
		libcurl4-gnutls-dev libexpat1-dev zlib1g-dev
```

The tool installation command was:

```sh
	mise install zig@0.17.1 jj@0.38.0 tmux@3.8 python@3.14.7
```

Git 2.56.0 comes from `https://www.kernel.org/pub/software/scm/git/git-2.56.0.tar.xz`.
Its build and install use `prefix=/opt/git NO_RUST=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease`.
Without `NO_RUST`, Git's build requires Cargo.

## Rerunnable checks

`scripts/linux-check.sh` checks Linux, exact tool versions, and distinct writable filesystems before running tests.
It records environment details, command output, exit statuses, binary hashes, and PTY transcripts.
It does not convert known compatibility failures into success.
It returns nonzero for any failing step. The final integrated run returns zero.

The pre-final run command in the retained container was:

```sh
	docker --context colima-tms-zig-check exec -w /work \
		-e TMS_SOURCE_SHA=2c7ca907e36357ba3f1b5fe060548cfd7caf9daa \
		tms-zig-linux-check /root/.local/bin/mise exec \
		zig@0.17.1 jj@0.38.0 tmux@3.8 python@3.14.7 -- \
		runuser -u verifier --preserve-environment -- bash -c '
			export HOME=/home/verifier PATH=/root/.local/bin:/opt/git/bin:$PATH
			export MISE_DATA_DIR=/root/.local/share/mise MISE_TRUSTED_CONFIG_PATHS=/work
			export MISE_EXEC_AUTO_INSTALL=false
			bash scripts/linux-check.sh .audit/linux-complete
		'
```

`TMS_SOURCE_SHA` records the supplied snapshot identity when the isolated copy has no `.git` directory.
Without that variable, the script records `git rev-parse HEAD`.
`TMS_TEST_CROSS_DEVICE_DIR` defaults to `/dev/shm`.
An optional first argument selects the output directory.
The focused picker driver invokes mise internally.
The exported mise directory lets the unprivileged user reuse the container's pinned tools.
Automatic installation is disabled for that nested invocation.
Rust and hk are not needed by these checks and are not installed in the container.

The additional fresh-cache module command was:

```sh
	zig build test -j2 --cache-dir .zig-cache/linux-final-fresh --summary all
```

The `.audit/linux-complete` directory contains the final logs, hashes, normalized tmux traces, and raw PTY transcripts.
It is retained both in the container and in the host verification worktree.
The source checksum manifest is `.audit/linux/source-final.sha256`.
The final summary records `suite=1 fresh-modules=0`.
The suite failure is only the two known command differences.

## Nix availability

A separate native aarch64 container ran `nix --version` successfully.
It reports Nix 2.35.6.
The image is `nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed`.
The probe container used `--rm` and is gone.
The image remains cached in the dedicated profile.
Subsequent package and sandbox verification is recorded in
[Nix verification](nix-verification.md).
