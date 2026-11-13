# Reference initialization policy

Reference: Rust `a91ea21780acb58eced5b7f52da7f212f6ca33f0`,
`src/cli.rs::init_repo_command`, calling `gix::init`.

The locked implementation is gix 0.85.0, gix-ref 0.65.0, gix-validate
0.11.2, and gix-config 0.58.0. `init.zig` follows their phases:

1. `gix/src/create.rs::into` refuses existing metadata. It creates the built-in
   templates, object and reference directories, fallback `HEAD` pointing to
   `main`, and filesystem-derived configuration. It does not apply ambient Git
   initialization settings such as `core.sharedRepository`.
2. `gix/src/init.rs::init_opts` opens the resulting repository and its config.
   Configuration errors therefore leave that completed layout behind.
3. It reads `init.defaultBranch`, with `main` as fallback.
   `gix-ref/src/fullname.rs::Category::to_full_name` adds `refs/heads/` only when
   that prefix is absent. `gix-validate/src/reference.rs::branch_name` validates
   the full reference and rejects `refs/heads/HEAD`.
4. Only after validation does it replace `HEAD`, with reflog writes disabled.
   Invalid branches leave the fallback HEAD, all 13 templates, and all object
   directories intact. No tmux session is opened.

The Zig adapter still runs `git init`. Its creation phase has an isolated
configuration and explicit SHA-1, fallback branch, empty external template,
and non-shared policies. Native writes install the reference templates.
The next phase queries the original system/global/repository configuration
and `GIT_CONFIG_COUNT` overrides. `GIT_CONFIG` and `GIT_CONFIG_PARAMETERS`
are Git CLI-specific inputs absent from gix-config's source/from-env logic.
They must not alter that query. Git's test-only initial branch override must
not control creation either.

The branch check uses `git check-ref-format` on the qualified reference,
not its stricter `--branch` mode: the reference accepts short names beginning
with a hyphen. HEAD is replaced natively after validation to avoid introducing
Git reflog or shared-permission policy.

`src/app/review_check.py` checks successful and failed initialization through the
real executable. It checks HEAD, template bytes, exact file/directory membership,
permissions, shared configuration absence, and private tmux session side effects.
Its optional `--rust` control runs the same expectations against the retained
Rust executable. Existing generic Git-error diagnostic wording is unchanged.
