#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="op-read"
_OP_SUPPRESS_STDERR="true"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_op-tactile-common.sh
source "${SCRIPT_DIR}/../libexec/_op-tactile-common.sh"

_op_tactile_require_op

show_help() {
  cat >&2 <<'HELP'
op-read — 1Password secret reader with Connect server failover

USAGE:
  op-read <op://vault/item/field>        URI mode
  op-read <vault> <item> [field]         CLI mode (field defaults to "password")
  op-read --help                         Show this help message

HOW IT WORKS:
  1. If OP_CONNECT_HOST + OP_CONNECT_TOKEN are set, reads via Connect server first
  2. If the Connect server is unreachable or times out, trips a circuit breaker so
     subsequent reads skip Connect and go straight to the service account (avoids
     cumulative delays)
  3. Falls back to OP_SERVICE_ACCOUNT_TOKEN only when Connect is unavailable. A
     secret that simply isn't found (Connect reachable) is reported as-is, with no
     fallback and no circuit breaker
  4. Set both credential sets for a safe failover setup

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL (e.g. https://connect.example.com)
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-read op://my-vault/my-item/credential
  op-read my-vault my-item password
HELP
  exit 0
}

# Handle --help and no arguments
if [ $# -eq 0 ]; then
  echo "Usage: op-read <op://vault/item/field>        (URI mode)" >&2
  echo "       op-read <vault> <item> [field]          (CLI mode, field defaults to \"password\")" >&2
  echo "       op-read --help                          (show detailed help)" >&2
  exit 1
fi

[ "$1" = "--help" ] || [ "$1" = "-h" ] && show_help

# Detect calling convention and build the op command args
if [[ "$1" == op://* ]]; then
  OP_CMD_ARGS=( op read "$1" )
else
  VAULT="$1"
  ITEM="$2"
  FIELD="${3:-password}"
  OP_CMD_ARGS=( op item get "$ITEM" --vault "$VAULT" --fields "$FIELD" --reveal )
fi

_op_exec_with_failover "${OP_CMD_ARGS[@]}"
