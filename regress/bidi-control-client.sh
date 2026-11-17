#!/bin/sh

# A control client has no terminal description. A pane switching bidi on,
# off, or changing auto-detect or SCP while one is attached must not crash
# the server, and the client must still get the pane output.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
sleep 1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; $TMUX kill-server 2>/dev/null' 0 1 15

# Emit each sequence followed by a marker the control client must see.
cat >"$TMP/pane.sh" <<'EOF'
sleep 2
printf '\033[8h'; printf 'MARK1'
printf '\033[?2501h'; printf 'MARK2'
printf '\033[8l'; printf 'MARK3'
printf '\033[1 k'; printf 'MARK4'
sleep 1
printf '\033[8h'; printf 'MARK5'
sleep 30
EOF

$TMUX -f/dev/null new -d -x80 -y24 "sh $TMP/pane.sh" || exit 1

# The first client is attached before the pane writes anything. The second
# attaches while the pane already has bidi on.
(sleep 5) | $TMUX -C attach >"$TMP/out1" 2>&1 &
sleep 1
(sleep 4) | $TMUX -C attach >"$TMP/out2" 2>&1 &
sleep 5

exit_status=0

if ! $TMUX has 2>/dev/null; then
	echo "server died"
	exit_status=1
fi
for i in 1 2 3 4 5; do
	for f in out1 out2; do
		if [ "$f" = out2 ] && [ "$i" -lt 5 ]; then
			continue
		fi
		if ! grep -q "^%output %0 .*MARK$i" "$TMP/$f"; then
			echo "$f: no output for MARK$i"
			exit_status=1
		fi
	done
done

exit $exit_status
