# Native move prerequisites

Read-only binary inspection, Freeform 5.0 baseline arm64e slice, 2026-10-09. Parent owns all live experiments.

## Positioning method

Objective-C metadata resolves `-[CRLBoardItem crl_onBoard:moveItemToPosition:size:]` to VM **0x1000737cc**, main-image offset **0x737cc**. Encoding `v56@0:8@16{CGPoint=dd}24{CGSize=dd}40`.

For unchanged size the method:

1. Reads `visibleBoundsForPositioning`.
2. Returns without mutation if its origin already equals the requested origin.
3. Takes a `mutableCopy` of `geometry`.
4. Sets geometry.position to old geometry.position + (requested origin - visible bounds origin).
5. Assigns the new geometry via `setGeometry:`.

The requested position therefore means **visible bounds origin**, which need not equal geometry.position. The size-changing branch calculates scaling factors, accounts for rotation, and calls `p_onBoard:setPositionerCalculatedSize:`. Preserve the observed size for the first experiment to avoid this additional behavior.

No direct transaction creation or undo registration is present in the positioning method. Geometry assignment delegates to the concrete shape's implementation.

## Transaction context is mandatory

CRLShapeItem inherits CRLStyledItem → CRLBoardItemBase → CRLBoardItem. CRLBoardItem's own geometry setter is abstract and fatal (“Override this.”); only use the live concrete shape.

CRLBoardItemBase.setGeometry: is VM **0x100b92808**, invoking Swift helper **0x100b8b374**. The helper checks a weak transaction-context reference and fatally asserts if absent:

> Attempting to mutate a CRLTransactable without a CRLTransactableContext set

The assertion identifies `_guardTransaction()` in CRLTransactions/CRLTransactable.swift. A standalone asynchronous move after a drag finishes is therefore unsafe without first creating a valid transaction. Merely dispatching on the main queue or opening an NSUndoManager group does not establish this application-specific transaction context.

A narrowly scoped live proof can perform a single additional move synchronously while an observed native operation already has its transaction context. This would prove a native mutation within the user's operation, but would not establish independent MCP command creation. Verify whether subsequent drag events overwrite the adjusted position before claiming success.

## Candidate seams for independent commands

- CRLEditorController `p_beginTransaction` / `p_endTransaction`, associated `mTransactionLevel`. These may be editor-level batching; not yet proven to create the model's CRLTransactionContext.
- Command layer strings `_openTransactionIfNecessary(commandType:)`, `_closeTransaction(applyingSelectionBehavior:phase:commandType:progressivityForEnqueuingClosingGroup:)`, `_execute` and “Executing an action while a transaction context was already open.”
- `CRLTransactionContext`, `CRLWatermarkTransactionContext`, and `transactionContext` selectors exist. Raw construction or assigning them is not yet verified.

If manual dragging does not hit the positioning method, observe `CRLBoardItemBase.setGeometry:` instead; the positioning method is a canvas-positioner helper and does not establish that every drag uses it.

Evidence: [movement-disassembly.txt](logs/movement-disassembly.txt), [objc-metadata.txt](logs/objc-metadata.txt). The metadata output contains both architecture slices; VM addresses above refer to the baseline arm64e slice used in the lab.

## Independent command entry point established statically

`CRLEditorController.p_beginTransaction` at VM0x1004265e4 simply increments an integer at object offset0x40 and returns. It cannot establish the model transaction context. Its counterpart decrements and issues deferred editor notifications. Evidence: `logs/editor-transaction-disassembly.txt`.

Use the shipped **Freeform.CRLCommandSetInfoGeometry** (`_TtC8Freeform25CRLCommandSetInfoGeometry`) instead:

- `initWithBoardItem:geometry:` IMP0x100e45ba0, encoding `@32@0:8@16@24`.
- The boardItem argument is the actual live native item. Constructor calls its Swift UUID getter, bridges the UUID to NSUUID, then delegates to `initWithId:geometry:`.
- `initWithId:geometry:` IMP0x100e45af0. Its helper0x100e46380 sends `[geometry copy]`, dynamically casts the copy to **CRLCanvasInfoGeometry**, and stores it. Supply a modified mutableCopy of the live item's geometry, rather than an arbitrary geometry stand-in.
- `commit(with:transaction:undoable:)` implementation0x100e45d0c resolves `getBoardItemForUUID:` on the board, uses the transaction before calling the item's geometry setter, and clears its stored geometry afterward. Missing item or geometry triggers assertions. Treat the command as single-use.
- `CRLCommandController.enqueueCommand:` forwards to `enqueueCommand:withSelectionBehavior:nil`; its latter ObjC entry is0x1009fda78. This is the application's normal user-command path, including its transaction handling, rather than a direct setter outside a transaction.

Proposed independent experiment: obtain the controller for the same board as the captured live shape, make a mutable copy of current geometry, add a small offset to geometry.position, initialize a new CRLCommandSetInfoGeometry with the item and copy, then enqueue that command on the main thread after any current user command has finished. Verify native coordinates, screen movement, undo/redo, and persistence. No raw transaction-context writes are necessary.

Evidence: [geometry-command-disassembly.txt](logs/geometry-command-disassembly.txt). The synchronous completion and undo behavior still require the parent's live verification.
