# Direct import investigation: live checks, 2026-10-09

The signed `freeform-read-board-id.shortcut` fixture targets `com.apple.freeform` / `CRLUtilitiesIntent`, `operation=boardID`, `arguments=[]`. Shortcuts displayed its import preview, then rejected Add Shortcut with:

> Can’t Import Shortcut. This shortcut can’t be imported because it contains features not supported on this device.

The public `freeform-create-control.shortcut` fixture used the same workflow packaging and AppIntent descriptor structure, with `CRLCreateBoardIntent` and no required parameters. It imported successfully: All Shortcuts increased from 947 to 948 and the `freeform-create-control` tile appeared. It was not run, so this test created no Freeform board. The control remains installed for inspection. The hidden fixture was not installed or executed.

This supports a real availability distinction between these two actions on this installation, rather than a general malformed/signing failure. It does not by itself identify every reason for hidden action rejection. Independent binary tracing proves that the hidden utility’s import/export branches are unimplemented anyway. With empty arguments, its implementation would reject the missing arguments before dispatch if reached.

The signed Text format control was created but did not need importing after the public AppIntent control succeeded.

No original Freeform executable, feature flags, account settings, board data, or system security settings were changed. Shortcuts UI navigation was used; no clipboard-based Freeform insertion occurred during this investigation.

## Add Item intent import test

Two signed fixtures targeting `com.apple.freeform` / `CRLAddItemToBoardIntent` were tested through Shortcuts File > Import on this same installation:

- `freeform-add-item-probe.shortcut`: Create Board titled `Add Item Intent Test — 2026-10-09`, followed by Add Item with the created board as its target, `itemType=roundedRectangle`, text `Created without the clipboard`, and `mediaItems=[]`. The readable source is `freeform-add-item-probe.plist`.
- `freeform-add-item-minimal.shortcut`: only the Add Item action descriptor and UUID, with all action parameters omitted. This separates rejection of the action from rejection caused specifically by the supplied board/output token, item type, or text values.

Both reached the import preview, then **Add Shortcut** produced the same unsupported-features alert quoted above. Neither fixture was installed or run; no test board or object was created. The public Create Board control had imported successfully with the same descriptor structure. The visible Freeform action catalog still lists only Create Board, Delete Boards, Open Board, Rename Board, and Add Files to Board.

Conclusion: the generated Add Item intent route is blocked at Shortcuts import on this Mac. Metadata declaration (`isDiscoverable=true`) does not establish live availability. These checks do not identify the precise registration/platform/capability condition responsible, or prove that every possible invocation route is unavailable. Add Files to Board remains a separate available action; whether it can import editable native shapes without the general clipboard is still untested.
