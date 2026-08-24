#!/bin/sh
# run.sh -- run the cubicle test suite
#
# Isolates the environment (git identity, config, HOME) so results do not
# depend on the host.

set -u

cd "$(dirname "$0")" || exit 1

# Isolation: no user/system git config, deterministic identity, private HOME.
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cubicle-run.XXXXXXXX")
CUBICLE_ROOT=$(pwd)/..
export CUBICLE_ROOT
export SANDBOX_ROOT
export HOME="$SANDBOX_ROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_TEMPLATE_DIR || :
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export TZ=UTC LANG=C LC_ALL=C

# shellcheck disable=SC1091
. ./harness.sh

# Hooks resolve cubicle via PATH at fire time (by design, no absolute paths
# embedded), so the suite needs cubicle on PATH exactly like a real
# installation. Symlink it into a sandbox bin dir.
mkdir -p "$SANDBOX_ROOT/bin"
ln -sf "$CUBICLE_BIN" "$SANDBOX_ROOT/bin/cubicle"
PATH="$SANDBOX_ROOT/bin:$PATH"
export PATH

# --- harness self-checks ----------------------------------------------------
#
# 1. A deliberately failing case must be counted as FAIL. Guards against any
#    future change that would let assertion failures pass silently.
_selfcheck_fail() { echo "intentional failure"; exit 1; }
_pass0=$PASS
_fail0=$FAIL
t 'selfcheck: failing case detected' _selfcheck_fail
if [ "$FAIL" -ne $((_fail0 + 1)) ] || [ "$PASS" -ne "$_pass0" ]; then
    say "FATAL: harness self-check failed -- assertions are being masked"
    exit 99
fi
FAIL=$_fail0   # restore: the canary's failure must not count against the suite

# 2. The suite must not leave anything behind in tests/. Snapshot the tree
#    now and compare after the run (logs/captures live under SANDBOX_ROOT).
_STRAYS_BEFORE=$SANDBOX_ROOT/strays.before
(find . -mindepth 1 | sort) >"$_STRAYS_BEFORE"
check_no_strays() {
    _after=$SANDBOX_ROOT/strays.after
    (find . -mindepth 1 | sort) >"$_after"
    if ! cmp -s "$_STRAYS_BEFORE" "$_after"; then
        say "FAIL: the test run polluted tests/:"
        diff "$_STRAYS_BEFORE" "$_after" | sed 's/^/     /' >&2
        return 1
    fi
}

# --- unit: path helpers ----------------------------------------------------

unit_abspath_relative() {
    source_lib
    SB=$(make_sandbox)
    cd "$SB" || return 1
    assert_eq "$(abspath './x/../y')" "$SB/y"
    assert_eq "$(abspath 'a//b/./c')" "$SB/a/b/c"
    assert_eq "$(abspath '.')" "$SB"
}

unit_abspath_absolute() {
    source_lib
    assert_eq "$(abspath /a//b/./../c)" /a/c
    assert_eq "$(abspath /a/b/c/)" /a/b/c
    assert_eq "$(abspath /../x)" /x
    assert_eq "$(abspath /a/../../b)" /b
    assert_eq "$(abspath /)" /
}

unit_rel_target_sibling() {
    source_lib
    assert_eq "$(rel_target /p/wt /p/share/f)" '../share/f'
}

unit_rel_target_nested() {
    source_lib
    assert_eq "$(rel_target /p/wt/sub /p/share/f)" '../../share/f'
}

unit_rel_target_below_base() {
    source_lib
    assert_eq "$(rel_target /a /a/b/c)" 'b/c'
}

unit_rel_target_equal() {
    source_lib
    assert_eq "$(rel_target /same /same)" '.'
}

unit_rel_target_divergent() {
    source_lib
    assert_eq "$(rel_target /a/x/c /a/b/d/e)" '../../b/d/e'
}

unit_rel_target_root_and_ups() {
    source_lib
    assert_eq "$(rel_target / /p/q)" 'p/q'
    assert_eq "$(rel_target /a/b /a)" '..'
}

unit_path_inside_dotdot_safe() {
    source_lib
    if path_inside /x/share/../wt /x/share; then
        echo "'..' escape must not count as inside"; return 1
    fi
    path_inside /x/share/sub /x/share || { echo "sub should be inside"; return 1; }
    path_inside /x/share /x/share || { echo "self should be inside"; return 1; }
}

