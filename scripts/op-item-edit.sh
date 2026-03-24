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
  op-item-edit <item_id_or_title> [field assignments...] [flags...]
  op-item-edit [any op item edit flags...]
  op-item-edit --help

HOW IT WORKS:
  Wraps `op item edit` with the same Connect-first, service-account-fallback
  strategy as op-read. All flags are passed through to `op item edit`.

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout in seconds (default: 3)

EXAMPLES:
  op-item-edit "my-item" --vault "my-vault" "username=newuser"
  op-item-edit "abc123" --vault "my-vault" "credential=newvalue"
HELP
  exit 0
}

if [ $# -eq 0 ]; then
  echo "Usage: op-item-edit <item_id_or_title> [field assignments...] [flags...]" >&2
  echo "       op-item-edit --help" >&2
  exit 1
fi

[ "$1" = "--help" ] || [ "$1" = "-h" ] && show_help

_op_exec_with_failover op item edit "$@"
