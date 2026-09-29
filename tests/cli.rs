use assert_cmd::Command;
use pretty_assertions::assert_eq;
use ratatui::style::Color;
use std::{fs, os::unix::fs::PermissionsExt, process::Command as ProcessCommand, str::FromStr};
use tempfile::tempdir;
use tms::configs::{
    CloneRepoSwitchConfig, Config, PickerColorConfig, SearchDirectory, SessionSortOrderConfig,
};

#[test]
fn tms_fails_with_missing_config() -> anyhow::Result<()> {
    let dir = tempdir()?;
    let file_path = dir.path().join("config.toml");

    let mut tms = Command::cargo_bin("tms")?;

    tms.env("TMS_CONFIG_FILE", file_path);

    tms.assert()
        .failure()
        .code(1)
        .stderr(predicates::str::contains("Error"))
        .stderr(predicates::str::contains(
            "No default search path was found",
        ));

    Ok(())
}

#[test]
fn tms_config() -> anyhow::Result<()> {
    let directory = tempdir()?;
    let config_file_path = directory.path().join("config.toml");

    let depth = 1;
    let default_session = String::from("my_default_session");
    let excluded_dir = String::from("/exclude/this/directory");
    let picker_highlight_color = Color::from_str("#aaaaaa")?;
    let picker_highlight_text_color = Color::from_str("#bbbbbb")?;
    let picker_border_color = Color::from_str("#cccccc")?;
    let picker_info_color = Color::from_str("green")?;
    let picker_prompt_color = Color::from_str("#eeeeee")?;

    let expected_config = Config {
        default_session: Some(default_session.clone()),
        display_full_path: Some(false),
        search_submodules: Some(false),
        recursive_submodules: Some(false),
        switch_filter_unknown: Some(false),
        session_sort_order: Some(SessionSortOrderConfig::Alphabetical),
        excluded_dirs: Some(vec![excluded_dir.clone()]),
        search_paths: None,
        search_dirs: Some(vec![SearchDirectory::new(
            fs::canonicalize(directory.path())?,
            depth,
        )]),
        sessions: None,
        picker_colors: Some(PickerColorConfig {
            highlight_color: Some(picker_highlight_color),
            highlight_text_color: Some(picker_highlight_text_color),
            border_color: Some(picker_border_color),
            info_color: Some(picker_info_color),
            prompt_color: Some(picker_prompt_color),
        }),
        shortcuts: None,
        bookmarks: None,
        session_configs: None,
        marks: None,
        clone_repo_switch: Some(CloneRepoSwitchConfig::Always),
        vcs_providers: None,
        input_position: None,
        list_worktrees: None,
    };

    let mut tms = Command::cargo_bin("tms")?;

    tms.env("TMS_CONFIG_FILE", &config_file_path)
        .arg("config")
        .args([
            "--paths",
            directory.path().to_str().unwrap(),
            "--max-depths",
            &depth.to_string(),
            "--session",
            &default_session,
            "--full-path",
            "false",
            "--search-submodules",
            "false",
            "--recursive-submodules",
            "false",
            "--switch-filter-unknown",
            "false",
            "--session-sort-order",
            "Alphabetical",
            "--excluded",
            &excluded_dir,
            "--picker-highlight-color",
            &picker_highlight_color.to_string(),
            "--picker-highlight-text-color",
            &picker_highlight_text_color.to_string(),
            "--picker-border-color",
            &picker_border_color.to_string(),
            "--picker-info-color",
            &picker_info_color.to_string(),
            "--picker-prompt-color",
            &picker_prompt_color.to_string(),
            "--clone-repo-switch",
            "Always",
        ]);

    tms.assert().success().code(0);

    let actual_config: Config = toml::from_str(&fs::read_to_string(&config_file_path).unwrap())?;

    assert_eq!(
        expected_config, actual_config,
        "tms config behaves as intended"
    );

    Ok(())
}

#[test]
fn opening_repo_and_worktree_creates_one_session_each_without_extra_windows() -> anyhow::Result<()>
{
    let directory = tempdir()?;
    let repo = directory.path().join("repo");
    let worktree = directory.path().join("worktree");
    fs::create_dir(&repo)?;
    assert!(ProcessCommand::new("git")
        .args(["init", "-b", "main"])
        .current_dir(&repo)
        .status()?
        .success());
    assert!(ProcessCommand::new("git")
        .args(["commit", "--allow-empty", "-m", "init"])
        .current_dir(&repo)
        .env("GIT_AUTHOR_NAME", "tms-test")
        .env("GIT_AUTHOR_EMAIL", "tms-test@example.com")
        .env("GIT_COMMITTER_NAME", "tms-test")
        .env("GIT_COMMITTER_EMAIL", "tms-test@example.com")
        .status()?
        .success());
    assert!(ProcessCommand::new("git")
        .args(["worktree", "add", "-b", "linked"])
        .arg(&worktree)
        .current_dir(&repo)
        .status()?
        .success());

    let config = Config {
        search_dirs: Some(vec![SearchDirectory::new(directory.path().into(), 1)]),
        ..Default::default()
    };
    let config_path = directory.path().join("config.toml");
    fs::write(&config_path, toml::to_string(&config)?)?;

    let bin = directory.path().join("bin");
    fs::create_dir(&bin)?;
    let fake_tmux = bin.join("tmux");
    fs::write(
        &fake_tmux,
        "#!/bin/sh\nprintf '%s\n' \"$*\" >> \"$TMS_TMUX_LOG\"\n",
    )?;
    fs::set_permissions(&fake_tmux, fs::Permissions::from_mode(0o755))?;
    let log = directory.path().join("tmux.log");

    for (name, path) in [("repo", &repo), ("worktree", &worktree)] {
        Command::cargo_bin("tms")?
            .args(["open-session", name])
            .env("TMS_CONFIG_FILE", &config_path)
            .env("TMS_TMUX_LOG", &log)
            .env("TERM_PROGRAM", "tmux")
            .env(
                "PATH",
                format!("{}:{}", bin.display(), std::env::var("PATH")?),
            )
            .assert()
            .success();

        let commands = fs::read_to_string(&log)?;
        assert!(
            commands.contains(&format!(
                "new-session -d -s {name} -c {}",
                fs::canonicalize(path)?.display()
            )),
            "unexpected tmux commands: {commands}"
        );
    }

    let commands = fs::read_to_string(&log)?;
    assert_eq!(commands.matches("new-session ").count(), 2);
    assert!(!commands.contains("new-window"));
    assert!(!commands.contains("move-window"));
    Ok(())
}
