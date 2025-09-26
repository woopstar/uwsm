#!/bin/sh

# Simple client for wayland-wm-app-daemon.service
# A drop-in replacement for "uwsm app"
# special arguments: ping, stop
#
# For situations where arguments can not be passed:
# If launched as "uwsm-terminal" (i.e. via symlink),
# hardcodes "-T --" before arguments,
# takes unit type from UWSM_APP_UNIT_TYPE environment var.
# Alternatively can be launched as "uwsm-terminal-service" or "uwsm-terminal-scope".

set -e

# timeout for all pipe operations
TIMEOUT=10

# assume uwsm is under the same name as us, without "-app"
SELF_NAME=${0##*/}
UWSM_NAME=${SELF_NAME%-app}

PIPE_IN="${XDG_RUNTIME_DIR}/uwsm-app-daemon-in"
PIPE_OUT="${XDG_RUNTIME_DIR}/uwsm-app-daemon-out"

DAEMON_UNIT=wayland-wm-app-daemon.service
LOCK_PATH="${XDG_RUNTIME_DIR}/uwsm-app.lock"

N='
'

message() {
	# print message "$1" to stdout
	echo "$1"
	# if notify-send is installed and stdout is not a terminal, also send notification
	if [ ! -t 1 ] && command -v notify-send > /dev/null; then
		notify-send -u normal -i info -a "${SELF_NAME}" "App message" "$1"
	fi
}

error() {
	# print message "$1" to stderr
	echo "$1" >&2
	# if notify-send is installed and stderr is not a terminal, also send notification
	if [ ! -t 2 ] && command -v notify-send > /dev/null; then
		notify-send -u critical -i error -a "${SELF_NAME}" "App failure" "$1"
	fi
	# if code is 141 (128+13, exit due to SIGPIPE), also restart daemon
	if [ "${2:-1}" = "141" ]; then
		systemctl --user restart "$DAEMON_UNIT" || true
	fi
	# exit with code $2
	exit ${2:-1}
}

# fork timeout killer
MAINPID=$$
{
	# send SIGPIPE to main process after timeout
	sleep $TIMEOUT
	if kill -0 $MAINPID 2> /dev/null; then
		kill -13 $MAINPID
	fi
} &
KILLER_PID=$!

# trap SIGPIPE
trap 'error "Timed out waiting for pipes!" 141' PIPE

# ---- Acquire a mutex: serialize one request/response over shared FIFOs ----
lfd=
exec {lfd}> "$LOCK_PATH"
if command -v flock >/dev/null 2>&1; then
	# block here until previous client finishes its round-trip
	flock -x "$lfd"
fi

# Ensure server is up without sleeps:
# If FIFOs are missing, create them; then start the daemon.
# FIFO open/write will naturally block until the daemon opens the other end.
if [ ! -p "$PIPE_IN" ] || [ ! -p "$PIPE_OUT" ]; then
	[ -p "$PIPE_IN" ]  || mkfifo -m 0600 "$PIPE_IN"
	[ -p "$PIPE_OUT" ] || mkfifo -m 0600 "$PIPE_OUT"
	systemctl --user start "$DAEMON_UNIT" >/dev/null 2>&1 || true
else
	# this does nothing if it is already started
	systemctl --user start "$DAEMON_UNIT" >/dev/null 2>&1 || true
fi

# update message
trap 'error "Timed out trying to write to ${PIPE_IN}!" 141' PIPE

# prepend arguments if launched as a terminal
case "${0##*/}" in
uwsm-terminal*)
	set -- -T -- "$@"
	case "${0##*/}" in
	uwsm-terminal-service*)
		set -- -t service "$@"
		;;
	uwsm-terminal-scope*)
		set -- -t scope "$@"
		;;
	*)
		case "${UWSM_APP_UNIT_TYPE-}" in
		service) set -- -t service "$@" ;;
		scope)   set -- -t scope   "$@" ;;
		esac
		;;
	esac
	;;
esac

# write args to input pipe
if [ "$#" = "0" ]; then
	echo "No args given!" >&2
	# release lock before exit
	if [ -n "$lfd" ]; then exec {lfd}>&-; fi
	exit 1
elif [ "$#" = "1" ] && [ "$1" = "ping" ]; then
	printf '%s' 'ping' > "$PIPE_IN"
elif [ "$#" = "1" ] && [ "$1" = "stop" ]; then
	printf '%s' 'stop' > "$PIPE_IN"
elif [ "$#" -ge "1" ] && {
	# intercept -h|--help arg
	help=false
	for arg in "$@"; do
		case "$arg" in
		--) break ;;
		-h | --help)
			help=true
			break
			;;
		esac
	done
	case "$help" in
	true) true ;;
	false) false ;;
	esac
} then
	printf '%s\n' "Running 'uwsm app --help':" ""
	# release lock before exec
	if [ -n "$lfd" ]; then exec {lfd}>&-; fi
	exec uwsm app -h
else
	# keep original protocol: NUL + "app" followed by each arg with the same format
	printf '\0%s' app "$@" > "$PIPE_IN"
fi

# update message
trap 'error "Timed out trying to read from ${PIPE_OUT}!" 141' PIPE

# read from output pipe
CMDLINE=
while IFS='' read line; do
	CMDLINE="${CMDLINE}${CMDLINE:+$N}${line}"
done < "$PIPE_OUT"

# kill timeout killer process and its sleep process
kill $KILLER_PID $(ps --ppid $KILLER_PID -o pid= || true) >/dev/null 2>&1 || true &

# release the mutex before executing the returned command
if [ -n "$lfd" ]; then
	exec {lfd}>&-
fi

case "$CMDLINE" in
pong)
	message pong
	exit 0
	;;
'' | "$N")
	error "Received empty command!"
	;;
*)
	# run received commands
	eval "$CMDLINE"
	;;
esac
