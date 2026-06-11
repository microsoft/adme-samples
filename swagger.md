# Access Swagger in your ADME instance

[⬅ Back to ADME Samples home](./)

> **⚠️ Deprecation Notice:** The static REST API references on this site are a point-in-time snapshot and are no longer updated after the **M26** OSDU Milestone release. For the latest, always-current API definitions — and to try endpoints with authentication — use the Swagger pages served directly from your own Azure Data Manager for Energy (ADME) instance.

## How to use

Each ADME (OSDU) service publishes its own Swagger / OpenAPI page. Take your instance base URL (for example `https://<your-instance>.energy.azure.com`) and append the suffix for the service you want. Swagger pages require sign-in — open the page, then authorize with a bearer token for your data partition to try requests.

For example, the Storage service Swagger page is:

```
https://<your-instance>.energy.azure.com/api/storage/v2/swagger-ui/index.html
```

## Service Swagger URL suffixes

* **CRS Catalog** — `/api/crs/catalog/swagger-ui/index.html`
* **CRS Conversion** — `/api/crs/converter/swagger-ui/index.html`
* **Dataset** — `/api/dataset/v1/swagger-ui/index.html`
* **EDS** — `/api/eds/v1/swagger-ui/index.html`
* **Entitlements** — `/api/entitlements/v2/swagger-ui/index.html`
* **File** — `/api/file/v2/swagger-ui/index.html`
* **Indexer** — `/api/indexer/v2/swagger-ui/index.html`
* **Legal** — `/api/legal/v1/swagger-ui/index.html`
* **Notification** — `/api/notification/v1/swagger-ui/index.html`
* **Register** — `/api/register/v1/swagger-ui/index.html`
* **Schema** — `/api/schema-service/v1/swagger-ui/index.html`
* **Search** — `/api/search/v2/swagger-ui/index.html`
* **Secret** — `/api/secret/swagger-ui/index.html`
* **Storage** — `/api/storage/v2/swagger-ui/index.html`
* **Unit** — `/api/unit/swagger-ui/index.html`
* **Workflow** — `/api/workflow/swagger-ui/index.html`
* **Petrel DDMS** — `/api/petreldms/docs/index.html`
* **Reservoir DDMS** — `/api/reservoir-ddms/v2`
* **Rock and Fluid Sample DDMS** — `/api/rafs-ddms/docs`
* **Seismic DDMS** — `/seistore-svc/api/v3/swagger-ui.html`
* **Seismic File Metadata** — `/seismic-file-metadata/api/swagger-ui.html`
* **Wellbore DDMS** — `/api/os-wellbore-ddms/docs`

**Note:** Most Java (Spring) services expose Swagger UI at `/swagger-ui/index.html` under the service base path; Python (FastAPI) DDMS services vary — some use `/docs` or `/swagger-ui.html`, and a few serve docs at the service base path itself. Paths are subject to change in future ADME releases — if a link returns a 404, check your instance's API documentation in the Azure portal.

[⬅ Back to ADME Samples home](./)
