#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Headless end-to-end test for the multiselector addon.
#
# It starts a private fcitx5 (isolated HOME, own DBus session and Xvfb
# display), loads the freshly built addon, types pinyin into a real GTK3
# entry, and checks the one-line list, the expanded grid, collapsing, and
# committing.  The user's ~/.local and running fcitx5 are never touched.
#
# Usage: tests/integration.sh [path/to/multiselector.so]
# Exit codes: 0 pass, 1 failure, 77 skipped (missing dependencies).
#
# The test needs a working session DBus.  In restricted sandboxes the DBus
# client can fail with "Failed to query AppArmor policy"; run it outside such
# a sandbox.  All state, logs and screenshots live under build/.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN=${1:-${PLUGIN:-$ROOT/build/multiselector.so}}
ARTIFACTS=${ARTIFACTS:-$ROOT/build/test-artifacts}
KEEP=${KEEP:-0}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [[ ! -f "$PLUGIN" ]]; then
    fail "plugin not found: $PLUGIN (build it first: cmake --build build)"
fi
PLUGIN=$(readlink -f "$PLUGIN")

missing=()
for cmd in fcitx5 fcitx5-remote Xvfb openbox xdotool xclip dbus-daemon \
           dbus-send import python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0")' >/dev/null 2>&1; then
    missing+=("python3-gi/gir1.2-gtk-3.0")
