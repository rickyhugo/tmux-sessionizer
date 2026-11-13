# Process adapter

`capture`, `inherit`, and `replace` accept literal argv without a shell. A nonzero exit or signal remains termination data.

`capture` returns two slices allocated with the caller's allocator. The caller frees both slices. `MultiReader` drains stdout and stderr concurrently. Read or allocation errors cancel the drains, kill the child, and reap it. A successful wait makes deferred cleanup a no-op.

`inherit` preserves stdout and stderr. Both spawn operations apply the requested stdin mode, cwd, and environment.

`replace` calls `std.process.replace`. It preserves the process ID. Zig 0.17 does not expose replacement stream options, so ignored stdin uses a POSIX descriptor adjustment. The saved descriptor has close-on-exec set. Replacement also applies cwd before exec because Zig 0.17's non-Darwin POSIX backend ignores `ReplaceOptions.cwd`. If replacement fails, the adapter restores stdin and cwd. Callers must restore terminal state before replacement.

`movePath` uses native rename first. If the destination is a directory, the final destination includes the source basename. Rename preserves native overwrite rules. A cross-device failure copies regular files, directories, symlinks, and FIFOs before removing the source. It replaces empty directories but does not merge trees. It rejects a destination inside the source.

The copy context owns an allocator and a device/inode map that preserves hardlinks within the moved tree. Darwin uses libc `copyfile` for data and metadata, without its ACL flag, and with explicit no-follow flags. FIFOs use ACL and xattr APIs without opening or reading the FIFO. Linux copies data with native descriptors and preserves ACLs through their native xattrs. Both platforms preserve ownership, exact permissions, access and modification timestamps, and xattrs. Darwin also preserves resource forks.

Copies remain inside a private `0700` staging directory beside the destination. Inherited ACLs are removed from that directory before copying. The completed item replaces the destination by rename. Copy or metadata errors leave the source and existing destination untouched. Rollback clears ACLs and restores owner permissions inside staging before removal. It does not follow symlinks or change the source or destination modes. Cleanup errors are returned, not discarded. The source is removed only after preservation and destination replacement succeed. Other special file types return `UnsupportedFileType`. The fallback does not invoke `mv` or a shell.

## Darwin ACL policy

The copy preserves all source ACEs, including inherited entries, in their original order. Destination-inherited entries follow the source entries. A source ACL with `ACL_FLAG_NO_INHERIT` suppresses destination inheritance. Directory and file inheritance, `only_inherit`, and `limit_inherit` follow [Darwin's inheritance rules](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_authorization.c#L794-L926). Destination inheritance travels separately through the copied tree, without granting access through the staging directory. ACLs are applied after data, other metadata, and children are complete.

This differs deliberately from [Apple's `copyfile_security`](https://github.com/apple-oss-distributions/copyfile/blob/9f91eb6ced021952278816cdc76ad68da8631ccb/copyfile.c#L3133-L3240), which drops inherited source ACEs. The Rust command invokes `mv`. [Apple's `mv`](https://github.com/apple-oss-distributions/file_cmds/blob/659a8a301e2acf0343f8b8673a154a2ca4d07084/mv/mv.c#L363-L370) uses that ACL behavior through `fcopyfile` for files and `cp -PRp` for directories. A macOS 26.6.2 APFS-to-APFS disk-image probe confirmed that `/bin/mv` removes inherited source deny and allow entries for both kinds. All four moves exited successfully. The native fallback retains those entries rather than losing source protections or grants. When the source has no inherited ACEs, destination inheritance matches native creation.

## Verification

`mise exec -- zig test src/process.zig -lc` runs real-child tests. The helper is the test executable itself. `/bin/sh` is used only by tests.

Coverage includes literal argv, cwd, environment inheritance and replacement, nonzero exits, signals, both output pipes beyond capacity, stdin modes, allocation failures, inherited streams, replacement PID, and failed-replacement restoration. Filesystem tests exercise the fallback directly on one filesystem. They verify contents, hardlinks, ownership, ACLs, xattrs, Darwin resource forks, timestamps, FIFO kind, and exact modes under umask `077`. Darwin ACL fixtures cover absent, inherited allow, inherited deny, and no-inherit ACLs on files and directories. Expected destination inheritance comes from objects created by the kernel, not from the copy implementation. Access checks verify inherited grants and denies before and after the move. A real rename failure against a nonempty destination verifies rollback of a nonempty `0500` directory and preservation of a symlink's outside target. An allocator also checks staging privacy during a partial copy and injects an allocation failure.

The real cross-device tests use `/dev/shm` on Linux. `TMS_TEST_CROSS_DEVICE_DIR` selects another writable filesystem. Without either location, those tests report a skip. On macOS, a temporary, unprivileged 64 MiB APFS disk image exercised the actual `CrossDevice` transition, metadata preservation, and the ACL fixtures. All 19 process tests passed with no skips. The image was detached and removed. HFS+ rounds timestamps to seconds and cannot pass the nanosecond preservation assertions. Linux x86_64 and aarch64 cross-compilation passed. Linux runtime checks remain unverified on this host.

Parent verification also passed all 19 tests against an APFS image attached with
`hdiutil attach -owners on`. The first run without that option failed the group-ID
assertion because the mount ignored ownership. Ownership must be enabled for this
preservation check. Both images were detached and removed.
