#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="test"
_OP_SUPPRESS_STDERR="true"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/_op-tactile-common.sh
source "${ROOT_DIR}/scripts/_op-tactile-common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export OP_CONNECT_HOST="https://connect.example.test"
export OP_CONNECT_TOKEN="test-token"
CALL_COUNT_FILE="${TEST_DIR}/calls"
TIMEOUTS_FILE="${TEST_DIR}/timeouts"
COMMAND_CALLS_FILE="${TEST_DIR}/command-calls"
COMMAND_TIMEOUTS_FILE="${TEST_DIR}/command-timeouts"
FALLBACK_CALLS_FILE="${TEST_DIR}/fallback-calls"
export CIRCUIT_BREAKER="${TEST_DIR}/circuit-breaker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "${message}: expected '${expected}', got '${actual}'"
}

reset_calls() {
  echo 0 > "$CALL_COUNT_FILE"
  : > "$TIMEOUTS_FILE"
  echo 0 > "$COMMAND_CALLS_FILE"
  : > "$COMMAND_TIMEOUTS_FILE"
  echo 0 > "$FALLBACK_CALLS_FILE"
  rm -f "$CIRCUIT_BREAKER"
}

curl() {
  local output_file=""
  local max_time=""
  local count

  while [ $# -gt 0 ]; do
    case "$1" in
      -o) output_file="$2"; shift 2 ;;
      -X) shift 2 ;;
      --max-time) max_time="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  count=$(cat "$CALL_COUNT_FILE")
  count=$((count + 1))
  echo "$count" > "$CALL_COUNT_FILE"
  echo "$max_time" >> "$TIMEOUTS_FILE"

  case "${CURL_SCENARIO}" in
    succeeds-on-third)
      if [ "$count" -lt 3 ]; then
        printf '000'
        return 28
      fi
      printf '{"ok":true}' > "$output_file"
      printf '200'
      ;;
    permanent-403)
      printf '{"message":"forbidden"}' > "$output_file"
      printf '403'
      return 22
      ;;
    always-timeout)
      printf '000'
      return 28
      ;;
    always-success)
      printf '{"ok":true}' > "$output_file"
      printf '200'
      ;;
    *)
      fail "unknown curl scenario: ${CURL_SCENARIO}"
      ;;
  esac
}

timeout() {
  local count
  count=$(cat "$COMMAND_CALLS_FILE")
  echo $((count + 1)) > "$COMMAND_CALLS_FILE"
  echo "$1" >> "$COMMAND_TIMEOUTS_FILE"
  if [ "${TIMEOUT_SCENARIO}" = "times-out" ]; then
    return 124
  fi
  printf 'secret-value'
}

env() {
  local count
  count=$(cat "$FALLBACK_CALLS_FILE")
  echo $((count + 1)) > "$FALLBACK_CALLS_FILE"
  printf 'fallback-value'
}

reset_calls
CURL_SCENARIO="succeeds-on-third"
response=$(_op_connect_api GET "/v1/vaults" 2>"${TEST_DIR}/retry-stderr")
assert_eq '{"ok":true}' "$response" "GET response"
assert_eq 3 "$(cat "$CALL_COUNT_FILE")" "transient GET attempt count"
assert_eq $'10\n10\n10' "$(cat "$TIMEOUTS_FILE")" "default timeout per attempt"

reset_calls
CURL_SCENARIO="permanent-403"
if _op_connect_api GET "/v1/vaults" >/dev/null 2>"${TEST_DIR}/403-stderr"; then
  fail "permanent 403 unexpectedly succeeded"
fi
assert_eq 1 "$(cat "$CALL_COUNT_FILE")" "permanent HTTP error attempt count"

reset_calls
CURL_SCENARIO="always-timeout"
if _op_connect_api POST "/v1/vaults/vault-id/items" '{}' >/dev/null 2>"${TEST_DIR}/post-stderr"; then
  fail "timed-out POST unexpectedly succeeded"
fi
assert_eq 1 "$(cat "$CALL_COUNT_FILE")" "mutating request attempt count"

reset_calls
CURL_SCENARIO="always-timeout"
export OP_CONNECT_ATTEMPTS=2
if _op_connect_api GET "/v1/vaults" >/dev/null 2>"${TEST_DIR}/attempts-stderr"; then
  fail "timed-out GET unexpectedly succeeded"
fi
assert_eq 2 "$(cat "$CALL_COUNT_FILE")" "configured GET attempt count"
unset OP_CONNECT_ATTEMPTS

reset_calls
CURL_SCENARIO="succeeds-on-third"
TIMEOUT_SCENARIO="succeeds"
result=$(_op_exec_with_failover op read 'op://vault/item/field' 2>"${TEST_DIR}/command-stderr")
assert_eq 'secret-value' "$result" "command output"
assert_eq 3 "$(cat "$CALL_COUNT_FILE")" "readiness attempt count"
assert_eq 1 "$(cat "$COMMAND_CALLS_FILE")" "requested command execution count"
assert_eq 10 "$(cat "$COMMAND_TIMEOUTS_FILE")" "requested command timeout"

reset_calls
CURL_SCENARIO="always-success"
TIMEOUT_SCENARIO="times-out"
export OP_SERVICE_ACCOUNT_TOKEN="fallback-token"
result=$(_op_exec_with_failover op read 'op://vault/item/field' 2>"${TEST_DIR}/fallback-stderr")
assert_eq 'fallback-value' "$result" "fallback output"
assert_eq 1 "$(cat "$COMMAND_CALLS_FILE")" "timed-out command execution count"
assert_eq 1 "$(cat "$FALLBACK_CALLS_FILE")" "service-account fallback count"
unset OP_SERVICE_ACCOUNT_TOKEN

echo "All Connect retry tests passed"
