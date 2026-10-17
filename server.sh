#!/usr/bin/env bash

# Discover the container's IPv4 address.
server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [[ -z "$server_ip" ]]; then
    echo "Error: could not determine the server IP address." >&2
    exit 1
fi

printf 'Server IP: %s\n' "$server_ip"

# The listening port is supplied through the environment.
if [[ -z "${SERVER_PORT:-}" ]]; then
    echo "Error: set SERVER_PORT before starting the server." >&2
    exit 1
fi

while true; do
    printf 'Waiting for a request...\n'

    if request=$(nc -l -p "$SERVER_PORT" </dev/null); then
        printf 'Received: %s\n' "$request"
    else
        echo "Error: failed to receive a request." >&2
        exit 1
    fi
done
