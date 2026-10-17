#!/usr/bin/env bash

# Discover the container's IPv4 address.
server_ip=$(ifconfig eth0 | awk '/inet / {print $2}')

if [[ -z "$server_ip" ]]; then
    echo "Error: could not determine the server IP address." >&2
    exit 1
fi

printf 'Server IP: %s\n' "$server_ip"
