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
RAW=$(mktemp)
trap 'rm -f "$TMP" "$RAW"; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null' \
	0 1 15

exit_status=0

FSI='\0342\0201\0250'
PDI='\0342\0201\0251'
LRI='\0342\0201\0246'
A10=aaaaaaaaaa
A80=$A10$A10$A10$A10$A10$A10$A10$A10

# inner <case> <pane_output> <split> [raw_file]
#   Show pane_output in the first pane of an inner session (split in two side
#   by side panes if split is 1), attach an inner client to it from an outer
#   pane and set captured to the outer pane. With raw_file, the bytes the
#   inner client writes for the refresh are also saved there.
inner() {
	$TMUX kill-server 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
	sleep 1

	printf '%b' "$2" >"$TMP"
	$TMUX2 new -d -x80 -y5 "cat '$TMP'; sleep 100" || exit 1
	$TMUX2 set -g status off || exit 1
	$TMUX2 set -g window-size manual || exit 1
	$TMUX2 set -as terminal-features '*:bidi' || exit 1
	[ "$3" = 1 ] && { $TMUX2 splitw -h 'sleep 100' || exit 1; }
	sleep 1
	$TMUX new -d -x80 -y5 "TMUX= $TMUX2 attach" || exit 1
	sleep 1
	: >"$RAW"
	[ -n "$4" ] && { $TMUX pipe-pane -O -t0:0.0 "cat >>'$4'" || exit 1; }
	$TMUX2 refresh-client -t "$($TMUX2 list-clients -F '#{client_name}')" ||
		exit 1
	sleep 1
	captured=$($TMUX capture-pane -p -t0:0.0) || {
		echo "[FAIL] case $1: capture-pane failed"
		exit_status=1
		return 1
	}
}

# check <case> <left_pane_output> <expected>
#   Show left_pane_output in the left pane of a two pane inner session, attach
#   an inner client to it from an outer pane, then compare row 1 of the outer
#   pane with expected (printf format).
check() {
	inner "$1" "$2" 1 || return
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

# A control at column 0 of a row the pane soft-wrapped into is not kept (the
# terminal alone would not keep it there either), and is never written at the
# end of the full row above, where the terminal is in pending wrap.
inner 3 "\033[8h\033[?2501h${A80}b\r${LRI}c" 0 && {
	row1=$(printf '%s\n' "$captured" | sed -n 1p)
	row2=$(printf '%s\n' "$captured" | sed -n 2p)
	[ "$row1" = "$A80" ] || {
		echo "[FAIL] case 3: expected row 1 of 80 a, got '$row1'"
		exit_status=1
	}
	[ "$row2" = "c" ] || {
		echo "[FAIL] case 3: expected row 2 'c', got '$row2'"
		exit_status=1
	}
}

# A lead the terminal does not keep (the control before a VS16 widened cell)
# is not written (checked on the bytes the inner client sends before the first
# border, as the outer tmux would drop it itself; the right pane's own
# initiator after the border is an LRI) and not counted, so the row has exactly one
# closing PDI (the left segment's; the right pane is the rightmost segment).
inner 4 "\033[8h\033[?2501h${LRI}☀️ abc" 1 "$RAW" && {
	row1=$(printf '%s\n' "$captured" | sed -n 1p)
	left=$(LC_ALL=C sed "s/.*$(printf '\033')\[1;1H//; s/$(printf '\342\224\202').*//" "$RAW")
	case $left in
	*"$(printf '%b' "$LRI")"*)
		echo "[FAIL] case 4: the inner client wrote the pane's LRI"
		exit_status=1
		;;
	esac
	[ -s "$RAW" ] || {
		echo "[FAIL] case 4: the inner client's refresh was not captured"
		exit_status=1
	}
	pdis=$(printf '%s' "$row1" | grep -o "$(printf '%b' "$PDI")" | wc -l)
	[ "$pdis" -eq 1 ] || {
		echo "[FAIL] case 4: expected 1 PDI in row 1, got $pdis"
		exit_status=1
	}
}

exit $exit_status
