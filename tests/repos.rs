use std::{fs, path::PathBuf, process::Command};

use tempfile::tempdir;
use tms::configs::{Config, SearchDirectory, VcsProviders};
use tms::repos::{find_repos, LazyRepoProvider};
use tms::session::SessionType;

fn config_searching(path: PathBuf, depth: usize) -> Config {
    Config {
        search_dirs: Some(vec![SearchDirectory::new(path, depth)]),
        ..Default::default()
    }
}

fn git_commit(repo: &std::path::Path) {
    Command::new("git")
        .args(["commit", "--allow-empty", "-m", "init"])
        .current_dir(repo)
        .env("GIT_AUTHOR_NAME", "tms-test")
        .env("GIT_AUTHOR_EMAIL", "tms-test@example.com")
        .env("GIT_COMMITTER_NAME", "tms-test")
        .env("GIT_COMMITTER_EMAIL", "tms-test@example.com")
        .status()
        .expect("git commit");
}

#[test]
fn find_repos_includes_gitlink_project() {
    let dir = tempdir().unwrap();
    let search = dir.path().join("search");
    let project = search.join("my-project");
    fs::create_dir_all(&project).unwrap();
    let search = fs::canonicalize(&search).unwrap();
    Command::new("git")
        .args(["init", "--bare"])
        .arg(project.join(".bare"))
        .status()
        .unwrap();
    fs::write(project.join(".git"), "gitdir: .bare\n").unwrap();

    let repos = find_repos(&config_searching(search, 2)).unwrap();

    assert!(
        repos.contains_key("my-project"),
        "expected gitlink project in picker results, got: {:?}",
        repos.keys().collect::<Vec<_>>()
    );
}

#[test]
fn find_repos_includes_worktrees() {
    let dir = tempdir().unwrap();
    let search = dir.path().join("search");
    let project = search.join("my-project");
    fs::create_dir_all(&project).unwrap();
    let search = fs::canonicalize(&search).unwrap();
    Command::new("git")
        .args(["init", "--bare"])
        .arg(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "main"])
        .current_dir(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "test"])
        .current_dir(&project)
        .status()
        .unwrap();
    let mut config = config_searching(search, 2);
    config.list_worktrees = Some(true);

    let repos = find_repos(&config).unwrap();

    assert!(repos.contains_key("my-project"));
    assert!(repos.contains_key("my-project#main"));
    assert!(repos.contains_key("my-project#test"));
    assert_eq!(repos.len(), 3);
}

#[test]
fn find_repos_includes_worktrees_with_relative_paths() {
    let dir = tempdir().unwrap();
    let search = dir.path().join("search");
    let project = search.join("my-project");
    fs::create_dir_all(&project).unwrap();
    let search = fs::canonicalize(&search).unwrap();
    Command::new("git")
        .args(["init", "--bare"])
        .arg(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["config", "worktree.useRelativePaths", "true"])
        .current_dir(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "main"])
        .current_dir(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "test"])
        .current_dir(&project)
        .status()
        .unwrap();

    // Ensure `worktree.useRelativePaths` took effect.
    let gitdir = fs::read_to_string(project.join("worktrees/main/gitdir")).unwrap();
    assert!(
        gitdir.trim_start().starts_with(".."),
        "expected a relative gitdir, got: {gitdir:?}"
    );

    let mut config = config_searching(search, 2);
    config.list_worktrees = Some(true);

    let repos = find_repos(&config).unwrap();

    assert!(repos.contains_key("my-project"));
    assert!(repos.contains_key("my-project#main"));
    assert!(repos.contains_key("my-project#test"));
    assert_eq!(repos.len(), 3);
}

#[test]
fn find_repos_includes_linked_worktree_as_separate_session() {
    let dir = tempdir().unwrap();
    let search = dir.path().join("search");
    fs::create_dir_all(&search).unwrap();
    let search = fs::canonicalize(&search).unwrap();
    let main_repo = search.join("main-repo");
    let linked = search.join("linked");
    fs::create_dir_all(&main_repo).unwrap();

    Command::new("git")
        .args(["init", "-b", "main"])
        .current_dir(&main_repo)
        .status()
        .unwrap();
    git_commit(&main_repo);
    Command::new("git")
        .args(["worktree", "add", "-b", "linked"])
        .arg(&linked)
        .current_dir(&main_repo)
        .status()
        .unwrap();

    let linked_repo = LazyRepoProvider::new(&linked, &[VcsProviders::Git]).unwrap();
    assert!(
        linked_repo.is_worktree().unwrap(),
        "linked checkout should be classified as a worktree"
    );

    let repos = find_repos(&config_searching(search, 2)).unwrap();

    assert!(
        repos.contains_key("main-repo"),
        "expected main repository in picker results, got: {:?}",
        repos.keys().collect::<Vec<_>>()
    );
    assert!(
        repos.contains_key("linked"),
        "linked worktree should appear in picker results, got: {:?}",
        repos.keys().collect::<Vec<_>>()
    );
    assert_eq!(repos.len(), 2);
    let SessionType::Git(linked_session) = &repos["linked"][0].session_type else {
        panic!("linked should be a Git session");
    };
    assert_eq!(linked_session.path, linked);
}

#[test]
fn find_repos_worktree_entry_is_a_worktree() {
    let dir = tempdir().unwrap();
    let search = dir.path().join("search");
    let project = search.join("my-project");
    fs::create_dir_all(&project).unwrap();
    let search = fs::canonicalize(&search).unwrap();
    Command::new("git")
        .args(["init", "--bare"])
        .arg(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "main"])
        .current_dir(&project)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "test"])
        .current_dir(&project)
        .status()
        .unwrap();
    let mut config = config_searching(search, 2);
    config.list_worktrees = Some(true);

    let repos = find_repos(&config).unwrap();

    let main_entry = repos
        .get("my-project#main")
        .expect("expected a my-project#main entry");
    let SessionType::Git(main_worktree) = &main_entry[0].session_type else {
        panic!("my-project#main should be a Git session");
    };
    assert!(
        main_worktree.is_worktree().unwrap(),
        "opening my-project#main should open only the `main` worktree, not fan out into siblings"
    );

    let repo_entry = repos
        .get("my-project")
        .expect("expected a my-project entry");
    let SessionType::Git(whole_repo) = &repo_entry[0].session_type else {
        panic!("my-project should be a Git session");
    };
    assert!(
        !whole_repo.is_worktree().unwrap(),
        "the bare repo itself is not a worktree"
    );
}

#[test]
fn bare_repo_worktree_is_classified_as_worktree() {
    let dir = tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let bare = root.join("project");
    Command::new("git")
        .args(["init", "--bare"])
        .arg(&bare)
        .status()
        .unwrap();
    Command::new("git")
        .args(["worktree", "add", "master"])
        .current_dir(&bare)
        .status()
        .unwrap();

    let worktree = LazyRepoProvider::new(&bare.join("master"), &[VcsProviders::Git]).unwrap();

    assert!(
        worktree.is_worktree().unwrap(),
        "a worktree of a bare repo should be classified as a worktree"
    );
}