# --- unit: item iteration --------------------------------------------------

_collect=

cb_collect() { _collect="$_collect|$1"; }

unit_for_each_basic() {
    source_lib
    cfg=$(make_sandbox)/cfg
    mkdir -p "$cfg/.git" "$cfg/.opencode"
    touch "$cfg/a.txt" "$cfg/.env" "$cfg/.gitignore"
    _collect=
    for_each_share_item "$cfg" cb_collect
    # glob order: non-hidden first, then dotfiles
    assert_eq "$_collect" '|a.txt|.env|.opencode'
}

unit_for_each_whitespace() {
    source_lib
    cfg=$(make_sandbox)/cfg
    mkdir -p "$cfg/my docs" "$cfg/sp ace" "$cfg/weird
name"
    _collect=
    for_each_share_item "$cfg" cb_collect
    assert_contains "$_collect" '|my docs'
    assert_contains "$_collect" '|sp ace'
    assert_contains "$_collect" '|weird
name'
}

# --- unit: classify --------------------------------------------------------

unit_classify_states() {
    source_lib
    base=$(make_sandbox)
    cfg=$base/cfg wt=$base/wt
    mkdir -p "$cfg" "$wt"
    printf x >"$cfg/live"            # linkable, absent in wt -> missing
    printf y >"$cfg/rf"; printf y >"$wt/rf"   # real file in wt
    printf t >"$wt/.elsewhere"; ln -s .elsewhere "$wt/other"; printf z >"$cfg/other"
    ln -s nowhere "$wt/dangling"; printf d >"$cfg/dangling"
    assert_eq "$(classify live "$wt" "$cfg")" missing
    assert_eq "$(classify absent "$wt" "$cfg")" nocfg
    assert_eq "$(classify rf "$wt" "$cfg")" realfile
    assert_eq "$(classify other "$wt" "$cfg")" other
    assert_eq "$(classify dangling "$wt" "$cfg")" dangling
    des=$(rel_target "$wt" "$cfg/live")
    ln -s "$des" "$wt/live"
    assert_eq "$(classify live "$wt" "$cfg")" linked
}

unit_hook_block_shape() {
    source_lib
    block=$(_write_hook_block)
    assert_contains "$block" CUBICLE-MANAGED-HOOK-v1
    assert_contains "$block" 'command -v cubicle'
    if printf '%s\n' "$block" | grep -q 'CUBICLE_BIN='; then
        echo "hook must resolve cubicle via PATH, not a hardcoded path"
        exit 1
    fi
    assert_contains "$block" 'exit 0'
}

unit_default_branch_config_fallback() {
    source_lib
    sb=$(make_sandbox)
    printf '[init]\n\tdefaultBranch = zen\n' >"$sb/global.gitconfig"
    GIT_CONFIG_GLOBAL="$sb/global.gitconfig"
    b=$(default_branch)
    assert_eq "$b" zen
    GIT_CONFIG_GLOBAL=/dev/null
    b=$(default_branch)
    assert_eq "$b" main
}

unit_print_layer_quiet() {
    source_lib
    # consumed by ok/info/warn from the sourced library
    # shellcheck disable=SC2034
    QUIET=yes
    msg=$( { ok h1; info h2; } 2>&1 )
    assert_eq "$msg" '' "ok/info must be silent when QUIET=yes"
    msg=$( { warn w1; } 2>&1 )
    assert_eq "$msg" '[warn] w1' "warn must stay visible when quiet"
    # shellcheck disable=SC2034
    QUIET=no
    msg=$( { ok v1; } 2>&1 )
    assert_eq "$msg" '[ok]   v1'
}

# --- e2e -------------------------------------------------------------------

e2e_init_layout() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    for d in .bare share trunk; do
        assert_file "$proj/$d" || return 1
    done
    assert_symlink_to "$proj/trunk/AGENTS.md" ../share/AGENTS.md
    assert_symlink_to "$proj/trunk/.opencode" ../share/.opencode
}

e2e_gitdir_pointer_newline() {
    proj=$(make_project "$(make_sandbox)/proj" master) || return 1
    last=$(tail -c 1 "$proj/.git" | od -An -c | tr -d ' ')
    assert_eq "$last" '\n' ".git pointer must end with newline"
}

