---
title: ADME Entra script prerequisites
description: Prepare Azure Cloud Shell, Linux, or WSL to run the primary ADME inventory and migration scripts for Entra ID groups authorization.
author: kurtschenk
ms.author: kurtschenk
ms.service: azure-data-manager-energy
ms.topic: how-to
ms.date: 05/28/2026
ms.custom:
  - template-how-to
# Customer intent: As an operator, I want to know exactly which tools, roles, and sign-in steps are required before I run the ADME inventory, migration, and verify workflows.
---

# ADME Entra script prerequisites

Use this article to prepare the environment for the primary scripts in this repo:

- `src/adme-entra-inventory.sh`
- `src/adme-entra-migration.sh`
- `src/Invoke-AdmeMigration.ps1`

> [!NOTE]
> Inventory is read-only. The migration and verify prerequisites later in this article apply only when you run `adme-entra-migration.sh` or `Invoke-AdmeMigration.ps1`.

> [!TIP]
> For the end-to-end operator workflow after setup is complete, use [how-to-enable-entra-id-groups-authorization.md](how-to-enable-entra-id-groups-authorization.md).

## Required tools

| Tool | Required for | Why it is needed |
| --- | --- | --- |
| `az` | Inventory, migration, verify | Microsoft Graph, Entra, and token operations |
| `jq` | Inventory, migration, verify | JSON filtering used throughout the scripts |
| `base64` | Verify | Token payload decoding during verification |

Optional tools:

| Tool | When it is used | Notes |
| --- | --- | --- |
| `pwsh` | PowerShell alternative path | Required only if you want to run `Invoke-AdmeMigration.ps1` instead of the bash entrypoint |
| `python3` + `msal` | Enhanced delegated verify path | Enables the optional forced-refresh delegated token proof |

## Choose an environment

### Option 1: Azure Cloud Shell

Azure Cloud Shell already includes `az`, `jq`, `base64`, and `python3`.

> [!NOTE]
> If you plan to use the PowerShell wrapper, open the PowerShell version of Cloud Shell or install PowerShell 7 in your Linux/WSL environment before running `Invoke-AdmeMigration.ps1`.

### Option 2: Linux or WSL

Install the required tools before you run the scripts.

Ubuntu or Debian example:

```bash
sudo apt-get update
sudo apt-get install -y jq coreutils python3 python3-pip
```

Install Azure CLI by following the Microsoft instructions for your distribution:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

If you want the PowerShell alternative, install PowerShell 7:

```bash
sudo apt-get install -y powershell
```

## Sign in to the correct tenant

Before you run the scripts, make sure the Azure CLI context is already signed in to the intended tenant.

Example:

```azurecli
az login --tenant <tenant-id> --allow-no-subscriptions
```

If you work across multiple tenants, isolate Azure CLI profiles with `AZURE_CONFIG_DIR`:

```bash
AZURE_CONFIG_DIR="$HOME/.azure-tenant-home" az login --tenant <home-tenant-id> --allow-no-subscriptions
AZURE_CONFIG_DIR="$HOME/.azure-tenant-customer" az login --tenant <customer-tenant-id> --allow-no-subscriptions
```

## Inventory prerequisites

`adme-entra-inventory.sh` has the smallest prerequisite surface.

### Required tenant access

For full inventory (`--scope all` or `--scope dffa-clients`), the signed-in Azure CLI context needs Microsoft Graph read access that covers:

- service principals
- `oauth2PermissionGrants`

Least-privilege access levels:

- Interactive Entra role: `Directory Readers`
- App permissions for equivalent app-only discovery: `Application.Read.All` and `Directory.Read.All`

> [!TIP]
> If delegated-grant visibility is unavailable, start with `--scope adme-1p-service-principals`. That narrower mode still confirms the dffa/bd0c service-principal state and is the recommended fallback while you resolve broader Graph read access.

### Inventory output

By default, the inventory script writes artifacts to `./inventory-output/`:

- `dffa-sp-<timestamp>.json`
- `bd0c-sp-<timestamp>.json`
- `inventory-summary-<timestamp>.json`
- `3p-inventory-<timestamp>.json`

If you supply `--label`, the label is inserted before the timestamp, for example `inventory-summary-baseline-<timestamp>.json`.

## Migration and verify prerequisites

These prerequisites apply only while you run the mutating migration workflow.

### Required Entra roles

The operator should have one of the following roles in the target tenant when running steps that modify applications or service principals:

- Application Administrator
- Cloud Application Administrator
- Global Administrator

### Optional enhanced delegated verification

If `python3` with the `msal` package is available, `verify` can run the extra delegated-token forced-refresh proof.

Install the package:

```bash
python3 -m pip install --user msal
```

> [!NOTE]
> If `python3` with `msal` is not available, `verify` still runs. It warns and skips only the enhanced delegated forced-refresh proof; the Graph-based delegated-grant verification still runs.

### Verify behavior summary

`verify` can perform two token-path checks:

1. **App-only proof**: uses an isolated `AZURE_CONFIG_DIR`, signs in with `az login --service-principal`, and then acquires a token with `az account get-access-token --resource`.
2. **Delegated forced-refresh proof**: runs only when `python3` and `msal` are available.

> [!IMPORTANT]
> The isolated service-principal login used for the app-only proof does not reuse or overwrite the operator's normal Azure CLI profile.

## Next step

After the environment is ready, continue with [how-to-enable-entra-id-groups-authorization.md](how-to-enable-entra-id-groups-authorization.md).
