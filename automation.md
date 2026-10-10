> Update 2026-10-09: The hidden utility lead below has now been traced. Its import/export operations are unimplemented on this Mac build, and the hidden read-only fixture was rejected by Shortcuts while a public Create Board control imported. A separate QA file importer exists behind internal-OS and feature gates. See [static findings](direct-import-static.md) and [live checks](direct-import/runtime-results.md). Earlier unresolved assessments below are retained as investigation history.

# Freeform automation evidence

Inspected 2026-10-09: `/System/Applications/Freeform.app`, version 5.0 (656.1.2), minimum macOS 27.0. Read-only investigation; no boards created or changed.

## Conclusion

A Node/JavaScript MCP service can plausibly drive Freeform through installed Shortcuts workflows that invoke its App Intents. The installed app contains a substantial intent surface. This is metadata-level proof, not proof that every intent is exposed or executes on this machine. A direct JXA Freeform object model was not found.

## Supported automation entrypoints

- `Info.plist` declares `freeform` and `com.apple.apps.freeform-edit-in` URL schemes. Executable contains `freeform://board?id=`. This is a board navigation lead, not a general manipulation protocol.
- No `.sdef`/`.scriptSuite` was found, Info.plist has no scripting declarations, and `sdef /System/Applications/Freeform.app` fails with error -10827. This strongly argues against a useful native AppleScript/JXA document object model, though does not prove all generic Apple Events fail.
- Share extension declares `com.apple.share-services`, accepts URLs, active webpages, files, images, text/RTF, movies, and MapKit items. This is an import UI path, not a direct headless API.
- App Intents metadata: `Contents/Resources/Metadata.appintents/extract.actionsdata` is JSON. Full formatted snapshot: `app-intents.json`.

## Exact intent inventory

| Intent | Parameters (? optional) | Discoverable | Opens app | Feature gate | Deprecated |
|---|---|---|---|---|---|
| CRLAddItemToBoardIntent | target, itemType?, text?, mediaItems, url? | True | False | Freeform/AppIntents | False |
| CRLAddStickyNoteToBoardIntent | board, string? | True | False | Freeform/AppIntents | True |
| CRLAddTextToBoardIntent | board, string? | True | False | Freeform/AppIntents | True |
| CRLChangeBoardCanvasGridIntent | entity, operation | True | False | Freeform/AppIntents | False |
| CRLChangeBoardObjectConnectorsIntent | entity, operation | True | False | Freeform/AppIntents | False |
| CRLChangeSelectionColorIntent | board, color | False | True |  | False |
| CRLChangeSelectionFontSizeIntent | board, size | False | True |  | False |
| CRLChangeSelectionFontStyleIntent | board, style | False | True |  | False |
| CRLCreateBoardIntent | title? | True | False | Freeform/AppIntents | False |
| CRLDeleteBoardIntent | entities | True | False | Freeform/AppIntents | False |
| CRLFavoriteBoardIntent_v2 | entity, operation | True | False | Freeform/AppIntents | False |
| CRLInsertFilesToBoardIntent | board, files | True | False | Freeform/AppIntents | False |
| CRLInsertPhotosToBoardIntent | board, images | True | False | Freeform/AppIntents | False |
| CRLInsertShapeToBoardIntent | board, shapes, string? | True | False | Freeform/AppIntents | True |
| CRLInsertTextToBoardIntent | board, strings, container? | False | False | Freeform/AppIntents | True |
| CRLInsertURLToBoardIntent | board, url | True | False | Freeform/AppIntents | True |
| CRLiOSCreateBoardIntent |  | True | True |  | True |
| CRLiOSOpenBoardIntent | board | True | True |  | True |
| CRLOpenBoardIntent | target | True | True | Freeform/AppIntents | False |
| CRLRenameBoardIntent | entity, property | False | False | Freeform/AppIntents | True |
| CRLResizeSelectionFontIntent | board, behavior | False | True |  | True |
| CRLResizeSelectionFontIntent_v2 | board, operation | False | True |  | False |
| CRLUpdateBoardIntent | target, title? | True | False | Freeform/AppIntents | False |
| CRLUtilitiesIntent | arguments, operation | False | False |  | False |

