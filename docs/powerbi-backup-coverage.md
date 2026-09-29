# Power BI backup coverage: why items go missing

Reference for the recurring class of case "items exist in Power BI but are absent from the
backup". It exists because a connector job log cannot, on its own, distinguish three very
different situations, and the difference decides whether anything can be done.

Recipes: [`powerbi/backup-coverage-matrix`](../recipes/powerbi/backup-coverage-matrix.ps1),
[`powerbi/report-rest-export`](../recipes/powerbi/report-rest-export.ps1),
[`powerbi/dataflow-gen2-visibility`](../recipes/powerbi/dataflow-gen2-visibility.ps1).

## The three classes

| Class | What happens | Visible in a job log? | Fixable by the vendor? |
|---|---|---|---|
| **A — Microsoft refuses the export** | The item is discovered, the API call is made, Microsoft returns an error code | Yes, as a per-item failure with an exact code | No. The refusal is documented product behaviour. Only a different retrieval path would help |
| **B — the item type is invisible** | The item never appears in the API surface used for discovery, so it is never requested | **No.** Nothing is attempted, so nothing can fail | Yes — it is a coverage gap, closed by calling a different API |
| **C — no definition exists to fetch** | The item is discovered and requested, but there is no PBIX behind it | Yes, as a 404 | Partly — the item's definition exists in another format |

Class B is what makes these cases confusing: the customer sees missing data, the log is clean,
and everyone talks past each other. **A clean log is not evidence that everything was collected.**

## Class A — documented export refusals

The PBIX download endpoint is `GET /v1.0/myorg/groups/{workspaceId}/reports/{reportId}/Export`.

The crucial point for customer conversations: **the Power BI UI offers three download modes**
("copy of report and data", "live connection", "empty report with semantic model only"), but the
REST endpoint has no mode parameter — it only ever attempts the full copy. So a report the
customer successfully downloads in the browser can still be un-exportable through the API. That
is not a defect; Microsoft documents it per case.

| Error code | Cause | Downloadable in the UI? |
|---|---|---|
| `ModelWithIncrementalRefreshIsNotDownloadable` | Semantic model has incremental refresh configured | Yes, **live-connect mode only** (no data) |
| `ExportData_DisabledForModelWithDirectLakeMode` | Semantic model is Direct Lake | Yes, **live-connect mode only** (no data) |
| `ServerError_PremiumFilesErrors_OperationIsNotSupportedForPremiumFilesModel` | Semantic model uses large semantic model storage format (`targetStorageMode: PremiumFiles`) | **Yes, fully** — Microsoft documents this as a REST-only restriction |
| `ModelExportActionDenied` | Template app or usage metrics content, or export disabled by tenant setting | No — template app reports can never be downloaded |

Sources:

