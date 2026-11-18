#!/bin/sh

# Test that a pane in BDSM (SM 8) keeps a directional isolate control (U+2066
# .. U+2069) printed at column 0, and drops it again when the text moves to
# another row or the screen scrolls. Without BDSM the control is dropped as
# upstream does.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
sleep 1

TMP=$(mktemp)
trap 'rm -f "$TMP"; $TMUX kill-server 2>/dev/null' 0 1 15

exit_status=0

PDI='\0342\0201\0251'
LRI='\0342\0201\0246'
SUN='\0342\0230\0200'
VS16='\0357\0270\0217'

# check <case> <pane_output> <rows> <expected>
#   Show pane_output in a 40x5 pane, then compare rows (a sed address, 1-based)
#   of the captured pane with expected (printf format).
check() {
	printf '%b' "$2" >"$TMP"
	$TMUX new -d -x40 -y5 "cat '$TMP'; sleep 100" || exit 1
	sleep 1
	captured=$($TMUX capture-pane -p -t0:0.0) || {
		echo "[FAIL] case $1: capture-pane failed"
		exit_status=1
		$TMUX kill-server 2>/dev/null
		sleep 1
		return
	}
	actual=$(printf '%s\n' "$captured" | sed -n "$3p")
	expected=$(printf '%b' "$4")
	$TMUX kill-server 2>/dev/null
	sleep 1
	if [ "$actual" != "$expected" ]; then
		echo "[FAIL] case $1: expected '$expected', got '$actual'"
		exit_status=1
	fi
}

check 1 "\033[8h${PDI}abc" 1 "${PDI}abc"
check 2 "${PDI}abc" 1 "abc"
check 3 "\033[8h${LRI}\r\nx" 1,2 "\nx"
check 4 "\033[8h\033[5;1H${PDI}\r\nx" 5 "x"

# A wide first cell does not keep the control; a VS16 that widens the first
# cell drops the control the cell already holds.
check 5 "\033[8h${PDI}漢abc" 1 "漢abc"
check 6 "\033[8h${LRI}${SUN}${VS16}abc" 1 "${SUN}${VS16}abc"

$TMUX kill-server 2>/dev/null

exit $exit_status
