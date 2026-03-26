#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="op-item-create"
_OP_SUPPRESS_STDERR="false"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_op-tactile-common.sh
source "${SCRIPT_DIR}/../libexec/_op-tactile-common.sh"

_op_tactile_require_op

show_help() {
  cat >&2 <<'HELP'
op-item-create — 1Password item creator with Connect server failover

USAGE:
  op-item-create --vault <vault> --title <title> [--category <cat>] [field=value ...]
  op-item-create --help

OPTIONS:
  --vault <vault>        Vault name or ID (required)
  --title <title>        Item title (required)
  --category <category>  Item category (default: login)
                         Examples: login, apicredential, password, securenote

FIELD ASSIGNMENTS:
  Positional key=value pairs set fields on the item.
  Fields named "password" or "credential" are marked as concealed.

HOW IT WORKS:
  1. If OP_CONNECT_HOST + OP_CONNECT_TOKEN are set, creates via Connect REST API (curl)
  2. If Connect fails, trips a circuit breaker and falls back to the op CLI with
     OP_SERVICE_ACCOUNT_TOKEN
  3. Requires jq for the Connect path; falls back to op CLI if jq is missing

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-item-create --vault my-vault --title "API Key" --category apicredential "credential=secret123"
  op-item-create --vault my-vault --title "DB Creds" "username=admin" "password=s3cret"
HELP
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

VAULT=""
TITLE=""
CATEGORY="login"
FIELDS=()

if [ $# -eq 0 ]; then
  echo "Usage: op-item-create --vault <vault> --title <title> [--category <cat>] [field=value ...]" >&2
  echo "       op-item-create --help" >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)   show_help ;;
    --vault)     VAULT="$2"; shift 2 ;;
    --title)     TITLE="$2"; shift 2 ;;
    --category)  CATEGORY="$2"; shift 2 ;;
    --)          shift; FIELDS+=("$@"); break ;;
    -)           shift ;;  # bare "-" (op CLI stdin indicator) — skip
    -*)          echo "${_OP_SCRIPT_NAME}: Unknown option: $1" >&2; exit 1 ;;
    *)           FIELDS+=("$1"); shift ;;
  esac
done

if [ -z "$VAULT" ]; then
  echo "${_OP_SCRIPT_NAME}: --vault is required" >&2
  exit 1
fi
if [ -z "$TITLE" ]; then
  echo "${_OP_SCRIPT_NAME}: --title is required" >&2
  exit 1
fi

# ── Connect path (curl) ─────────────────────────────────────────────────────

connect_create() {
  local vault_id api_category fields_json body response item_id

  vault_id=$(_op_resolve_vault_id "$VAULT") || return 1
  api_category=$(_op_category_to_connect "$CATEGORY")
  fields_json=$(_op_parse_field_assignments "${FIELDS[@]+"${FIELDS[@]}"}")

  body=$(jq -n \
    --arg vault_id "$vault_id" \
    --arg category "$api_category" \
    --arg title "$TITLE" \
    --argjson fields "$fields_json" \
    '{
      vault: { id: $vault_id },
      category: $category,
      title: $title,
      fields: $fields
    }')

  response=$(_op_connect_api POST "/v1/vaults/${vault_id}/items" "$body") || return 1
  item_id=$(echo "$response" | jq -r '.id // empty')
  if [ -n "$item_id" ]; then
    echo "$response"
    return 0
  fi
  return 1
}

# ── Try Connect, then fallback ───────────────────────────────────────────────

if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ] && _op_connect_available && _op_require_jq; then
  if connect_create; then
    exit 0
  fi
  echo "${_OP_SCRIPT_NAME}: Connect failed, tripping circuit breaker" >&2
  _op_trip_circuit_breaker
fi

# ── Service account fallback ─────────────────────────────────────────────────

if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  [ -n "${OP_CONNECT_TOKEN:-}" ] && echo "${_OP_SCRIPT_NAME}: Falling back to service account" >&2
  err_file="$(mktemp)"
  result=$(env -i \
    HOME="$HOME" PATH="$PATH" \
    OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
    op item create --category "$CATEGORY" --title "$TITLE" --vault "$VAULT" "${FIELDS[@]+"${FIELDS[@]}"}" 2>"$err_file") || {
      echo "${_OP_SCRIPT_NAME}: Failed via service account" >&2
      [ -s "$err_file" ] && cat "$err_file" >&2
      rm -f "$err_file"
      exit 1
    }
  [ -s "$err_file" ] && cat "$err_file" >&2
  rm -f "$err_file"
  echo "$result"
  exit 0
fi

if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ]; then
  echo "${_OP_SCRIPT_NAME}: Connect server unavailable (circuit breaker tripped). Set OP_SERVICE_ACCOUNT_TOKEN for fallback." >&2
else
  echo "${_OP_SCRIPT_NAME}: No credentials configured. Set OP_CONNECT_HOST + OP_CONNECT_TOKEN (preferred) or OP_SERVICE_ACCOUNT_TOKEN or both." >&2
fi
exit 1
