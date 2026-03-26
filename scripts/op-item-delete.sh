#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="op-item-delete"
_OP_SUPPRESS_STDERR="false"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_op-tactile-common.sh
source "${SCRIPT_DIR}/../libexec/_op-tactile-common.sh"

_op_tactile_require_op

show_help() {
  cat >&2 <<'HELP'
op-item-delete — 1Password item deleter with Connect server failover

USAGE:
  op-item-delete --vault <vault> <item>
  op-item-delete --help

OPTIONS:
  --vault <vault>   Vault name or ID (required)

ARGUMENTS:
  <item>            Item ID or title to delete (required)

HOW IT WORKS:
  1. If OP_CONNECT_HOST + OP_CONNECT_TOKEN are set, deletes via Connect REST API (curl)
  2. If Connect fails, trips a circuit breaker and falls back to the op CLI with
     OP_SERVICE_ACCOUNT_TOKEN
  3. Requires jq for the Connect path; falls back to op CLI if jq is missing

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-item-delete --vault my-vault "API Key"
  op-item-delete --vault my-vault abc12defghijklmnopqrstuvwx
HELP
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

VAULT=""
ITEM=""

if [ $# -eq 0 ]; then
  echo "Usage: op-item-delete --vault <vault> <item>" >&2
  echo "       op-item-delete --help" >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)  show_help ;;
    --vault)    VAULT="$2"; shift 2 ;;
    --)         shift; [ $# -gt 0 ] && ITEM="$1"; break ;;
    -*)         echo "${_OP_SCRIPT_NAME}: Unknown option: $1" >&2; exit 1 ;;
    *)          ITEM="$1"; shift ;;
  esac
done

if [ -z "$VAULT" ]; then
  echo "${_OP_SCRIPT_NAME}: --vault is required" >&2
  exit 1
fi
if [ -z "$ITEM" ]; then
  echo "${_OP_SCRIPT_NAME}: Item ID or title is required" >&2
  exit 1
fi

# ── Connect path (curl) ─────────────────────────────────────────────────────

connect_delete() {
  local vault_id item_id

  vault_id=$(_op_resolve_vault_id "$VAULT") || return 1
  item_id=$(_op_resolve_item_id "$vault_id" "$ITEM") || return 1

  _op_connect_api DELETE "/v1/vaults/${vault_id}/items/${item_id}" || return 1
  return 0
}

# ── Try Connect, then fallback ───────────────────────────────────────────────

if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ] && _op_connect_available && _op_require_jq; then
  if connect_delete; then
    exit 0
  fi
  echo "${_OP_SCRIPT_NAME}: Connect failed, tripping circuit breaker" >&2
  _op_trip_circuit_breaker
fi

# ── Service account fallback ─────────────────────────────────────────────────

if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  [ -n "${OP_CONNECT_TOKEN:-}" ] && echo "${_OP_SCRIPT_NAME}: Falling back to service account" >&2
  err_file="$(mktemp)"
  env -i \
    HOME="$HOME" PATH="$PATH" \
    OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
    op item delete "$ITEM" --vault "$VAULT" 2>"$err_file" || {
      echo "${_OP_SCRIPT_NAME}: Failed via service account" >&2
      [ -s "$err_file" ] && cat "$err_file" >&2
      rm -f "$err_file"
      exit 1
    }
  [ -s "$err_file" ] && cat "$err_file" >&2
  rm -f "$err_file"
  exit 0
fi

if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ]; then
  echo "${_OP_SCRIPT_NAME}: Connect server unavailable (circuit breaker tripped). Set OP_SERVICE_ACCOUNT_TOKEN for fallback." >&2
else
  echo "${_OP_SCRIPT_NAME}: No credentials configured. Set OP_CONNECT_HOST + OP_CONNECT_TOKEN (preferred) or OP_SERVICE_ACCOUNT_TOKEN or both." >&2
fi
exit 1