e2e_hook_installed() {
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    hook=$proj/.bare/hooks/post-checkout
    assert_file "$hook" || return 1
    [ -x "$hook" ] || { echo "hook not executable"; return 1; }
    assert_contains "$(cat "$hook")" CUBICLE-MANAGED-HOOK-v1
    assert_contains "$(cat "$hook")" 'command -v cubicle'
    if grep -q 'CUBICLE_BIN=' "$hook"; then
        echo "hook must not hardcode an absolute binary path"
        return 1
    fi
}

e2e_worktree_autolink_via_hook() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    # Plain git (not the cubicle wrapper): proves the installed hook does the work.
    assert_rc0 git -C "$proj/trunk" worktree add "$proj/w2" -b w2
    assert_symlink_to "$proj/w2/AGENTS.md" ../share/AGENTS.md
    assert_symlink_to "$proj/w2/.opencode" ../share/.opencode
}

e2e_cubicle_worktree_wrapper() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" worktree ../feat -b feat || return 1
    assert_symlink_to "$proj/feat/AGENTS.md" ../share/AGENTS.md
}

e2e_link_idempotent() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" link
    mtime_before=$(readlink "$proj/trunk/AGENTS.md")
    assert_rc0 "$CUBICLE_BIN" -q link
    assert_eq "$(readlink "$proj/trunk/AGENTS.md")" "$mtime_before"
}

e2e_quiet_is_quiet() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    capture "$CUBICLE_BIN" -q link
    assert_eq "$RC" 0
    assert_eq "$ERR" '' "quiet mode must not write to stderr"
}

e2e_realfile_never_overwritten() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    rm AGENTS.md
    printf 'CUSTOM' >AGENTS.md
    capture "$CUBICLE_BIN" link
    assert_eq "$RC" 0
    assert_eq "$(cat AGENTS.md)" CUSTOM
    assert_contains "$ERR" skipped
}

e2e_other_symlink_untouched() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    rm AGENTS.md
    ln -s /etc/hostname AGENTS.md
    capture "$CUBICLE_BIN" link
    assert_eq "$RC" 0
    assert_eq "$(readlink AGENTS.md)" /etc/hostname
    assert_contains "$ERR" points elsewhere
}

e2e_dangling_repair() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    stash=$(make_sandbox)/stash
    mkdir -p "$stash"
    cd "$proj/trunk" || return 1

    # Phase 1 -- orphaned managed link: config item removed entirely.
    # check must flag it; restoring the item heals it (classify -> linked).
    mv "$proj/share/AGENTS.md" "$stash/"
    if [ -e AGENTS.md ]; then
        echo "link should be dangling now"
        return 1
    fi
    assert_exit 1 "$CUBICLE_BIN" check
    assert_contains "$ERR" DANGLING
    mv "$stash/AGENTS.md" "$proj/share/AGENTS.md"
    capture "$CUBICLE_BIN" link
    assert_rc0 "$CUBICLE_BIN" check

    # Phase 2 -- genuinely broken managed link: config item still present,
    # so a scoped relink must actively rewrite the link.
    rm AGENTS.md
    ln -s ../share/AGENTS.md.broken AGENTS.md
    assert_exit 1 "$CUBICLE_BIN" check
    assert_contains "$ERR" DANGLING
    capture "$CUBICLE_BIN" link
    assert_contains "$ERR" repaired
    assert_symlink_to AGENTS.md ../share/AGENTS.md
    assert_rc0 "$CUBICLE_BIN" check
}

e2e_check_unwired_repo() {
    sb=$(make_sandbox)
    git init -q "$sb/plain"
    cd "$sb/plain" || return 1
    assert_exit 1 "$CUBICLE_BIN" check
    assert_contains "$ERR" 'config directory not found'
}

e2e_spaces_in_names() {
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    mkdir -p "$proj/share/my docs"
    printf hi >"$proj/share/my docs/note.txt"
    git -C "$proj/share" add -A && git -C "$proj/share" commit -qm notes
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" link
    assert_symlink_to "$proj/trunk/my docs" '../share/my docs'
    assert_file "$proj/trunk/my docs/note.txt"
    assert_rc0 "$CUBICLE_BIN" check
}

