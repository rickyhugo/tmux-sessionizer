# Nix verification

## Environment

Verification ran on 2026-11-13 in the dedicated Colima `tms-zig-check` VM:
native aarch64 Linux, two CPUs, 4 GiB RAM, and a 20 GiB disk.
Docker commands use `--context colima-tms-zig-check`.
The global Docker context remains `default`.
The two additional sandbox-test containers are retained but stopped.

The base image is
`nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed`
with Nix 2.35.6. The retained `tms-zig-nix-privileged` container uses a cached
image containing the locked inputs. A privileged container was necessary for
the nested Nix namespaces; `SYS_ADMIN` and relaxed Docker security profiles
alone did not suffice. No host Nix installation was made.

## Findings and fixes

1. The initial Docker setup could not create Nix namespaces. Its fallback run
   did not prove sandbox operation. Later builds explicitly set
   `sandbox=true` and `sandbox-fallback=false`.
2. Musl test executables initially requested a loader outside the Nix sandbox.
   `build.zig` now explicitly links musl tests statically.
3. Nix deliberately blocks xattr calls with `ENOTSUP`. A minimal Python probe
   failed with the filter enabled and passed with `filter-syscalls=false`.
   An unfiltered full run then reached a separate ACL fixture limitation in
   the Nix user namespace; it was not counted as successful metadata coverage.
4. The package sets `TMS_TEST_ALLOW_UNSUPPORTED_XATTR=1`. Only unsupported
   xattr fixture setup may skip. Preservation assertions remain unchanged.
   Normal tests fail on unsupported xattrs, and the separate native Linux
   suite requires and passes xattr/ACL preservation across devices.
5. A working-tree tar transfer included macOS AppleDouble metadata in notices.
   Final packaging verification uses `git archive 6c4daab`, which contains
   only committed source files.

## Evidence

The integrated source at `3ad4fda`, then clean committed source at `6c4daab`,
passed fresh native package builds with:

```sh
nix build .#default .#tmux-sessionizer --no-link -L \
  --option sandbox true --option sandbox-fallback false \
  --max-jobs 1 --cores 2
```

`nix flake check --all-systems --no-build --no-update-lock-file` evaluates
both package aliases, checks, and development shells on all four systems.
Aliases resolve to the same derivation on each system.
This is evaluation evidence, not four native builds.

Native `nix flake check` passes. `nix develop --command sh -c
'mise --version; mise backends'` reports mise 2026.10.17 and lists `packslip`.
The package generates bash, fish, and zsh completions during installation.

The built static `tms` was copied into the Ubuntu verification container,
which has no Nix store. It passes all 42 command cases and all 21 strict
terminal/popup scenarios. The accompanying Zig oracle passes all 25 stored
ranking vectors.

The final clean package is
`/nix/store/hykakdi675y86zbg6xhdy93lsjplkakd-tmux-sessionizer-0.6.1`.
Its executable SHA-256 is
`bdd989e208da77eca070d92397b6168d94485512ec76f740ca40e81bde92dbbb`.
This exact executable passes the Ubuntu command and terminal suites.
Archive inspection confirms the exact notice set and byte contents, plus
three nonempty shell completion files.

Logs are retained under `.audit/`:

- `nix-final-build.log`: initial successful integrated sandbox build.
- `nix-final-check.log`, `nix-all-systems.log`: native checks and full evaluation.
- `nix-final-devshell.log`: actual shell tool and backend output.
- `nix-runtime.log`: package execution in Ubuntu.
- `nix-release-build.log`: clean committed-source rebuild after Rust retirement.
- `nix-release-runtime.log`: final package command and terminal checks.
- `nix-release-package.tar`: installed package used for notice/completion checks.

Native x86-64 Linux, Intel macOS, and Apple Silicon macOS Nix builds remain
unexecuted locally. The four-system hosted workflow is configured but has not run.
