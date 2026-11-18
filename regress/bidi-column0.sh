#!/bin/sh

# Test that a pane in BDSM (SM 8) keeps a directional isolate control (U+2066
# .. U+2069) printed at column 0, and drops it again when the text moves to
# another row or the screen scrolls. A first cell that is wide, or not one tmux
# and the terminal are known to size alike, does not keep the control. Without
# BDSM the control is dropped as upstream does.

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
A10=aaaaaaaaaa
A40=$A10$A10$A10$A10

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

# A first cell that is wide, or not one tmux and the terminal are known to size
# alike (a narrow cell outside the agreed list, a VS16 that widens the cell the
# control already leads), does not keep the control.
check 5 "\033[8h${PDI}漢abc" 1 "漢abc"
check 6 "\033[8h${LRI}${SUN}${VS16}abc" 1 "${SUN}${VS16}abc"
check 13 "\033[8h${PDI}☝abc" 1 "☝abc"
check 14 "\033[8h\033(0${LRI}lqk\033(B" 1 "lqk"

# At most 8 controls lead a row.
check 15 "\033[8h${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}a" 1 \
    "${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}${LRI}a"

# The control is not kept once an insert or delete line, a change of mode or an
# insert or delete character at column 0 touches the row before the next
# character: it must not survive onto text it no longer leads.
check 7 "\033[8h${LRI}\033[La" 1 "a"
check 8 "\033[8h${LRI}\033[Mb" 1 "b"
check 9 "\033[8hx\r${LRI}\033[@c" 1 "cx"
check 10 "\033[8h${LRI}\033[8la" 1 "a"
check 12 "\033[8h${LRI}\033[Pc" 1 "c"

# A row the cursor reached by wrapping continues the row above, where the
# control cannot lead it, so it is not kept.
check 11 "\033[8h${A40}b\r${LRI}c" 2 "c"

$TMUX kill-server 2>/dev/null

exit $exit_status