e2e_clone_flow() {
    sb=$(make_sandbox)
    git -c init.defaultBranch=devel init -q --bare "$sb/upstream.git"
    seed=$sb/seed
    git -c init.defaultBranch=devel init -q "$seed"
    (cd "$seed" && printf x >f && git add f && git commit -qm seed &&
        git push -q "$sb/upstream.git" devel) || return 1
    assert_rc0 "$CUBICLE_BIN" clone --opencode "$sb/upstream.git" "$sb/cloned" || return 1
    for d in .bare share devel; do
        assert_file "$sb/cloned/$d" || return 1
    done
    assert_symlink_to "$sb/cloned/devel/AGENTS.md" ../share/AGENTS.md
}

e2e_help_and_version_flags() {
    # Interface contract: -h/--help and -V/--version are recognized only in
    # front position; after a subcommand they are ordinary arguments, and
    # bare words are unknown commands.
    assert_exit 0 "$CUBICLE_BIN" --help
    capture "$CUBICLE_BIN" --help
    assert_contains "$OUT" 'Usage:'
    assert_contains "$OUT" '-V, --version'
    assert_exit 0 "$CUBICLE_BIN" -h
    capture "$CUBICLE_BIN" -V
    assert_contains "$OUT" '1.0.0'
    assert_exit 1 "$CUBICLE_BIN" help
    assert_exit 1 "$CUBICLE_BIN" version
    assert_exit 1 "$CUBICLE_BIN" frobnicate
    assert_fails "$CUBICLE_BIN" clone --help   # treated as a URL, not a flag
    # zero-argument commands reject stray arguments
    assert_exit 1 "$CUBICLE_BIN" check unexpected-arg
    assert_contains "$ERR" 'usage: cubicle check'
    # global options compose in any order among themselves
    assert_exit 0 "$CUBICLE_BIN" -q -h
    assert_exit 0 "$CUBICLE_BIN" -h -q
    capture "$CUBICLE_BIN" -q -V
    assert_contains "$OUT" '0.'
    # unknown leading options are rejected explicitly
    assert_exit 1 "$CUBICLE_BIN" -x check
    assert_contains "$ERR" 'Unknown option'
    # the old per-command habit fails loudly now
    assert_exit 1 "$CUBICLE_BIN" link --quiet
    assert_contains "$ERR" 'usage: cubicle link'
}

e2e_init_empty_share() {
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    for f in AGENTS.md CLAUDE.md .opencode .claude .git; do
        assert_no_file "$proj/share/$f"
    done
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" link
    capture "$CUBICLE_BIN" check
    assert_eq "$RC" 0 "empty share is valid: check must not fail"
    assert_contains "$ERR" 'no linkable content'
}

e2e_claude_stubs() {
    INIT_OPTS=--claude
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    assert_file "$proj/share/CLAUDE.md"
    assert_file "$proj/share/.claude/settings.json"
    assert_eq "$(cat "$proj/share/.claude/settings.json")" '{}'
    # default: no repository, and cubicle never commits in share/
    assert_no_file "$proj/share/.git"
    assert_symlink_to "$proj/trunk/CLAUDE.md" ../share/CLAUDE.md
}

e2e_share_repo_option() {
    INIT_OPTS='--opencode --repo'
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    assert_file "$proj/share/.git"
    if git -C "$proj/share" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        echo "cubicle must never create commits in share/"
        return 1
    fi
    assert_symlink_to "$proj/trunk/AGENTS.md" ../share/AGENTS.md
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" check
}

e2e_default_branch_fallback() {
    # No explicit branch, no init.defaultBranch anywhere -> main (never master)
    proj=$(make_project "$(make_sandbox)/proj") || return 1
    assert_file "$proj/main"
    if [ -e "$proj/master" ]; then
        echo "hardcoded master leaked through; expected configured default or main"
        return 1
    fi
}

e2e_default_branch_config() {
    # A configured init.defaultBranch wins over the built-in fallback
    sb=$(make_sandbox)
    printf '[init]\n\tdefaultBranch = zen\n' >"$sb/global.gitconfig"
    GIT_CONFIG_GLOBAL="$sb/global.gitconfig"
    export GIT_CONFIG_GLOBAL
    proj=$(make_project "$sb/proj") || return 1
    assert_file "$sb/proj/zen"
}

