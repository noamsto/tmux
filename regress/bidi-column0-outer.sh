#!/bin/sh

# Test where a bidi-capable client writes the directional isolate controls of
# a pane that starts at column 0. An inner tmux client (with the bidi terminal
# feature) runs in a pane of an outer tmux; its enabling of BDSM puts the outer
# pane in BDSM too, so the outer pane keeps the controls the inner client
# writes at column 0 and capture-pane shows where it wrote them.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"

TMP=$(mktemp)
trap 'rm -f "$TMP"; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null' \
	0 1 15

exit_status=0

FSI='\0342\0201\0250'
PDI='\0342\0201\0251'

# check <case> <left_pane_output> <expected>
#   Show left_pane_output in the left pane of a two pane inner session, attach
#   an inner client to it from an outer pane, then compare row 1 of the outer
#   pane with expected (printf format).
check() {
	$TMUX kill-server 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
	sleep 1

	printf '%b' "$2" >"$TMP"
	$TMUX2 new -d -x80 -y5 "cat '$TMP'; sleep 100" || exit 1
	$TMUX2 set -g status off || exit 1
	$TMUX2 set -g window-size manual || exit 1
	$TMUX2 set -as terminal-features '*:bidi' || exit 1
	$TMUX2 splitw -h 'sleep 100' || exit 1
	sleep 1
	$TMUX new -d -x80 -y5 "TMUX= $TMUX2 attach" || exit 1
	sleep 1
	captured=$($TMUX capture-pane -p -t0:0.0) || {
		echo "[FAIL] case $1: capture-pane failed"
		exit_status=1
		return
	}
	actual=$(printf '%s\n' "$captured" | sed -n 1p)
	expected=$(printf '%b' "$3")
	case $actual in
	"$expected"*) ;;
	*)
		echo "[FAIL] case $1: expected row to start with '$expected'," \
		    "got '$actual'"
		exit_status=1
		;;
	esac
}

# The inner client writes its isolate before the shin at column 0, not after it.
check 1 "\033[8h\033[?2501hשלום world" "${FSI}ש"

# The closing isolate of the pane's own FSI goes after the space the cursor is
# on, not before it.
check 2 "\033[8h\033[?2501h❯ ${FSI}אני " "${FSI}❯ ${FSI}אני ${PDI}"

exit $exit_status
