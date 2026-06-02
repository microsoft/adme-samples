# Supplemental scripts

These scripts are retained for legacy and internal-validation scenarios. For the customer-facing workflow, start with the primary scripts in `../`:

- `adme-entra-inventory.sh`
- `adme-entra-migration.sh`
- `Invoke-AdmeMigration.ps1`

## Scripts

| File | Status | Purpose |
| --- | --- | --- |
| `find-sp.sh` | Legacy | Resolves the ADME resource service principal by app ID or identifier URI. |
| `view-1p-app-details.sh` | Legacy | Dumps 1P resource service principal details, exposed permissions, assignments, and owners. |
| `view-3p-app-registrations.sh` | Legacy | Lists customer app registrations that request permissions to the target resource app. |
| `refresh-1p-app-sp.sh` | Legacy | Applies or cleans up a temporary tag to refresh a customer service principal in place. |
| `set-client-env-from-inventory.sh` | Legacy helper | Selects a client app from inventory output and exports the related environment variables. It intentionally works from the current working directory so its default `inventory-output/` lookup stays local to where you run it. |
| `simulate-1p-apps.sh` | Internal validation | Creates and manages simulated 1P/3P app state for internal end-to-end validation. |
| `config-template.env` | Legacy helper | Local-only template for the older config-driven migration and verification flow. |
| `Delete-1PServicePrincipal.ps1` | Legacy | Deletes a customer service principal for the specified 1P app ID. |
| `Get-1PAppDetails.ps1` | Legacy | Shows the 1P resource application's permissions, assignments, and related details. |
| `Get-3PAppRegistrations.ps1` | Legacy | Enumerates customer app registrations that reference the target resource app. |
| `New-1PServicePrincipal.ps1` | Legacy | Creates the customer service principal for the specified 1P app if it does not already exist. |

## Notes

- `AdmeEntraHelper.psm1`, `get-token.py`, and `test.sh` stay in `../` because the primary workflow still resolves them at runtime from that directory.
- Keep any generated state, inventory, or local config files out of git. Do not commit populated `.env` files, client secrets, or token output.