e2e_link_scope() {
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" worktree ../feat -b feat || return 1

    # break feat's link, then prove scoped `link .` leaves it alone
    rm ../feat/AGENTS.md
    assert_rc0 "$CUBICLE_BIN" link .
    if [ -e ../feat/AGENTS.md ]; then
        echo "scoped link must not touch other worktrees"
        return 1
    fi

    # bare link repairs every worktree
    assert_rc0 "$CUBICLE_BIN" link
    assert_symlink_to "$proj/feat/AGENTS.md" ../share/AGENTS.md
}

e2e_init_unknown_option_rejected() {
    sb=$(make_sandbox)
    capture "$CUBICLE_BIN" init "$sb/proj" --bogus
    assert_eq "$RC" 1
    assert_contains "$ERR" 'usage: cubicle init'
    assert_no_file "$sb/proj"        # rejected before any side effects
    capture "$CUBICLE_BIN" clone "$sb/url.git" --bogus
    assert_eq "$RC" 1
    assert_contains "$ERR" 'usage: cubicle clone'
    assert_no_file "$sb/url.git"
}

e2e_both_stub_bundles() {
    INIT_OPTS='--opencode --claude'
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    for f in AGENTS.md .opencode/opencode.json CLAUDE.md .claude/settings.json; do
        assert_file "$proj/share/$f"
    done
    assert_symlink_to "$proj/trunk/.opencode" ../share/.opencode
}

e2e_clone_repo_option() {
    sb=$(make_sandbox)
    up=$(make_upstream "$sb" devel) || return 1
    assert_rc0 "$CUBICLE_BIN" clone --repo "$up" "$sb/cloned" || return 1
    assert_file "$sb/cloned/share/.git"
    if git -C "$sb/cloned/share" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        echo "clone --repo must never create commits in share/"
        return 1
    fi
}

e2e_hook_heals_siblings() {
    # Chosen semantics: hooks are argument-less, i.e. every checkout relinks
    # the WHOLE project -- a broken sibling must be repaired by a checkout
    # happening anywhere else.
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" worktree ../feat -b feat || return 1
    rm ../feat/AGENTS.md
    [ -e ../feat/AGENTS.md ] && { echo "setup failed: link still present"; return 1; }
    assert_rc0 git -C "$proj/trunk" worktree add "$proj/w3" -b w3
    assert_symlink_to "$proj/feat/AGENTS.md" ../share/AGENTS.md
}

# --- regressions -----------------------------------------------------------

reg_link_from_sibling_worktree() {
    INIT_OPTS=--opencode
    # Bug: cmd_link resolved --git-common-dir relative to $PWD instead of DIR,
    # producing <worktree>/.git (a FILE) as COMMON_DIR and dying in mkdir.
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    assert_rc0 "$CUBICLE_BIN" link ../trunk
    assert_contains "$(cat "$proj/.bare/info/exclude")" /AGENTS.md
    assert_no_file "$proj/trunk/.git/info"
}

reg_hook_update_preserves_foreign_tail() {
    source_lib
    common=$(make_sandbox)/common
    mkdir -p "$common/hooks"
    hook=$common/hooks/post-checkout
    {
        _write_hook_block
        echo '# my own stuff'
        echo 'echo foreign >> marker-file'
    } >"$hook"
    chmod +x "$hook"
    # consumed by install_hook from the sourced library
    # shellcheck disable=SC2034
    COMMON_DIR=$common
    install_hook
    content=$(cat "$hook")
    assert_contains "$content" 'command -v cubicle'
    assert_contains "$content" '# my own stuff'
    assert_contains "$content" 'echo foreign >> marker-file'
    assert_contains "$content" CUBICLE-MANAGED-HOOK-v1
}

reg_excludes_only_once() {
    # consumed by make_project -> init via $INIT_OPTS
    # shellcheck disable=SC2034
    INIT_OPTS=--opencode
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    cd "$proj/trunk" || return 1
    "$CUBICLE_BIN" link >/dev/null 2>&1
    "$CUBICLE_BIN" link >/dev/null 2>&1
    n=$(grep -c '^/AGENTS\.md$' "$proj/.bare/info/exclude")
    assert_eq "$n" 1 "/AGENTS.md must appear exactly once"
}

