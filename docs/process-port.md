# Process adapter

`capture`, `inherit`, and `replace` accept literal argv without a shell. A nonzero exit or signal remains termination data.

`capture` returns two slices allocated with the caller's allocator. The caller frees both slices. `MultiReader` drains stdout and stderr concurrently. Read or allocation errors cancel the drains, kill the child, and reap it. A successful wait makes deferred cleanup a no-op.

`inherit` preserves stdout and stderr. Both spawn operations apply the requested stdin mode, cwd, and environment.

`replace` calls `std.process.replace`. It preserves the process ID. Zig 0.17 does not expose replacement stream options, so ignored stdin uses a POSIX descriptor adjustment. The saved descriptor has close-on-exec set. Replacement also applies cwd before exec because Zig 0.17's non-Darwin POSIX backend ignores `ReplaceOptions.cwd`. If replacement fails, the adapter restores stdin and cwd. Callers must restore terminal state before replacement.

`movePath` uses native rename first. If the destination is a directory, the final destination includes the source basename. Rename preserves native overwrite rules. A cross-device failure copies regular files, directories, and symlinks before removing the source. The fallback preserves permissions and timestamps. It replaces empty directories but does not merge trees. It rejects a destination inside the source.

The fallback does not preserve hard-link relationships, ownership, ACLs, or extended attributes. Special file types return `UnsupportedFileType`.

## Verification

`mise exec -- zig test src/process.zig -lc` runs real-child tests. The helper is the test executable itself. `/bin/sh` is used only by tests.

Coverage includes literal argv, cwd, environment inheritance and replacement, nonzero exits, signals, both output pipes beyond capacity, stdin modes, allocation failures, inherited streams, replacement PID, and failed-replacement restoration. Filesystem tests cover rename and the copy/remove fallback.

The real cross-device test uses `/dev/shm` on Linux. `TMS_TEST_CROSS_DEVICE_DIR` selects another writable filesystem. Without either location, that test reports a skip. This macOS run has no writable second filesystem, so the actual `CrossDevice` transition remains unverified here. The fallback itself runs on the local filesystem.
