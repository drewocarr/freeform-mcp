# In-process Freeform experiment

Tested 2026-10-09, macOS 27.0 (26A428), Freeform 5.0 (656.1.2).

**Native MCP integration passed.** The server can now discover open boards and objects by persistent UUID without a preliminary shape edit, list geometry, and move an explicitly targeted object. The full stdio MCP test passed, including stale-geometry and nonexistent-object rejection. UUIDs and geometry survived a restart; the object was also rejected when requested on another board. See [MCP evidence](logs/native-mcp-proof.json), [restart evidence](logs/native-mcp-restart.json), and [cross-board check](logs/native-cross-board-guard.json).

**Earlier live native editing proof:** JavaScript moved an existing rectangle in the isolated Freeform copy through its native command system. The canvas updated, Undo and Redo restored the expected coordinates, and the change survived quitting and reopening the app. [Checked evidence](logs/live-edit-proof.json) · [Reproduction](LIVE-EDIT.md).

| Stage | X | Y | Size |
| --- | ---: | ---: | --- |
| Before JavaScript request | 306 | 249 | 150 × 150 |
| After native move | 426 | 249 | 150 × 150 |
| After Undo | 306 | 249 | 150 × 150 |
| After Redo | 426 | 249 | 150 × 150 |
| After restart, one-point nudge, then Undo | 426 | 249 | 150 × 150 |

The initial CloudKit startup blocker below was overcome with explicit offline stand-ins and storage redirection. The current prototype targets board/object UUIDs in a separate lab app. It does not edit boards in the installed Apple-signed app.

## Earlier loading and swizzling evidence

| Experiment | Observed result | What it establishes |
| --- | --- | --- |
| arm64 and arm64e control programs | Both exit 0 with injected constructor markers | Toolchain and host can execute both probe variants |
| Ad-hoc signed Freeform copy, early exit | Exit 0, 282 runtime records | Our arm64e code runs inside the actual Freeform executable |
| Freeform `CRLPasteboardController.delegate` on synthetic instance | Hook and original each called once, expected nil result, method restored, exit 0 | A real Freeform implementation can be wrapped and called in process |
| Normal startup with passthrough hooks | Hooks installed; SIGTRAP before either ran | Installing a hook alone does not prove invocation or board access |
| Offline crash analysis | Freeform calls `CKContainer initWithContainerID:options:`; top two frames are CloudKit | The first observed startup failure is CloudKit construction |

Loading evidence: [launch-results-v2.json](logs/launch-results-v2.json) and [runtime inventory](logs/freeform-adhoc-v2.jsonl). Startup evidence: [startup1-result.json](logs/startup1-result.json), [crash summary](logs/startup1-crash-summary.json), and [disassembly](logs/startup1-offline-disassembly.txt).

The [final getter self-test](logs/selftest3-result.json) dispatches through `objc_msgSend`, uses zeroed synthetic instance storage, and deliberately skips Freeform's initializer. Offline disassembly shows this getter only reads a weak reference. Runtime checks validate its signature, superclass, weak property, and ivar offset. This tests the actual Apple implementation, but does not represent an initialized controller or a live board.

The exact CloudKit assertion is unknown. Missing entitlements and intentionally denied cloud services are plausible causes. Changing the bundle identifier or redirecting an app-group directory alone would not address this observed constructor failure.

## Experiment boundaries

Only `lab/FreeformLab.app` was re-signed. It has a separate identifier, empty entitlements, and no registered URL/activity handlers. The installed Freeform executable was unchanged; its SHA-256 before and after is `0c8d842de7100e07063828415551d3a05ef6aaf9e282252d97bec5be5fc291de`.

The lab sandbox denies direct access to user files outside this experiment, writes outside its logs and isolated lab data, network access, and named cloud/account/keychain services. This is not a claim that every possible XPC broker is blocked. Only newly created scratch boards were opened by the lab copy. No global security settings were changed. Constructor exit occurs before app main, but dependency constructors and Objective-C `+load` can run earlier.

## What remains

Only boards with live command controllers are discoverable. Opening a saved board still happens through the lab UI; the MCP does not yet enumerate every stored board, create native objects, edit text/styles, or provide cloud collaboration. Native move support is tested on a rounded rectangle.

Requests now use individual files, session identity, expiry, matching response IDs, and serialized main-thread processing. Moves require current geometry and reject an open edit group. Two simultaneous read clients passed. UUIDs are persistent model identifiers; transport session IDs change on each launch.

The installed executable hash remains unchanged. Both discovery test processes exited cleanly. Builds passed for arm64 and arm64e; live tests ran on arm64e. All 19 JavaScript tests passed. No global MCP configuration was changed.

See [LIVE-EDIT.md](LIVE-EDIT.md), [MCP configuration](../bridge/mcp-config.native.example.json), and [native command prerequisites](movement-notes.md).
