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

# Returns 0 if jq is available, 1 otherwise
_op_require_jq() {
  command -v jq &>/dev/null
}

# ─── Connect REST API helpers ───────────────────────────────────────────────

# Makes an HTTP request to the Connect REST API.
# Args: METHOD ENDPOINT [BODY]
# Stdout: response body
# Returns: 0 on 2xx, 1 on failure
_op_connect_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local connect_timeout="${OP_CONNECT_TIMEOUT:-3}"
  local url="${OP_CONNECT_HOST}${endpoint}"
  local response_file http_code

  response_file="$(mktemp)"

  local curl_args=(
    -s --fail-with-body
    --max-time "$connect_timeout"
    -X "$method"
    -H "Authorization: Bearer ${OP_CONNECT_TOKEN}"
    -H "Content-Type: application/json"
    -w "%{http_code}"
    -o "$response_file"
  )

  if [ -n "$body" ]; then
    curl_args+=(-d "$body")
  fi

  http_code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || {
    local err
    err=$(cat "$response_file" 2>/dev/null)
    rm -f "$response_file"
    [ -n "$err" ] && echo "${_OP_SCRIPT_NAME}: Connect API error: $err" >&2
    return 1
  }

  if [[ "$http_code" =~ ^2 ]]; then
    cat "$response_file"
    rm -f "$response_file"
    return 0
  else
    local err
    err=$(cat "$response_file" 2>/dev/null)
    rm -f "$response_file"
    echo "${_OP_SCRIPT_NAME}: Connect API returned HTTP $http_code" >&2
    [ -n "$err" ] && echo "${_OP_SCRIPT_NAME}: $err" >&2
    return 1
  fi
}

# Resolves a vault name to its UUID. If input looks like a UUID, returns as-is.
# Args: VAULT_NAME_OR_ID
# Stdout: vault UUID
_op_resolve_vault_id() {
  local vault="$1"
  # If it looks like a UUID, return as-is
  if [[ "$vault" =~ ^[a-z0-9]{26}$ ]]; then
    echo "$vault"
    return 0
  fi
  local encoded_name
  encoded_name=$(printf '%s' "$vault" | jq -sRr @uri)
  local response
  response=$(_op_connect_api GET "/v1/vaults?filter=name%20eq%20%22${encoded_name}%22") || return 1
  local vault_id
  vault_id=$(echo "$response" | jq -r '.[0].id // empty')
  if [ -z "$vault_id" ]; then
    echo "${_OP_SCRIPT_NAME}: Vault not found: $vault" >&2
    return 1
  fi
  echo "$vault_id"
}

# Resolves an item title to its UUID within a vault. If input looks like a UUID, returns as-is.
# Args: VAULT_ID ITEM_TITLE_OR_ID
# Stdout: item UUID
_op_resolve_item_id() {
  local vault_id="$1"
  local item="$2"
  # If it looks like a UUID, return as-is
  if [[ "$item" =~ ^[a-z0-9]{26}$ ]]; then
    echo "$item"
    return 0
  fi
  local encoded_title
  encoded_title=$(printf '%s' "$item" | jq -sRr @uri)
  local response
  response=$(_op_connect_api GET "/v1/vaults/${vault_id}/items?filter=title%20eq%20%22${encoded_title}%22") || return 1
  local item_id
  item_id=$(echo "$response" | jq -r '.[0].id // empty')
  if [ -z "$item_id" ]; then
    echo "${_OP_SCRIPT_NAME}: Item not found: $item" >&2
    return 1
  fi
  echo "$item_id"
}

# Maps op CLI category names to Connect API format.
# Args: CLI_CATEGORY
# Stdout: API category string
_op_category_to_connect() {
  local cli_cat="${1,,}" # lowercase
  case "$cli_cat" in
    apicredential|api_credential) echo "API_CREDENTIAL" ;;
    login)        echo "LOGIN" ;;
    password)     echo "PASSWORD" ;;
    securenote|secure_note) echo "SECURE_NOTE" ;;
    server)       echo "SERVER" ;;
    database)     echo "DATABASE" ;;
    document)     echo "DOCUMENT" ;;
    softwarelicense|software_license) echo "SOFTWARE_LICENSE" ;;
    *)            echo "${cli_cat^^}" ;;  # uppercase fallback
  esac
}

# Parses "key=value" field assignments into a JSON fields array.
# Args: field assignments (key=value ...)
# Stdout: JSON array of field objects
_op_parse_field_assignments() {
  local json="[]"
  for assignment in "$@"; do
    local key="${assignment%%=*}"
    local value="${assignment#*=}"
    # Skip bare "-" (sometimes used as stdin indicator)
    [ "$key" = "-" ] && continue
    local field_type="STRING"
    case "$key" in
      password|credential) field_type="CONCEALED" ;;
    esac
    json=$(echo "$json" | jq --arg id "$key" --arg val "$value" --arg type "$field_type" \
      '. + [{"id": $id, "value": $val, "type": $type}]')
  done
  echo "$json"
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
  if [ -n "${OP_CONNECT_TOKEN:-}" ] && [ -n "${OP_CONNECT_HOST:-}" ]; then
    echo "${_OP_SCRIPT_NAME}: Connect server unavailable (circuit breaker tripped). Set OP_SERVICE_ACCOUNT_TOKEN for fallback." >&2
  else
    echo "${_OP_SCRIPT_NAME}: No credentials configured. Set OP_CONNECT_HOST + OP_CONNECT_TOKEN (preferred) or OP_SERVICE_ACCOUNT_TOKEN or both." >&2
  fi
  return 1
}
