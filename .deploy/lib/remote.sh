# shellcheck shell=bash
#
# How another host is reached: the bounds on an ssh connection to it. Needs nothing else. Sourced
# through .deploy/lib.sh.

# BatchMode, so a host that asks for a password fails at once. ConnectTimeout alone bounds only the
# handshake: a host that answers and then stops holds the connection open, and a copy or a load
# waits on it indefinitely. The keepalives are what end it; they are answered by sshd, so an idle
# hour of loading is not taken for a dead connection.
#
# The port, the key and the user are left to ~/.ssh/config, or to the caller.
# shellcheck disable=SC2034  # read by the scripts that source this file.
readonly SSH_CONNECTION_BOUNDS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