- [Download a report from the Power BI service — Limitations](https://learn.microsoft.com/power-bi/create-reports/service-export-to-pbix#limitations)
  — the mode table ("Reports based on Direct Lake semantic models → copy of report and data: No,
  live connection: Yes"), plus "Semantic models with incremental refresh can't be downloaded to a
  .pbix file", "You can't download Direct Lake semantic models", "Template App reports can't be
  downloaded", "Usage metrics report can't be downloaded", and — the important one —
  **"Reports that are based on a semantic model enabled for large semantic model storage format
  can't be downloaded using REST APIs. Use the Power BI service to download these reports."**
- [Large semantic models in Power BI Premium](https://learn.microsoft.com/fabric/enterprise/powerbi/service-premium-large-models#set-default-storage-format)
  — confirms `PremiumFiles` is the storage mode name for that format, so `targetStorageMode` on
  the semantic model predicts the refusal before the export is attempted.

`PremiumFiles` is the one worth flagging early in a case: it is the only code in the table where
the customer is completely right that the report downloads fine from the portal, and where the
asymmetry is purely an API restriction.

Note the log-visible short code may be a suffix of what the API returns. A live lab run returned
`ServerError_PremiumFilesErrors_OperationIsNotSupportedForPremiumFilesModel`; a connector log
showing `OperationIsNotSupportedForPremiumFilesModel` is the same thing.

## Class B — item types invisible to the Power BI surface

A Power BI connector typically discovers content through the Power BI REST API plus the admin
metadata scanner. Neither surface can see Fabric-native item types.

The [`GetScanResult` response schema](https://learn.microsoft.com/rest/api/power-bi/admin/workspace-info-get-scan-result)
defines a workspace as carrying exactly five collections: `reports`, `dashboards`, `datasets`,
`dataflows`, `datamarts`. There is **no collection for generic Fabric items**. Its
`WorkspaceInfoDataflow` object is Gen1-shaped — `objectId` plus `modelUrl`, "a URL to the dataflow
definition file (model.json)".

Dataflow Gen2 (CI/CD) is not that. It is a Fabric item of `type: "Dataflow"` whose definition is
[`mashup.pq` + `queryMetadata.json`](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/dataflow-definition),
retrieved with `POST /v1/workspaces/{ws}/items/{id}/getDefinition`. Microsoft states the parity
gap directly: ["Dataflow Gen2 uses the Fabric REST API, which doesn't have full parity with the
Power BI REST API. If applications trigger or manage your Gen1 dataflow through the Power BI REST
API, review those calls and update them to the corresponding Fabric REST API
endpoints."](https://learn.microsoft.com/fabric/data-factory/migrate-to-dataflow-gen2-using-upgrade-wizard#known-limitations)

So a Gen2 (CI/CD) dataflow is absent from `GET /v1.0/myorg/groups/{ws}/dataflows` and absent from
the scanner result. Nothing requests it, nothing fails, and it is silently missing.

Two constraints on closing this gap, both from
[Public APIs capabilities for Dataflow Gen2](https://learn.microsoft.com/fabric/data-factory/dataflow-gen2-public-apis#get-started-with-public-apis-for-dataflows):

1. **Service principal authentication isn't supported** for the Dataflow Gen2 APIs.
2. `Get Item` and `List Item Access Details` "don't return the correct information if you filter
   on dataflow item type" — so enumeration has to list all items and filter client-side.

The same invisibility applies to Lakehouse, Warehouse, Notebook, SQLEndpoint and every other
Fabric-native type.

An upgrade wizard converts Gen1 → Gen2 (CI/CD) and *keeps the same name*, changing only the item
type. A customer who upgrades sees no visible change in the workspace, while the item silently
leaves the backup's field of view. Worth checking whenever dataflows "disappear".

## Class C — reports with no PBIX behind them

`GET .../Export` returning HTTP 404 `ExportPBIX_ModelessWorkbookNotFound` means the report has no
workbook to export — typically authored in the service or created through the Fabric items API,
where the definition is PBIR rather than PBIX. The scanner exposes this as the report's `format`
field ([`PBIR`, `PBIRLegacy`, or `RDL`](https://learn.microsoft.com/rest/api/power-bi/admin/workspace-info-get-scan-result)).

Paginated reports are the related case: `reportType: "PaginatedReport"`, definition format `RDL`.
The PBIX Export endpoint does not apply to them at all, so depending on how a connector filters,
they either 404 or are skipped before any call is made — the second variant produces no log entry.

## Verified in the lab

`.\lab.ps1 INSPECT powerbi/backup-coverage-matrix -Target powerbi-largesem` and `-Target powerbi-fabric`,
against the lab's own tenant:

- Two reports over `targetStorageMode: PremiumFiles` → HTTP 400
  `ServerError_PremiumFilesErrors_OperationIsNotSupportedForPremiumFilesModel`. Same reports
  download normally from the portal.
- Two reports over ordinary `Abf` storage → exported fine (≈300 KB PBIX each). The control that
  makes the above meaningful: the identity, workspace and code path are identical.
- Reports created through the Fabric items API → HTTP 404 `ExportPBIX_ModelessWorkbookNotFound`.
- Three Dataflow Gen2 (CI/CD) items present in `GET /v1/workspaces/{ws}/items` were **absent** from
  `GET /v1.0/myorg/groups/{ws}/dataflows`, while two Gen1 dataflows in the same workspace appeared
  in it. Nothing about the Gen2 items produced an error anywhere.
- Lakehouse, Warehouse, Notebook and SQLEndpoint items: invisible to every Power BI surface.

## Triage order for a new case

1. Get the customer's list of expected-but-missing items with their **item types**, not just names.
2. Run the coverage matrix against the affected workspace. It answers "refused / invisible / no
   definition" per item in one pass.
3. Reconcile counts before theorising. If a connector reports *N* items skipped as
   not-exportable but logs fewer than *N* failures, the difference was dropped without an error —
   that is an observability defect and is worth raising separately from the coverage question.
4. For each Class A item, check `targetStorageMode` and the semantic model's refresh
   configuration. Those predict the refusal without needing to attempt the export.
5. Only escalate as a product gap what is genuinely Class B.
