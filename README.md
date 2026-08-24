# cubicle

Link shared agent config and other files into [git
worktrees](https://git-scm.com/docs/git-worktree).

## Overview

Git worktrees are ideal for running parallel agent sessions on one project,
but makes it difficult to manage untracked files across each worktree. `cubicle`
allows you to have a single source-of-truth for files that should not be in the
main project repository but need to be accessible from each worktree.

A project created with `cubicle` creates:

- a bare git repo (`project/.bare`) with worktrees as plain subdirectories
- a standalone `share/` that can contain your AI-agent configuration and any
    other files that should be shared across worktrees. This directory can be
    version controlled separately if necessary
- a `post-checkout` hook that automatically links each top-level file in
    `share/` into each worktree
- project `info/exclude` rules that prevent the links from showing up in a
    worktree's status output

## Install

Run `make install` or copy `cubicle` somewhere on your `PATH`.

## Quickstart

Start a brand-new project with OpenCode stubs:

```sh
cubicle init --opencode ~/src/myproj # add OpenCode files to share/
cd ~/src/myproj/main
```

Or adopt an existing remote and create Claude stubs:

```sh
cubicle clone --claude https://example.com/me/myproj.git # add Claude files to share/
cd ~/myproj/main
```

Both commands create a bare repository and the `share/` directory. Passing the
`--opencode` option populates it with files for OpenCode while the `--claude`
option creates files for Claude. Omitting these options leaves `share/` empty.
Passing the `--repo` option makes `share` its own git repository.

An empty `share/` is a valid state. Add files any time and run `cubicle link`
to update links in every worktree.

### Workflow

```sh
cd ~/src/myproj

# Edit shared agent config
$EDITOR share/AGENTS.md
git -C share commit -am "update guidance"

# Create a new worktree for a task. Links into `share/` are automatically created
cubicle worktree feature -b feature

# Update links in all worktrees
cubicle link
```

## Commands

Command                                                      | Purpose
-------                                                      | -------
`cubicle clone [--opencode] [--claude] [--repo] URL [DIR]`   | clone URL to DIR (Default: repo basename) and setup `share` and hooks
`cubicle init [--opencode] [--claude] [--repo] DIR [BRANCH]` | same as clone but create a local repo in DIR (with BRANCH as the first worktree. Default: main)
`cubicle worktree ['git worktree add' args] PATH`            | run `git worktree add` and update links in all worktrees
`cubicle link [DIR]`                                         | update links to `share/` items into worktree DIR. Omit DIR to update every worktree
`cubicle check`                                              | check the status of links and the `cubicle` hooks

Global Options:

- `-q | --quiet`: suppress non-warning output
- `-h | --help`:  print help
- `-V | --version` print version

## How it works

- **Links:** top-level entries of `share/`, including hidden files (`.git*`
    files are skipped) are symlinked into each worktree.  Any existing links or
    files are left alone and dangling links are repaired.  `check` reports stale
    managed links whose config item was removed from `share/`.
- **Git Hook:** a code block that runs `cubicle link` after every checkout or
    worktree-add is added to `<common-git-dir>/hooks/post-checkout`.
    Pre-existing hooks are not overwritten.
- **Git Excludes:** the linked contents of `share/` are added to
    `<common-git-dir>/info/exclude` so links are invisible to `git status` in
    every worktree.

## License

GPLv3+. Copyright 2026 Jeremy Brubaker.
