# Azure Data Manager for Energy - Samples

This repo contains samples for Azure Data Manager for Energy APIs.

# REST API Reference

* [CRS Catalog Service](/rest-apis/M23/crs_catalog_v3_openapi.yaml)
* [CRS Conversion Service](/rest-apis/M23/crs_converter_openapi.yaml)
* [Dataset Service](/rest-apis/M23/dataset_openapi.yaml)
* [Entitlements Service](/rest-apis/M23/entitlements_openapi.yaml)
* [File Service](/rest-apis/M23/file_service_openapi.yaml)
* [Indexer Service](/rest-apis/M23/indexer_openapi.yaml)
* [Legal Service](/rest-apis/M23/compliance_openapi.yaml)
* [Notification Service](/rest-apis/M23/notification_openapi.yaml)
* [Petrel DDMS Service](/rest-apis/M23/petrel_ddms_openapi.yaml)
* [Register Service](/rest-apis/M23/register_openapi.yaml)
* [Schema Service](/rest-apis/M23/schema_openapi.yaml)
* [Search Service](/rest-apis/M23/search_openapi.yaml)
* [Secret Service](/rest-apis/M23/secret_openapi.yaml)
* [Seismic DDMS Service](/rest-apis/M23/seismic_ddms_openapi.yaml)
* [Seismic File MetaData Service](/rest-apis/M23/seismic_file_metadata_openapi.yaml)
* [Storage Service](/rest-apis/M23/storage_openapi.yaml)
* [Unit Service](/rest-apis/M23/unit_openapi.yaml)
* [Wellbore DDMS Service](/rest-apis/M23/wellbore_ddms_openapi.yaml)
* [Well Delivery DDMS Service](/rest-apis/M23/welldelivery_ddms_openapi.yaml)
* [Workflow Service](/rest-apis/M23/ingestion_worflow_openapi.yaml)

**Note:** \
Partition service's swagger is not uploaded to this repo because it is an internal service. Users are not expected to call the partition service directly. Partition service is called by other services indirectly for reading partition info. It's also invoked when users interact with the partition management section of ADME Azure portal experience and the ADME partition management APIs.\
Access to paritition service will soon be revoked in the future, it is recommended by ADME team to not make direct API calls to the partition service.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft
trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