## Useful contracts and limits

- `CRLAddItemToBoardIntent`: `target: CRLBoardEntity`, `itemType?: CRLCanvasItemType`, optional rich text `text`, `mediaItems` array defaults to empty and accepts public.item files, optional `url`. Returns CRLBoardEntity. Item types: circle, line, roundedRectangle, square, stickyNote, star, textBox, triangle, url, media.
- `CRLCreateBoardIntent`: optional title; returns CRLBoardEntity. `CRLUpdateBoardIntent`: target and optional title; returns CRLBoardEntity.
- Board entity fields: title, creationDate, lastModificationDate, isFavorite, isCanvasDotGridEnabled, isConnectorModeEnabled. Query `Freeform.CRLBoardQuery` exists. No canvas item entity/query or item geometry parameters exposed in the metadata inspected.
- Selection styling intents require an existing UI selection, open the app, and are assistant-only in visibility metadata. They do not provide arbitrary item selection by ID.
- Most current board/content actions require feature capability `{"domain":"FeatureFlag","key":"Freeform/AppIntents","value":true}`. Whether enabled on this machine needs the Shortcuts action picker/runtime check.

## Hidden utility intent: highest-value reverse engineering lead

`CRLUtilitiesIntent(arguments: [String], operation: CRLUtilitiesOperation) -> String` is not discoverable, has no requiredCapabilities, and has openAppWhenRun false. Default operation is boardID. Enum values and labels:

- `boardID`: Get Board ID
- `downloadStatus`: Get Board Download Status
- `importBoard`: Import a sideloaded board
- `exportBoard`: Export a board to a local .freeform file
- `shareBoard`: Share a board
- `acceptSharedBoard`: Accept a shared board invitation
- `stopSharingBoard`: Stop sharing a board
- `downloadBoard`: Download a board’s content
- `resetBoard`: Reset a board
- `manipulate`: Manipulate items on a board

The binary contains matching names and labels. The arguments grammar and runtime access constraints have not been established. Do not treat a hidden intent as a stable supported API. Especially avoid reset/share/delete operations during probing.

## CLI invocation proof

`shortcuts run --help` confirms:
```text
shortcuts run <shortcut-name-or-identifier> [--input-path <input-path> ...] [--output-path <output-path>] [--output-type <output-type>]
```

The CLI runs installed workflows, not arbitrary App Intent IDs. A JavaScript wrapper should invoke an explicitly installed workflow by stable identifier with child_process.execFile and private temporary input/output files. The workflow can parse JSON and route to Freeform actions, then emit structured results.

`shortcuts list` failed in the sandbox with “Couldn’t communicate with a helper application.” A read-only unsandboxed subprocess verification succeeded: exit 0, 947 workflows, zero names containing Freeform. Private names were not printed. Thus the host service CLI route exists, while this tool sandbox blocks the helper.

Recommended next verification: inspect visible Freeform actions in Shortcuts, create a read-only board-listing/get-details workflow if exposed, run it from the CLI, then test create/add operations against an expressly disposable board. This investigation did not install or execute a workflow.

## Live action-picker observation from coordinating agent

The coordinating agent inspected Shortcuts on this machine, searched Freeform, and observed exactly five visible actions (the results fit without scrolling): **Create Board, Delete Boards, Open Board, Rename Board, Add Files to Board**. An existing empty shortcut was opened, with no actions added or run. This is a stronger runtime availability boundary than the 24 shipped metadata records. Feature flags are a plausible explanation for the narrower surface, but the precise cause is unproven.

Utilities implementation clues additionally present in the binary: `CRLUtilitiesIntentPerformer`, `CRLUtilitiesIntentPerforming`, `CRLBoardLibraryUtilitiesDependent`, `Operation to perform with the given arguments.`, `Warning: Operation did not return a result.`, and `Error: Operation `. No relevant named `nm` symbols were available. This proves compiled utility machinery exists, but its `manipulate` arguments grammar, possible internal-build gating, and external callability remain unresolved.
