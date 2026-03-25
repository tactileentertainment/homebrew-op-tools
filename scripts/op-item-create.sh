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
  op-item-create --category <cat> --title <title> --vault <vault> [field=value ...]
  op-item-create [any op item create flags...]
  op-item-create --help

HOW IT WORKS:
  Wraps `op item create` with the same Connect-first, service-account-fallback
  strategy as op-read. All flags are passed through to `op item create`.

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-item-create --category apicredential --title "my-secret" --vault "my-vault" "credential=value"
  op-item-create --category password --title "server-pwd" --vault "my-vault" "password=s3cret"
HELP
  exit 0
}

if [ $# -eq 0 ]; then
  echo "Usage: op-item-create --category <cat> --title <title> --vault <vault> [field=value ...]" >&2
  echo "       op-item-create --help" >&2
  exit 1
fi

[ "$1" = "--help" ] || [ "$1" = "-h" ] && show_help

_op_exec_with_failover op item create "$@"
