#!/bin/bash
# ============================================================================
# bw-session — tests the per-task bw unlock helpers and the BWS_ACCESS_TOKEN
# export (kalmia#343): roles/dev_host/files/{bw,bw-unlock,bw-lock,bw-session.sh}
# and the bws block in roles/shell/templates/bashrc_block.j2.
#
# Every bw and bws here is a stub for the whole run, and every key and token is
# a fake string: the test never reads, prints or creates a real secret
# (the drosera#337 near-miss). HOME and XDG_RUNTIME_DIR point into a temp dir.
#
#   tests/bw-session.sh
# Needs bash, script (util-linux) for a tty, and stat. Exit 0 when clean.
# ============================================================================
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
files=$root/roles/dev_host/files
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME=$tmp/home XDG_RUNTIME_DIR=$tmp/run
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$tmp/bin"
chmod 700 "$XDG_RUNTIME_DIR"
unset BW_SESSION BWS_ACCESS_TOKEN

export BW_SESSION_LIB=$files/bw-session.sh BW_REAL=$tmp/bin/bw-stub
# The stub records what it saw: the fake session key it was handed and its args.
cat >"$BW_REAL" <<'S'
#!/bin/bash
echo "args=$* session=${BW_SESSION:-<unset>}" >>"$STUB_LOG"
case "${1:-}" in
    unlock) echo -n "FAKE-SESSION-KEY" ;;
esac
S
chmod +x "$BW_REAL"
export STUB_LOG=$tmp/stub.log
keyfile=$XDG_RUNTIME_DIR/bw-session

fails=0
check() { # check NAME CONDITION...
    local name=$1
    shift
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
last() { tail -n 1 "$STUB_LOG"; }
mode() { stat -c %a "$1"; }

# --- the wrapper -------------------------------------------------------------
: >"$STUB_LOG"
"$files/bw" status
check "no key file: bw runs with no session" test "$(last)" = "args=status session=<unset>"

printf %s FAKE-SESSION-KEY >"$keyfile"
chmod 600 "$keyfile"
"$files/bw" list items
check "key file: bw gets the session key" test "$(last)" = "args=list items session=FAKE-SESSION-KEY"

BW_SESSION=ALREADY-SET "$files/bw" status
check "BW_SESSION already set wins" test "$(last)" = "args=status session=ALREADY-SET"

chmod 644 "$keyfile"
"$files/bw" status 2>/dev/null
check "loose mode: key ignored" test "$(last)" = "args=status session=<unset>"

chmod 600 "$keyfile"
: >"$keyfile"
"$files/bw" status
check "empty key file: ignored" test "$(last)" = "args=status session=<unset>"

rm -f "$keyfile"
ln -s "$tmp/elsewhere" "$keyfile"
printf %s FAKE-SESSION-KEY >"$tmp/elsewhere"
chmod 600 "$tmp/elsewhere"
"$files/bw" status
check "symlinked key file: ignored" test "$(last)" = "args=status session=<unset>"
rm -f "$keyfile"

# Claude Code's per-command shells: a fresh process reads the file at call time.
printf %s FAKE-SESSION-KEY >"$keyfile"
chmod 600 "$keyfile"
env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" BW_SESSION_LIB="$BW_SESSION_LIB" \
    BW_REAL="$BW_REAL" STUB_LOG="$STUB_LOG" bash -c "$files/bw status"
check "fresh shell env: key still found" test "$(last)" = "args=status session=FAKE-SESSION-KEY"
rm -f "$keyfile"

# --- XDG_RUNTIME_DIR unset: fall back to /run/user/<uid>, never to disk ---------
# Where /run/user/<uid> exists the fallback must resolve to it; where it does
# not (a CI runner), it must fail rather than pick a disk path.
if [[ -d /run/user/$(id -u) && -O /run/user/$(id -u) ]]; then
    check "fallback is /run/user/<uid>" bash -c \
        "unset XDG_RUNTIME_DIR; . '$files/bw-session.sh'; [[ \$(bw_session_file) == /run/user/\$(id -u)/bw-session ]]"
else
    check "no tmpfs directory: no fallback path" bash -c \
        "unset XDG_RUNTIME_DIR; . '$files/bw-session.sh'; ! bw_session_file"
fi

# --- bw-unlock and bw-lock ---------------------------------------------------
: >"$STUB_LOG"
script -qec "$files/bw-unlock" /dev/null </dev/null >/dev/null 2>&1
check "bw-unlock writes the key" test "$(cat "$keyfile" 2>/dev/null)" = "FAKE-SESSION-KEY"
check "bw-unlock key file is mode 600" test "$(mode "$keyfile" 2>/dev/null)" = "600"
check "bw-unlock leaves no temp files" test "$(find "$XDG_RUNTIME_DIR" -type f | wc -l)" = "1"

"$files/bw-unlock" </dev/null >/dev/null 2>&1
check "bw-unlock refuses without a tty" test $? -ne 0

"$files/bw-lock" >/dev/null
check "bw-lock removes the key file" test ! -e "$keyfile"
check "bw-lock calls bw lock" grep -q '^args=lock' "$STUB_LOG"

printf %s FAKE-SESSION-KEY >"$keyfile"
cat >"$BW_REAL" <<'S'
#!/bin/bash
exit 1
S
"$files/bw-lock" >/dev/null
check "bw-lock removes the key even when bw lock fails" test ! -e "$keyfile"

# --- BWS_ACCESS_TOKEN export (the shell role's bashrc block) ---------------------
snippet=$tmp/bws-snippet.sh
sed -n '/^# --- Bitwarden Secrets Manager (bws) ---$/,/^# --- Granted/p' \
    "$root/roles/shell/templates/bashrc_block.j2" | sed '$d' >"$snippet"
check "bws block found in bashrc_block.j2" test -s "$snippet"

token() { bash -c ". '$snippet'; printf %s \"\${BWS_ACCESS_TOKEN-<unset>}\""; }
check "no token file: nothing exported" test "$(token)" = "<unset>"

mkdir -p "$HOME/.config/bws"
: >"$HOME/.config/bws/access-token"
check "empty token file: nothing exported" test "$(token)" = "<unset>"

printf 'FAKE-BWS-TOKEN\n' >"$HOME/.config/bws/access-token"
chmod 644 "$HOME/.config/bws/access-token"
check "loose token mode: nothing exported" test "$(token 2>/dev/null)" = "<unset>"

chmod 600 "$HOME/.config/bws/access-token"
check "token file: exported, newline trimmed" test "$(token)" = "FAKE-BWS-TOKEN"

echo
if [[ $fails -gt 0 ]]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "all checks passed"
