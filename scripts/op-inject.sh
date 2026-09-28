#!/bin/bash
set -euo pipefail

_OP_SCRIPT_NAME="op-inject"
_OP_SUPPRESS_STDERR="false"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_op-tactile-common.sh
source "${SCRIPT_DIR}/../libexec/_op-tactile-common.sh"

_op_tactile_require_op

show_help() {
  cat >&2 <<'HELP'
op-inject — 1Password template injector with Connect server failover

USAGE:
  op-inject -i <template_file> -o <output_file>
  op-inject -i <template_file>                    (output to stdout)
  op-inject [any op inject flags...]
  op-inject --help

HOW IT WORKS:
  Wraps `op inject` with the same Connect-first, service-account-fallback
  strategy as op-read. All flags are passed through to `op inject`.

  NOTE: When using process substitution as input (e.g. -i <(cmd)), if
  Connect fails the fallback will also fail because the input stream was
  already consumed. Use actual files when failover is important.

ENVIRONMENT VARIABLES:
  OP_CONNECT_HOST           Connect server URL
  OP_CONNECT_TOKEN          Connect server access token
  OP_SERVICE_ACCOUNT_TOKEN  Service account token (fallback)
  OP_CONNECT_TIMEOUT        Connect timeout per attempt in seconds (default: 10)
  OP_CONNECT_ATTEMPTS       Safe readiness/GET attempts (default: 3)

EXAMPLES:
  op-inject -i .env.tpl -o .env
  op-inject -i config.tpl -o config.json
HELP
  exit 0
}

if [ $# -eq 0 ]; then
  echo "Usage: op-inject -i <template> [-o <output>] [op inject flags...]" >&2
  echo "       op-inject --help" >&2
  exit 1
fi

[ "$1" = "--help" ] || [ "$1" = "-h" ] && show_help

_op_exec_with_failover op inject "$@"
