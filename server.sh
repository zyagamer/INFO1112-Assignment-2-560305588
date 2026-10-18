#!/usr/bin/env bash

server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [[ -z "$server_ip" ]]; then
    echo "Error: could not determine the server IP address." >&2
    exit 1
fi

if [[ ! "${SERVER_PORT:-}" =~ ^[0-9]{1,5}$ ]]; then
    echo "Error: configure SERVER_PORT with a number from 1 to 65535." >&2
    exit 1
fi

SERVER_PORT=$((10#$SERVER_PORT))

if (( SERVER_PORT < 1 || SERVER_PORT > 65535 )); then
    echo "Error: port must be between 1 and 65535." >&2
    exit 1
fi

listener_pid=""

cleanup() {
    if [[ -n "$listener_pid" ]]; then
        kill "$listener_pid" 2>/dev/null || true
        wait "$listener_pid" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while true; do
    coproc CONNECTION {
        exec nc -4 -l -N "$SERVER_PORT"
    }

    listener_pid=$CONNECTION_PID
    send_fd=${CONNECTION[1]}
    receive_fd=${CONNECTION[0]}

    listening_port=""

    for ((attempt = 0; attempt < 30; attempt++)); do
        listening_port=$(ss -ltnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") {
                address = $4
                sub(/^.*:/, "", address)
                print address
                exit
            }
        ')

        [[ -n "$listening_port" ]] && break
        kill -0 "$listener_pid" 2>/dev/null || break
        sleep 0.1
    done

    if [[ -z "$listening_port" ]]; then
        echo "Error: could not detect the listening port." >&2
        exit 1
    fi

    printf 'Server listening at %s, port=%s\n' \
        "$server_ip" "$listening_port"

    if IFS= read -r -u "$receive_fd" request; then
        peer=$(ss -tnpH | awk -v pid="$listener_pid" '
            index($0, "pid=" pid ",") {
                print $5
                exit
            }
        ')

        if [[ -n "$peer" ]]; then
            client_ip="${peer%:*}"
            printf 'Client IP: %s\n' "$client_ip"
        else
            echo "Error: could not determine client IP." >&2
        fi

        printf 'Received: %s\n' "$request"
        printf 'OK: received %s\n' "$request" >&"$send_fd"
    else
        echo "Error: client disconnected without a complete request." >&2
    fi

    # Finish the response so netcat can signal EOF to the client.
    exec {send_fd}>&-
    exec {receive_fd}<&-

    if ! wait "$listener_pid"; then
        echo "Error: netcat exited unsuccessfully." >&2
        exit 1
    fi

    listener_pid=""
done