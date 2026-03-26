#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="op-item-edit"
_OP_SUPPRESS_STDERR="false"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_op-tactile-common.sh
source "${SCRIPT_DIR}/../libexec/_op-tactile-common.sh"

_op_tactile_require_op

show_help() {
  cat >&2 <<'HELP'
op-item-edit — 1Password item editor with Connect server failover

USAGE:
  op-item-edit <item> --vault <vault> [field=value ...]
  op-item-edit --help

OPTIONS:
  --vault <vault>   Vault name or ID (required)

ARGUMENTS:
  <item>            Item ID or title to edit (required, first positional arg)
  field=value       Field assignments to update (e.g., "credential=newsecret")

HOW IT WORKS:
  1. If OP_CONNECT_HOST + OP_CONNECT_TOKEN are set, edits via Connect REST API (curl):
     - GETs the current item, updates fields in-place, PUTs the modified item back
  2. If Connect fails, trips a circuit breaker and falls back to the op CLI with
     OP_SERVICE_ACCOUNT_TOKEN
  3. Requires jq for the Connect path; falls back to op CLI if jq is missing

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-item-edit "API Key" --vault my-vault "credential=newsecret"
  op-item-edit abc12defghijklmnopqrstuvwx --vault my-vault "password=updated"
HELP
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

VAULT=""
ITEM=""
FIELDS=()

if [ $# -eq 0 ]; then
  echo "Usage: op-item-edit <item> --vault <vault> [field=value ...]" >&2
  echo "       op-item-edit --help" >&2
  exit 1
fi

# First positional arg is the item (before any flags)
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)  show_help ;;
    --vault)    VAULT="$2"; shift 2 ;;
    --)         shift; FIELDS+=("$@"); break ;;
    -*)         echo "${_OP_SCRIPT_NAME}: Unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$ITEM" ]; then
        ITEM="$1"
      else
        FIELDS+=("$1")
      fi
      shift
      ;;
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
if [ ${#FIELDS[@]} -eq 0 ]; then
  echo "${_OP_SCRIPT_NAME}: At least one field=value assignment is required" >&2
  exit 1
fi

# ── Connect path (curl) ─────────────────────────────────────────────────────

connect_edit() {
  local vault_id item_id current_item updated_item

  vault_id=$(_op_resolve_vault_id "$VAULT") || return 1
  item_id=$(_op_resolve_item_id "$vault_id" "$ITEM") || return 1

  # GET the full current item
  current_item=$(_op_connect_api GET "/v1/vaults/${vault_id}/items/${item_id}") || return 1

  # Update fields in-place
  updated_item="$current_item"
  for assignment in "${FIELDS[@]}"; do
    local key="${assignment%%=*}"
    local value="${assignment#*=}"
    # Skip bare "-"
    [ "$key" = "-" ] && continue

    # Check if the field exists; if so update it, otherwise add it
    local field_exists
    field_exists=$(echo "$updated_item" | jq --arg id "$key" '[.fields[] | select(.id == $id or .label == $id)] | length')

    if [ "$field_exists" -gt 0 ]; then
      # Update existing field by id or label
      updated_item=$(echo "$updated_item" | jq --arg id "$key" --arg val "$value" \
        '.fields = [.fields[] | if (.id == $id or .label == $id) then .value = $val else . end]')
    else
      # Add new field
      local field_type="STRING"
      case "$key" in
        password|credential) field_type="CONCEALED" ;;
      esac
      updated_item=$(echo "$updated_item" | jq --arg id "$key" --arg val "$value" --arg type "$field_type" \
        '.fields += [{"id": $id, "label": $id, "value": $val, "type": $type}]')
    fi
  done

  # PUT the updated item back
  _op_connect_api PUT "/v1/vaults/${vault_id}/items/${item_id}" "$updated_item" >/dev/null || return 1
  return 0
}

# ── Try Connect, then fallback ───────────────────────────────────────────────

if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ] && _op_connect_available && _op_require_jq; then
  if connect_edit; then
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
    op item edit "$ITEM" --vault "$VAULT" "${FIELDS[@]}" 2>"$err_file" || {
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
