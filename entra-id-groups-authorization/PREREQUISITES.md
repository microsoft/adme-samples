# ADME Entra Migration Prerequisites

This script is designed to run in **Azure Cloud Shell**, **WSL**, or a standard **Linux** environment.

## Required tools

| Tool | Why it is needed |
|------|------------------|
| `az` | Microsoft Graph and Entra operations |
| `jq` | JSON filtering used throughout the migration workflow |
| `base64` | Token payload decoding during `verify` |

## Optional tools

| Tool | When it is used |
|------|------------------|
| `python3` + `msal` | Enables the extra delegated-token forced-refresh proof in `verify` |

If `python3` with the `msal` package is not available, `verify` still succeeds. It warns and skips only the **enhanced delegated forced-refresh proof**. The Graph-based delegated-grant verification still runs.

## Supported environments

### Azure Cloud Shell

Expected to already include:

- `az`
- `jq`
- `base64`
- `python3` may be present, but `msal` is not required

### Linux / WSL

Install the required tools before running the script.

Ubuntu / Debian example:

```bash
sudo apt-get update
sudo apt-get install -y jq coreutils
```

Install Azure CLI using the Microsoft instructions for your distro:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Optional enhanced delegated verification:

```bash
python3 -m pip install --user msal
```

## Azure sign-in requirements

The saved Azure CLI profiles used by the script must already be signed in to the correct tenants.

Examples:

```bash
AZURE_CONFIG_DIR="$HOME/.azure-tenant-KSAD" az login --tenant <HOME_TENANT_ID>
AZURE_CONFIG_DIR="$HOME/.azure-tenant-KSAD2" az login --tenant <CUSTOMER_TENANT_ID>
```

## Required Entra roles

The operator should have one of the following roles in the target tenant when running the migration steps that modify applications or service principals:

- Application Administrator
- Cloud Application Administrator
- Global Administrator

## Verify behavior summary

`verify` performs two token-path checks:

1. **App-only proof** — uses an isolated `AZURE_CONFIG_DIR`, signs in with `az login --service-principal`, then acquires a token with `az account get-access-token --resource`.
2. **Delegated forced-refresh proof** — runs only when `python3` + `msal` are available.

The isolated service-principal login used for the app-only proof does **not** reuse or overwrite the operator's normal Azure CLI profile.
