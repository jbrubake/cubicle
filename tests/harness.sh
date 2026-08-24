# shellcheck shell=dash
# harness.sh -- minimal POSIX test helpers for the cubicle suite.
# Sourced by run.sh; test files define case functions and register them
# with:  t 'case name' case_function

CUBICLE_ROOT=${CUBICLE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
CUBICLE_BIN=$CUBICLE_ROOT/cubicle

PASS=0
FAIL=0
CASE_NO=0
LOG=
SANDBOX_ROOT=${SANDBOX_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/cubicle-tests.XXXXXXXX")}

say() { printf '%s\n' "$*"; }

# Run FUNCTION in a throwaway subshell: fresh working directory under
# SANDBOX_ROOT (so a buggy SUT that litters CWD cannot pollute tests/) and
# discarded cd/variable state. Assertions abort the case with `exit 1`,
# which is immune to errexit-semantics quirks; set -e is belt-and-suspenders.
t() {
    CASE_NO=$((CASE_NO + 1))
    LOG=$SANDBOX_ROOT/log.$CASE_NO
    CASE_DIR=$SANDBOX_ROOT/cwd.$CASE_NO
    mkdir -p "$CASE_DIR"
    if (
        set -e
        cd "$CASE_DIR" || exit 99
        "$2"
    ) >"$LOG" 2>&1; then
        PASS=$((PASS + 1))
        say "ok   $1"
    else
        FAIL=$((FAIL + 1))
        say "FAIL $1"
        sed 's/^/     | /' "$LOG"
    fi
    rm -f "$LOG"
}

summary() {
    say
    say "passed: $PASS  failed: $FAIL"
    [ "$FAIL" -eq 0 ]
}

cleanup_all() { rm -rf "$SANDBOX_ROOT"; }
trap cleanup_all EXIT

# --- assertions (run inside a case subshell) -------------------------------
#
# All assertion helpers abort with `exit 1`, not `return 1`: they only ever
# run inside t()'s case subshell, and an explicit exit cannot be masked by
# errexit edge cases. Never call these outside a case function.

assert_eq() { # ACTUAL EXPECTED [MSG]
    if [ "$1" != "$2" ]; then
        echo "assert_eq${3:+ ($3)}: [$1] != [$2]"
        exit 1
    fi
}

assert_contains() { # HAYSTACK NEEDLE [MSG]
    case $1 in
        *"$2"*) ;;
        *)
            echo "assert_contains${3:+ ($3)}: missing [$2] in:"
            printf '%s\n' "$1" | sed 's/^/     > /'
            exit 1
            ;;
    esac
}

assert_file() {
    [ -e "$1" ] || { echo "assert_file: missing $1"; exit 1; }
}

assert_no_file() {
    [ ! -e "$1" ] || { echo "assert_no_file: exists $1"; exit 1; }
}

assert_symlink_to() { # LINK EXPECTED_TARGET
    [ -L "$1" ] || { echo "assert_symlink_to: not a symlink: $1"; exit 1; }
    assert_eq "$(readlink "$1")" "$2" "target of $1"
}

assert_exit() { # EXPECTED_RC CMD... (output kept in OUT/ERR)
    local want=$1
    shift
    capture "$@"
    assert_eq "$RC" "$want" "exit code of: $*"
}

# Assert CMD exits non-zero without pinning the exact code (usage errors,
# git usage errors, etc. vary)
assert_fails() { # CMD...
    capture "$@"
    if [ "$RC" -eq 0 ]; then
        echo "assert_fails: unexpectedly succeeded: $*"
        exit 1
    fi
}

assert_rc0() {
    assert_exit 0 "$@"
}

# --- command runners -------------------------------------------------------

OUT=
ERR=
RC=

capture() { # CMD...
    local errf rc=0
    errf=$SANDBOX_ROOT/capture.$$
    # Expected failures must not abort the caller (cases run under set -e)
    # OUT/ERR/RC are consumed by callers through these globals
    # shellcheck disable=SC2034
    OUT=$("$@" 2>"$errf") || rc=$?
    # shellcheck disable=SC2034
    RC=$rc
    # shellcheck disable=SC2034
    ERR=$(cat "$errf")
    rm -f "$errf"
}

make_sandbox() {
    CASE_NO=$((CASE_NO + 1))
    mktemp -d "$SANDBOX_ROOT/sb.$CASE_NO.XXXXXXXX"
}

# Create a fully wired project: make_project <dir> [branch]
# Leading init options (e.g. --opencode/--claude) may be supplied beforehand
# via $INIT_OPTS; they are intentionally word-split (flags contain no
# spaces). Omitting <branch> lets cubicle resolve its own default -- useful
# for testing default_branch precedence.
make_project() {
    # shellcheck disable=SC2086
    if [ $# -ge 2 ]; then
        assert_rc0 "$CUBICLE_BIN" init ${INIT_OPTS:-} "$1" "$2" || return 1
    else
        assert_rc0 "$CUBICLE_BIN" init ${INIT_OPTS:-} "$1" || return 1
    fi
    printf '%s\n' "$1"
}

# Create an upstream bare repo with one commit on BRANCH; prints its path
# usage: make_upstream SANDBOX BRANCH
make_upstream() {
    git -c "init.defaultBranch=$2" init -q --bare "$1/upstream.git" || return 1
    seed=$(mktemp -d "$1/seed.XXXXXXXX") || return 1
    git -c "init.defaultBranch=$2" init -q "$seed" || return 1
    (cd "$seed" && printf x >f && git add f && git commit -qm seed &&
        git push -q "$1/upstream.git" "$2") || return 1
    printf '%s\n' "$1/upstream.git"
}

# Source cubicle with the load-without-dispatch sentinel (shellspec
# convention) so internal helpers can be unit-tested. The sentinel is an
# assignment prefix on the '.' special builtin, which POSIX says persists
# in the current shell -- unset it defensively afterwards.
source_lib() {
    # shellcheck disable=SC1090
    __SOURCED__=1 . "$CUBICLE_BIN"
    unset __SOURCED__
}
