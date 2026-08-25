# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project bootstrap via `clone` and `init`: a `.bare` repository, a standalone
  `share/` directory beside it, and a first worktree named after the default
  branch (`init.defaultBranch`, else `main`)
- Link engine: top-level entries of `share/` (hidden files included, `.git*`
  skipped) symlinked into every worktree root using relative targets; dangling
  links repaired; real files and symlinks pointing elsewhere never touched
- Managed `post-checkout` hook delimited by `# CUBICLE-MANAGED-HOOK BEGIN/END`
  markers; all other hook content preserved
- Anchored `<common-git-dir>/info/exclude` rules keeping managed links out of
  `git status`
- `--opencode` / `--claude` stub bundles creating empty placeholders
  (`AGENTS.md` + `.opencode/`, `CLAUDE.md` + `.claude/`); `--repo` turns
  `share/` into its own git repository that cubicle never commits to
