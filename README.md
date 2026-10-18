# INFO1112 Assignment 2

## Setup progress
- Created the Alpine Docker container myserver with port 1234 forwarded.
- Verified Windows-to-container connectivity by sending my name.
- Created the assignment working directory in Ubuntu WSL 2.

- Verified Ubuntu-to-Alpine connectivity using nc on port 1234; captured client and server screenshots.

- Installed bash, curl, iproute2, and net-tools in the Alpine server container.

## Test (a): server not listening
Stopped server.sh while leaving myserver running.
Confirmed ss -ltnp showed no listening TCP sockets.
A separate Alpine client container using OpenBSD nc connected directly
to myserver's container IP on port 1234.
Observed: Connection refused; exit status 1.

The Ubuntu-to-localhost probe returned success through Docker Desktop's
published port, so it was not used as evidence of connection refusal.
