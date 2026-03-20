#!/bin/bash
set -euo pipefail

# Reads a 1Password secret with automatic failover.
# Primary:  1Password Connect server (via op CLI with OP_CONNECT_HOST/OP_CONNECT_TOKEN)
# Fallback: 1Password service account API (via op CLI with OP_SERVICE_ACCOUNT_TOKEN)
#
# Uses a circuit breaker: if Connect fails once, all subsequent reads in the
# same deployment skip Connect and go straight to service account, avoiding
# cumulative timeout delays across many reads.
#
# Usage (two calling conventions):
#   op-read <op://vault/item/field>        # URI mode
#   op-read <vault> <item> [field]          # CLI mode (field defaults to "password")
#
# Required env vars (at least one set):
#   OP_CONNECT_HOST  - Connect server URL
#   OP_CONNECT_TOKEN - Connect server access token
#   OP_SERVICE_ACCOUNT_TOKEN - Service account token (fallback)
#
# Optional env vars:
#   OP_CONNECT_TIMEOUT - Connect timeout in seconds (default: 3)

show_help() {
  cat >&2 <<'HELP'
op-read — 1Password secret reader with Connect server failover

USAGE:
  op-read <op://vault/item/field>        URI mode
  op-read <vault> <item> [field]         CLI mode (field defaults to "password")
  op-read --help                         Show this help message

HOW IT WORKS:
  1. If OP_CONNECT_HOST + OP_CONNECT_TOKEN are set, reads via Connect server first
  2. If Connect fails or times out, trips a circuit breaker so subsequent reads
     skip Connect and go straight to the service account (avoids cumulative delays)
  3. Falls back to OP_SERVICE_ACCOUNT_TOKEN if Connect is unavailable
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
  # URI mode: op-read "op://vault/item/field"
  OP_CMD_ARGS=( op read "$1" )
  LABEL="$1"
else
  # CLI mode: op-read <vault> <item> [field]
  VAULT="$1"
  ITEM="$2"
  FIELD="${3:-password}"
  OP_CMD_ARGS=( op item get "$ITEM" --vault "$VAULT" --fields "$FIELD" --reveal )
  LABEL="$ITEM in $VAULT"
fi

CONNECT_TIMEOUT="${OP_CONNECT_TIMEOUT:-3}"
CIRCUIT_BREAKER="/tmp/op-connect-circuit-breaker"

# Check if the circuit breaker has been tripped (Connect failed recently)
connect_available() {
  [ ! -f "$CIRCUIT_BREAKER" ]
}

SECRET_VALUE=""

# Try Connect server first
if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ] && connect_available; then
  SECRET_VALUE=$(timeout "${CONNECT_TIMEOUT}" env -i \
    HOME="$HOME" PATH="$PATH" \
    OP_CONNECT_HOST="${OP_CONNECT_HOST}" \
    OP_CONNECT_TOKEN="${OP_CONNECT_TOKEN}" \
    "${OP_CMD_ARGS[@]}" 2>/dev/null) || {
    echo "op-read: Connect failed for ${LABEL}, tripping circuit breaker" >&2
    touch "$CIRCUIT_BREAKER"
    SECRET_VALUE=""
  }
fi

# Fallback to service account
if [ -z "$SECRET_VALUE" ]; then
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    [ -n "${OP_CONNECT_TOKEN:-}" ] && echo "op-read: Falling back to service account for ${LABEL}" >&2
    SECRET_VALUE=$(env -i \
      HOME="$HOME" PATH="$PATH" \
      OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
      "${OP_CMD_ARGS[@]}" 2>/dev/null) || {
      echo "op-read: Failed to read ${LABEL} via service account" >&2
      exit 1
    }
  else
    echo "op-read: No credentials configured. Set OP_CONNECT_HOST + OP_CONNECT_TOKEN (preferred) or OP_SERVICE_ACCOUNT_TOKEN or both to create a safe fallback option" >&2
    exit 1
  fi
fi

echo "$SECRET_VALUE"