reg_link_works_from_nested_subdir() {
    proj=$(make_project "$(make_sandbox)/proj" trunk) || return 1
    mkdir -p "$proj/trunk/deep/dir"
    cd "$proj/trunk/deep/dir" || return 1
    capture "$CUBICLE_BIN" link .
    assert_eq "$RC" 0
}

reg_sentinel_loads_without_dispatch() {
    # The __SOURCED__ sentinel must let test frameworks load definitions
    # without firing the dispatcher. If it ever breaks, sourcing runs main,
    # prints help and exits 1 -- killing this subshell before 'loaded'.
    # shellcheck disable=SC1090  # CUBICLE_BIN resolved at runtime
    out=$( __SOURCED__=1 . "$CUBICLE_BIN" && type abspath >/dev/null 2>&1 && echo loaded )
    assert_eq "$out" loaded
}

# --- registration ----------------------------------------------------------

t 'unit: abspath relative'              unit_abspath_relative
t 'unit: abspath absolute normalize'    unit_abspath_absolute
t 'unit: rel_target sibling'            unit_rel_target_sibling
t 'unit: rel_target nested'             unit_rel_target_nested
t 'unit: rel_target below base'         unit_rel_target_below_base
t 'unit: rel_target equal'              unit_rel_target_equal
t 'unit: rel_target divergent'          unit_rel_target_divergent
t 'unit: rel_target root and ups'       unit_rel_target_root_and_ups
t 'unit: path_inside dotdot-safe'       unit_path_inside_dotdot_safe
t 'unit: for_each_share_item basic'     unit_for_each_basic
t 'unit: for_each whitespace names'     unit_for_each_whitespace
t 'unit: classify states'               unit_classify_states
t 'unit: hook block shape'              unit_hook_block_shape
t 'unit: quiet-aware print layer'      unit_print_layer_quiet
t 'e2e: init layout'                    e2e_init_layout
t 'e2e: .git pointer newline'           e2e_gitdir_pointer_newline
t 'e2e: hook installed + executable'    e2e_hook_installed
t 'e2e: plain git worktree autolink'    e2e_worktree_autolink_via_hook
t 'e2e: cubicle worktree wrapper'          e2e_cubicle_worktree_wrapper
t 'e2e: link idempotent'            e2e_link_idempotent
t 'e2e: quiet flag silences output'     e2e_quiet_is_quiet
t 'e2e: realfile never overwritten'     e2e_realfile_never_overwritten
t 'e2e: foreign symlink untouched'      e2e_other_symlink_untouched
t 'e2e: dangling detect + repair'       e2e_dangling_repair
t 'e2e: check on unwired repo fails'   e2e_check_unwired_repo
t 'e2e: spaces in share names'          e2e_spaces_in_names
t 'e2e: clone flow'                     e2e_clone_flow
t 'e2e: help/version flags'             e2e_help_and_version_flags
t 'e2e: init empty share valid'         e2e_init_empty_share
t 'e2e: claude stub bundle'             e2e_claude_stubs
t 'e2e: bare link = all, DIR = scoped' e2e_link_scope
t 'unit: default_branch config/fallback' unit_default_branch_config_fallback
t 'e2e: init rejects unknown option'     e2e_init_unknown_option_rejected
t 'e2e: both stub bundles together'      e2e_both_stub_bundles
t 'e2e: clone --repo option'             e2e_clone_repo_option
t 'e2e: hook heals sibling worktrees'    e2e_hook_heals_siblings
t 'e2e: default branch falls back to main' e2e_default_branch_fallback
t 'e2e: default branch from config'       e2e_default_branch_config
t 'e2e: share --repo option'            e2e_share_repo_option
t 'reg: link from sibling worktree'     reg_link_from_sibling_worktree
t 'reg: hook update keeps foreign tail' reg_hook_update_preserves_foreign_tail
t 'reg: excludes written once'          reg_excludes_only_once
t 'reg: link works from nested subdir'  reg_link_works_from_nested_subdir
t 'reg: __SOURCED__ loads w/o dispatch' reg_sentinel_loads_without_dispatch

if ! summary; then
    exit 1
fi
if ! check_no_strays; then
    exit 1
fi
