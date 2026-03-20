# homebrew-op-read

Homebrew tap for **op-read** — a 1Password secret reader with automatic Connect server failover to service account.

## Install

```bash
brew tap tactileentertainment/op-read
brew install op-read
```

## Usage

```bash
# URI mode
op-read op://vault/item/field

# CLI mode (field defaults to "password")
op-read <vault> <item> [field]
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OP_CONNECT_HOST` | One set required | Connect server URL |
| `OP_CONNECT_TOKEN` | One set required | Connect server access token |
| `OP_SERVICE_ACCOUNT_TOKEN` | One set required | Service account token (fallback) |
| `OP_CONNECT_TIMEOUT` | Optional | Connect timeout in seconds (default: 3) |

## How It Works

1. If `OP_CONNECT_TOKEN` and `OP_CONNECT_HOST` are set, tries the Connect server first
2. If Connect fails, trips a circuit breaker and falls back to the service account
3. Subsequent reads skip Connect (circuit breaker) to avoid cumulative timeout delays
4. If only `OP_SERVICE_ACCOUNT_TOKEN` is set, uses the service account directly

## Prerequisites

Requires the [1Password CLI](https://developer.1password.com/docs/cli/get-started/):

```bash
brew install --cask 1password-cli
```
