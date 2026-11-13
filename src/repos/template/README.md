# Reference initialization templates

Copied unchanged from `gix` 0.85.0, `src/assets/init`, used by Rust reference
`a91ea21780acb58eced5b7f52da7f212f6ca33f0`.

Upstream: https://github.com/GitoxideLabs/gitoxide/tree/gix-v0.85.0/gix/src/assets/init

These files retain the reference's built-in templates independently of installed
Git templates, `GIT_TEMPLATE_DIR`, and `init.templateDir`. They are embedded in the
executable and written with native filesystem operations. Git still initializes
the repository. Git owns HEAD, with the reference's `main` fallback.

The upstream MIT license is reproduced in `LICENSE`. No gix runtime is required.
