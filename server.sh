#!/usr/bin/env bash

# Netcat runs this same script in client-handling mode.
if [[ "${INFO1112_CLIENT_MODE:-}" == "1" ]]; then
    peer=$(ss -tnH | awk -v port="$SERVER_PORT" '
        ($1 == "ESTAB" || $1 == "CLOSE-WAIT") &&
        $4 ~ (":" port "$") {
            print $5
            exit
        }
    ')

    if [[ -n "$peer" ]]; then
        client_ip="${peer%:*}"
        client_ip="${client_ip#\[}"
        client_ip="${client_ip%\]}"
        client_ip="${client_ip#::ffff:}"
        printf 'Client IP: %s\n' "$client_ip" >&2
    else
        printf 'Error: could not determine client IP.\n' >&2
    fi
    
    if IFS= read -r request; then
        printf 'Received: %s\n' "$request" >&2
        printf 'OK: received %s\n' "$request"
    else
        printf 'Error: no complete request received.\n' >&2
    fi
    exit 0
fi

server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [[ -z "$server_ip" ]]; then
    echo "Error: could not determine the server IP address." >&2
    exit 1
fi

printf 'Server IP: %s\n' "$server_ip"

if [[ -z "${SERVER_PORT:-}" ]]; then
    echo "Error: set SERVER_PORT before starting the server." >&2
    exit 1
fi

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

listener_pid=""

cleanup() {
    if [[ -n "$listener_pid" ]]; then
        kill "$listener_pid" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while true; do
    INFO1112_CLIENT_MODE=1 nc -l -p "$SERVER_PORT" -e "$script_path" &
    listener_pid=$!

    listening_port=""

    # Allow the listener time to start.
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

    if ! wait "$listener_pid"; then
        echo "Error: listener failed." >&2
        exit 1
    fi

    listener_pid=""
done