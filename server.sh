#!/usr/bin/env bash

# Netcat runs this same script in client-handling mode.
if [[ "${INFO1112_CLIENT_MODE:-}" == "1" ]]; then
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

while true; do
    printf 'Waiting for a request...\n'

    if ! INFO1112_CLIENT_MODE=1 nc -l -p "$SERVER_PORT" -e "$script_path"; then
        echo "Error: listener failed." >&2
        exit 1
    fi
done