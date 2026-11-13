# Process adapter

`capture`, `inherit`, and `replace` accept literal argv without a shell. A nonzero exit or signal remains termination data.

`capture` returns two slices allocated with the caller's allocator. The caller frees both slices. `MultiReader` drains stdout and stderr concurrently. Read or allocation errors cancel the drains, kill the child, and reap it. A successful wait makes deferred cleanup a no-op.

`inherit` preserves stdout and stderr. Both spawn operations apply the requested stdin mode, cwd, and environment.

`replace` calls `std.process.replace`. It preserves the process ID. Zig 0.17 does not expose replacement stream options, so ignored stdin uses a POSIX descriptor adjustment. The saved descriptor has close-on-exec set. Replacement also applies cwd before exec because Zig 0.17's non-Darwin POSIX backend ignores `ReplaceOptions.cwd`. If replacement fails, the adapter restores stdin and cwd. Callers must restore terminal state before replacement.

`movePath` uses native rename first. If the destination is a directory, the final destination includes the source basename. Rename preserves native overwrite rules. A cross-device failure copies regular files, directories, symlinks, and FIFOs before removing the source. It replaces empty directories but does not merge trees. It rejects a destination inside the source.

The copy context owns an allocator and a device/inode map that preserves hardlinks within the moved tree. Darwin uses libc `copyfile` with full data and metadata flags and explicit no-follow flags. FIFOs use ACL and xattr APIs without opening or reading the FIFO. Linux copies data with native descriptors and preserves ACLs through their native xattrs. Both platforms preserve ownership, exact permissions, access and modification timestamps, and xattrs. Darwin also preserves resource forks.

Copies remain inside a private `0700` staging directory beside the destination. Inherited ACLs are removed from that directory before copying. The completed item replaces the destination by rename. Copy or metadata errors leave the source and existing destination untouched. The source is removed only after preservation and destination replacement succeed. Other special file types return `UnsupportedFileType`. The fallback does not invoke `mv` or a shell.

## Verification

`mise exec -- zig test src/process.zig -lc` runs real-child tests. The helper is the test executable itself. `/bin/sh` is used only by tests.

Coverage includes literal argv, cwd, environment inheritance and replacement, nonzero exits, signals, both output pipes beyond capacity, stdin modes, allocation failures, inherited streams, replacement PID, and failed-replacement restoration. Filesystem tests exercise the fallback directly on one filesystem. They verify contents, hardlinks, ownership, ACLs, xattrs, Darwin resource forks, timestamps, FIFO kind, and exact modes under umask `077`. An allocator observes staging permissions during a partial copy, injects an error, and verifies that the source and old destination survive for retry.

The real cross-device test uses `/dev/shm` on Linux. `TMS_TEST_CROSS_DEVICE_DIR` selects another writable filesystem. Without either location, that test reports a skip. This macOS run has no writable second filesystem, so the actual `CrossDevice` transition remains unverified here. The fallback itself runs on the local filesystem.
