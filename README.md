# op-tools

Homebrew tap for **op-tactile** — 1Password CLI wrappers with automatic Connect server failover to service account.

## Install

```bash
brew tap tactileentertainment/op-tools
brew install op-tactile
```

### Docker / CI (without Homebrew)

```bash
VERSION=v1.5.0
BASE_URL="https://raw.githubusercontent.com/tactileentertainment/homebrew-op-tools/${VERSION}/scripts"
mkdir -p /usr/local/libexec
curl -fsSL "${BASE_URL}/_op-tactile-common.sh" -o /usr/local/libexec/_op-tactile-common.sh
for cmd in op-read op-inject op-item-create op-item-delete op-item-edit; do
  curl -fsSL "${BASE_URL}/${cmd}.sh" -o /usr/local/bin/${cmd}
  chmod +x /usr/local/bin/${cmd}
  sed -i 's|${SCRIPT_DIR}/../libexec/_op-tactile-common.sh|/usr/local/libexec/_op-tactile-common.sh|' /usr/local/bin/${cmd}
done
```

## Commands

| Command | Wraps | Description |
|---------|-------|-------------|
| `op-read` | `op read` / `op item get` | Read secrets |
| `op-inject` | `op inject` | Inject secrets into template files |
| `op-item-create` | `op item create` | Create 1Password items |
| `op-item-delete` | `op item delete` | Delete 1Password items |
| `op-item-edit` | `op item edit` | Edit 1Password items |

## Usage

```bash
# op-read — URI mode
op-read op://vault/item/field

# op-read — CLI mode (field defaults to "password")
op-read <vault> <item> [field]

# op-inject — inject secrets into a template file
op-inject -i .env.tpl -o .env

# op-item-create — create a new item
op-item-create --category apicredential --title "my-secret" --vault "my-vault" "credential=value"

# op-item-delete — delete an item
op-item-delete --vault "my-vault" "my-item-title"

# op-item-edit — edit an existing item
op-item-edit "my-item" --vault "my-vault" "username=newuser"

# All commands support --help
op-read --help
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OP_CONNECT_HOST` | One set required | Connect server URL |
| `OP_CONNECT_TOKEN` | One set required | Connect server access token |
| `OP_SERVICE_ACCOUNT_TOKEN` | One set required | Service account token (fallback) |
| `OP_CONNECT_TIMEOUT` | Optional | Connect timeout in seconds (default: 3) |

## How It Works

All commands share the same failover strategy:

1. If `OP_CONNECT_TOKEN` and `OP_CONNECT_HOST` are set, tries the Connect server first
2. If Connect fails, trips a circuit breaker and falls back to the service account
3. Subsequent calls skip Connect (circuit breaker) to avoid cumulative timeout delays
4. If only `OP_SERVICE_ACCOUNT_TOKEN` is set, uses the service account directly

## Prerequisites

Requires the [1Password CLI](https://developer.1password.com/docs/cli/get-started/):

```bash
brew install --cask 1password-cli
```

Each command checks for `op` at runtime and prints install instructions if it's missing.

## Migrating from op-read

If you were using the standalone `op-read` formula:

```bash
brew uninstall op-read
brew untap tactileentertainment/op-read
brew tap tactileentertainment/op-tools
brew install op-tactile
```

The `op-read` command works identically — no changes to your scripts are needed.
