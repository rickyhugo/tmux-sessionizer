# tomlc17

Native C17 TOML parser by CK Tan, under the MIT license in `LICENSE`.
The source files are unmodified.

Revision `aa4ca1bc5fe6382ac631a8d1428077a9a084a64d`.

Source URLs:

- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/src/tomlc17.c
- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/src/tomlc17.h
- https://raw.githubusercontent.com/cktan/tomlc17/aa4ca1bc5fe6382ac631a8d1428077a9a084a64d/LICENSE

SHA-256:

| File | Hash |
| --- | --- |
| `tomlc17.c` | `7476923b6c9b8f0858b82b63ed6107f57448882983390e70c31327f7d3e2a362` |
| `tomlc17.h` | `29c0909092f4b23c7edce705167064f4a90548db5334b4aa2cd95d7ad801adb9` |
| `LICENSE` | `f949d0976f85076c96fc5122f0632b5a1b806d8b2badbe968c42c97230e6e79e` |

`src/config/toml.zig` owns recursive merge semantics. It replaces arrays rather
than using the parser's array-of-tables append operation.
