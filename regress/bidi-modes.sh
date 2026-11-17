#!/bin/sh

# Test bidi mode handling: BDSM (SM/RM 8), auto-detect (private mode 2501),
# and the alternate screen save/restore and RIS for both, all observed through
# DECRQM.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
sleep 1

TMP=$(mktemp)
trap 'rm -f "$TMP"; $TMUX kill-server 2>/dev/null' 0 1 15

$TMUX -f/dev/null new -d -x80 -y24 || exit 1
sleep 1

# Keep the session alive regardless of pane exits.
$TMUX set -g remain-on-exit on

exit_status=0

# query_decrpm <outfile> <mode> <setup_seq> <reply_length>
#   Spawn a pane that sends setup_seq, then DECRQM for mode, and captures
#   the reply (reply_length bytes) into outfile in cat -v form.
query_decrpm() {
	_outfile=$1
	_mode=$2
	_setup=$3
	_n=$4

	$TMUX respawnw -k -t:0 -- sh -c "
		exec 2>/dev/null
		stty raw -echo
		if [ -n \"\$2\" ]; then printf \"\$2\"; sleep 0.2; fi
		printf '\033[%s\$p' \"\$1\"
		dd bs=1 count=\"\$3\" 2>/dev/null | cat -v > \"\$4\"
		sleep 0.2
	" sh "$_mode" "$_setup" "$_n" "$_outfile" || exit 1
	sleep 2
}

# check <name> <mode> <setup_seq> <reply_length> <expected>
check() {
	query_decrpm "$TMP" "$2" "$3" "$4"

	actual=$(cat "$TMP")
	if [ "$actual" = "$5" ]; then
		if [ -n "$VERBOSE" ]; then
			echo "[PASS] $1 -> $actual"
		fi
	else
		echo "[FAIL] $1: expected '$5', got '$actual'"
		exit_status=1
	fi
}

# Replies are ESC [ 8 ; Ps $ y (7 bytes) or ESC [ ? 2501 ; Ps $ y (11 bytes).
check "BDSM default" 8 '' 7 "^[[8;2\$y"
check "BDSM set" 8 '\033[8h' 7 "^[[8;1\$y"
check "BDSM set then reset" 8 '\033[8h\033[8l' 7 "^[[8;2\$y"
check "bidi auto set" '?2501' '\033[?2501h' 11 "^[[?2501;1\$y"
check "BDSM cleared on alternate screen" 8 '\033[8h\033[?1049h' 7 \
    "^[[8;2\$y"
check "BDSM restored on alternate screen exit" 8 \
    '\033[8h\033[?1049h\033[?1049l' 7 "^[[8;1\$y"
check "BDSM cleared by RIS" 8 '\033[8h\033c' 7 "^[[8;2\$y"
check "BDSM not restored after RIS on alternate screen" 8 \
    '\033[8h\033[?1049h\033c\033[?1049l' 7 "^[[8;2\$y"
check "bidi auto set then reset" '?2501' '\033[?2501h\033[?2501l' 11 \
    "^[[?2501;2\$y"
check "bidi auto cleared on alternate screen" '?2501' \
    '\033[?2501h\033[?1049h' 11 "^[[?2501;2\$y"
check "bidi auto restored on alternate screen exit" '?2501' \
    '\033[?2501h\033[?1049h\033[?1049l' 11 "^[[?2501;1\$y"
check "bidi auto cleared by RIS" '?2501' '\033[?2501h\033c' 11 \
    "^[[?2501;2\$y"

$TMUX kill-server 2>/dev/null

exit $exit_status