fi
if ((${#missing[@]})); then
    echo "SKIP: missing test dependencies: ${missing[*]}" >&2
    echo "  Debian/Ubuntu: sudo apt install fcitx5 fcitx5-chinese-addons \\" >&2
    echo "      fcitx5-frontend-gtk3 xvfb openbox xdotool xclip \\" >&2
    echo "      python3-gi gir1.2-gtk-3.0 dbus-daemon imagemagick" >&2
    exit 77
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fcitx5-ms-test.XXXXXX")
SHOTS=$TMP/shots
mkdir -p "$TMP/home/.config/fcitx5" "$TMP/home/.local/share/fcitx5/addon" \
         "$TMP/home/.cache" "$TMP/run" "$SHOTS"
chmod 700 "$TMP/run"

export HOME=$TMP/home
export XDG_CONFIG_HOME=$HOME/.config
export XDG_DATA_HOME=$HOME/.local/share
export XDG_CACHE_HOME=$HOME/.cache
export XDG_RUNTIME_DIR=$TMP/run
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export NO_AT_BRIDGE=1
export LANG=C.UTF-8

cat > "$XDG_DATA_HOME/fcitx5/addon/multiselector.conf" <<EOF
[Addon]
Name=Multi Selector
Category=Module
Version=0.0.3
Library=${PLUGIN%.so}
Type=SharedLibrary
OnDemand=False
Configurable=False
EOF

cat > "$XDG_CONFIG_HOME/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

APP_PID=""
FCITX_PID=""
OPENBOX_PID=""
XVFB_PID=""
DBUS_PID=""

cleanup() {
    rc=$?
    set +e
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    if [ -n "$FCITX_PID" ]; then
        fcitx5-remote -e >/dev/null 2>&1
        sleep 0.2
        kill "$FCITX_PID" 2>/dev/null
    fi
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" 2>/dev/null
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    [ -n "$DBUS_PID" ] && kill "$DBUS_PID" 2>/dev/null

    if [ -d "$SHOTS" ]; then
        mkdir -p "$ARTIFACTS/latest"
        cp -a "$SHOTS"/. "$ARTIFACTS/latest"/ 2>/dev/null
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 77 ]; then
        mkdir -p "$ARTIFACTS"
        cp -a "$TMP"/. "$ARTIFACTS"/ 2>/dev/null
        echo "logs and screenshots: $ARTIFACTS" >&2
    fi
    if [ "$KEEP" != 1 ] && { [ "$rc" -eq 0 ] || [ "$rc" -eq 77 ]; }; then
        rm -rf "$TMP"
    fi
    trap - EXIT
    exit "$rc"
}
trap cleanup EXIT

mapfile -t BUS < <(dbus-daemon --session --fork --print-address=1 --print-pid=1)
if ((${#BUS[@]} < 2)); then
    fail "could not start a private DBus session"
fi
export DBUS_SESSION_BUS_ADDRESS=${BUS[0]}
DBUS_PID=${BUS[1]}

mkdir -p /tmp/.X11-unix 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
: > "$TMP/display"
Xvfb -displayfd 3 -screen 0 1280x800x24 -nolisten tcp -extension GLX \
    3>"$TMP/display" >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 100); do
    [ -s "$TMP/display" ] && break
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        fail "Xvfb exited during startup (see $TMP/xvfb.log)"
    fi
    sleep 0.05
done
[ -s "$TMP/display" ] || fail "Xvfb did not report a display"
export DISPLAY=":$(cat "$TMP/display")"
for _ in $(seq 1 100); do
    xdpyinfo >/dev/null 2>&1 && break
    sleep 0.05
done
xdpyinfo >/dev/null 2>&1 || fail "X display $DISPLAY is not usable"

openbox >"$TMP/openbox.log" 2>&1 &
OPENBOX_PID=$!
sleep 0.5

fcitx5 --replace >"$TMP/fcitx5.log" 2>&1 &
FCITX_PID=$!
for _ in $(seq 1 100); do
    grep -q 'Loaded addon pinyin' "$TMP/fcitx5.log" 2>/dev/null && break
    if ! kill -0 "$FCITX_PID" 2>/dev/null; then
        fail "fcitx5 exited during startup (see $TMP/fcitx5.log)"
    fi
    sleep 0.1
done
grep -q 'Loaded addon multiselector' "$TMP/fcitx5.log" \
    || fail "multiselector addon was not loaded"
grep -q 'Loaded addon pinyin' "$TMP/fcitx5.log" \
    || fail "fcitx5 pinyin engine was not loaded"

python3 "$ROOT/tests/gtk-entry.py" >"$TMP/app.log" 2>&1 &
APP_PID=$!
WIN=""
for _ in $(seq 1 100); do
    WIN=$(xdotool search --name '^smoke$' 2>/dev/null | head -1 || true)
    [ -n "$WIN" ] && break
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        fail "GTK test client exited (see $TMP/app.log)"
    fi
    sleep 0.05
done
[ -n "$WIN" ] || fail "GTK test window did not appear"
xdotool windowactivate --sync "$WIN" 2>/dev/null \
    || xdotool windowfocus --sync "$WIN"
sleep 0.5
fcitx5-remote -o >/dev/null 2>&1 || true
sleep 0.5

state=$(fcitx5-remote 2>/dev/null || true)
im=$(fcitx5-remote -n 2>/dev/null || true)
[ "$state" = 2 ] || fail "fcitx5 is not active (state='$state')"
[ "$im" = pinyin ] || fail "unexpected current input method: '$im'"

cand_id() { xdotool search --class '^fcitx$' 2>/dev/null | head -1 || true; }
win_h() { xdotool getwindowgeometry --shell "$1" 2>/dev/null | awk -F= '/^HEIGHT=/{print $2}'; }
win_w() { xdotool getwindowgeometry --shell "$1" 2>/dev/null | awk -F= '/^WIDTH=/{print $2}'; }

wait_candidate() {
    local id
    for _ in $(seq 1 50); do
        id=$(cand_id)
        if [ -n "$id" ]; then
            echo "$id"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

read_entry() {
    printf '' | timeout 2 xclip -selection clipboard >/dev/null 2>&1 || true
    xdotool key ctrl+a
    xdotool key ctrl+c
    sleep 0.5
    timeout 5 xclip -selection clipboard -o 2>/dev/null || true
}

clear_entry() {
    xdotool key ctrl+a
    xdotool key BackSpace
    sleep 0.3
}

assert_cjk() {
    local text=$1 label=$2
    if ! printf '%s' "$text" | python3 -c \
        'import sys; t = sys.stdin.read(); raise SystemExit(0 if any(ord(c) > 0x2E80 for c in t) else 1)'; then
        fail "$label: committed text has no CJK characters: '$text'"
    fi
}

# One-line list: Space commits the highlighted candidate.
xdotool type --delay 120 'shi'
ID=$(wait_candidate) || fail "fcitx5 candidate window did not appear"
sleep 0.8
H1=$(win_h "$ID")
W1=$(win_w "$ID")
import -window root "$SHOTS/1-one-line.png" 2>/dev/null || true
((H1 > 10 && H1 < 80)) || fail "expected a one-line candidate window, got height $H1"

xdotool key space
sleep 1.0
TEXT1=$(read_entry)
assert_cjk "$TEXT1" "one-line Space"
echo "one-line commit: $TEXT1"
clear_entry

# One-line list: Right moves the highlight, so the next Space commits a
# different candidate.
xdotool type --delay 120 'shi'
ID=$(wait_candidate) || fail "candidate window did not reappear"
sleep 0.6
xdotool key Right
sleep 0.5
import -window root "$SHOTS/1b-right.png" 2>/dev/null || true
xdotool key space
sleep 1.0
TEXT2=$(read_entry)
assert_cjk "$TEXT2" "one-line Right+Space"
[ "$TEXT2" != "$TEXT1" ] \
    || fail "Right did not change the highlighted candidate (both '$TEXT1')"
echo "one-line Right commit: $TEXT2"
clear_entry

# Grid: Down expands, arrows move, Escape collapses, Space commits.
xdotool type --delay 120 'shi'
ID=$(wait_candidate) || fail "candidate window did not reappear for the grid test"
sleep 0.5
xdotool key Down
sleep 1.2
ID=$(cand_id)
[ -n "$ID" ] || fail "candidate window disappeared after Down"
H2=$(win_h "$ID")
W2=$(win_w "$ID")
import -window root "$SHOTS/2-grid.png" 2>/dev/null || true
((H2 >= 100)) || fail "grid did not expand (height $H2)"
((W2 >= W1)) || fail "grid is narrower than the one-line list ($W2 < $W1)"

xdotool key Down
xdotool key Right
sleep 0.6
ID=$(cand_id)
H2b=$(win_h "$ID")
import -window root "$SHOTS/3-moved.png" 2>/dev/null || true
((H2b >= 100)) || fail "grid closed while moving (height $H2b)"

xdotool key Escape
sleep 0.8
ID=$(cand_id)
[ -n "$ID" ] || fail "candidate window disappeared after Escape"
H3=$(win_h "$ID")
import -window root "$SHOTS/4-collapsed.png" 2>/dev/null || true
((H3 > 10 && H3 < 80)) || fail "grid did not collapse (height $H3)"

xdotool key Down
sleep 1.2
ID=$(cand_id)
H4=$(win_h "$ID")
((H4 >= 100)) || fail "grid did not re-expand (height $H4)"
xdotool key space
sleep 1.0
import -window root "$SHOTS/5-committed.png" 2>/dev/null || true

TEXT3=$(read_entry)
assert_cjk "$TEXT3" "grid commit"
echo "grid commit: $TEXT3"

echo "PASS: multiselector loaded; one-line select and grid expand/move/collapse/commit worked"
echo "screenshots: $ARTIFACTS/latest"
