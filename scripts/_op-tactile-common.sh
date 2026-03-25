#!/bin/bash
# Shared library for op-tactile scripts. Source this file; do not execute directly.
#
# Each script must set before sourcing:
#   _OP_SCRIPT_NAME       - script name for log prefixes (e.g. "op-read")
#   _OP_SUPPRESS_STDERR   - "true" to suppress op stderr (for read ops), "false" to show it

CIRCUIT_BREAKER="/tmp/op-connect-circuit-breaker"

_op_tactile_require_op() {
  if ! command -v op &>/dev/null; then
    echo "${_OP_SCRIPT_NAME}: ERROR: 1Password CLI (op) not found." >&2
    echo "  Install with: brew install --cask 1password-cli" >&2
    echo "  Or see: https://developer.1password.com/docs/cli/get-started/" >&2
    exit 1
  fi
}

_op_connect_available() {
  [ ! -f "$CIRCUIT_BREAKER" ]
}

_op_trip_circuit_breaker() {
  touch "$CIRCUIT_BREAKER"
}

# Runs an op command with Connect-first, service-account-fallback strategy.
# Arguments: the full op command (e.g. op read "op://vault/item/field")
# Stdout: the command's output
_op_exec_with_failover() {
  local connect_timeout="${OP_CONNECT_TIMEOUT:-3}"
  local result=""
  local err_file=""
  err_file="$(mktemp)"

  # Try Connect server first
  if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ] && _op_connect_available; then
    if [ "$_OP_SUPPRESS_STDERR" = "true" ]; then
      result=$(timeout "${connect_timeout}" env -i \
        HOME="$HOME" PATH="$PATH" \
        OP_CONNECT_HOST="${OP_CONNECT_HOST}" \
        OP_CONNECT_TOKEN="${OP_CONNECT_TOKEN}" \
        "$@" 2>"$err_file") && {
          rm -f "$err_file"
          echo "$result"
          return 0
        }
    else
      result=$(timeout "${connect_timeout}" env -i \
        HOME="$HOME" PATH="$PATH" \
        OP_CONNECT_HOST="${OP_CONNECT_HOST}" \
        OP_CONNECT_TOKEN="${OP_CONNECT_TOKEN}" \
        "$@" 2>"$err_file") && {
          [ -s "$err_file" ] && cat "$err_file" >&2
          rm -f "$err_file"
          echo "$result"
          return 0
        }
    fi
    echo "${_OP_SCRIPT_NAME}: Connect failed, tripping circuit breaker" >&2
    _op_trip_circuit_breaker
  fi

  # Fallback to service account
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    [ -n "${OP_CONNECT_TOKEN:-}" ] && echo "${_OP_SCRIPT_NAME}: Falling back to service account" >&2
    if [ "$_OP_SUPPRESS_STDERR" = "true" ]; then
      result=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
        "$@" 2>"$err_file") || {
          echo "${_OP_SCRIPT_NAME}: Failed via service account" >&2
          [ -s "$err_file" ] && cat "$err_file" >&2
          rm -f "$err_file"
          return 1
        }
    else
      result=$(env -i \
        HOME="$HOME" PATH="$PATH" \
        OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
        "$@" 2>"$err_file") || {
          echo "${_OP_SCRIPT_NAME}: Failed via service account" >&2
          [ -s "$err_file" ] && cat "$err_file" >&2
          rm -f "$err_file"
          return 1
        }
      [ -s "$err_file" ] && cat "$err_file" >&2
    fi
    rm -f "$err_file"
    echo "$result"
    return 0
  fi

  rm -f "$err_file"
  echo "${_OP_SCRIPT_NAME}: No credentials configured. Set OP_CONNECT_HOST + OP_CONNECT_TOKEN (preferred) or OP_SERVICE_ACCOUNT_TOKEN or both." >&2
  return 1
}
