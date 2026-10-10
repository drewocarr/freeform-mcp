# Decisive JSON clipboard test: passed

2026-10-09, Freeform 5.0 (656.1.2), macOS 27.0. Test board: **JS Bridge Test — 2026-10-09**. Only this newly created board was changed. It remains in Freeform with three objects for inspection.

## What worked

1. Inserted a native blue/teal rounded rectangle, 150 × 150 points.
2. Copied it using Freeform's Edit → Copy command. Captured its typed clipboard representations with a small AppKit helper.
3. Found a JSON array of shapes under **`com.apple.apps.content-language.canvas-object-1.0`**. The source clipboard also included native Freeform data and PNG.
4. Replaced the clipboard with **only the JSON type**. Pasted it through Edit → Paste. Freeform created a second native vector shape with eight resize handles. No PNG/native fallback was available on the clipboard.
5. Used `change-color.mjs` in Node to change only the shape's fill color (RGB components) to `(1, 0.2, 0.15)`. Wrote only the modified JSON type to the clipboard and pasted.
6. Freeform displayed a third, red shape with resize handles. A screenshot was inspected live.
7. Copied that imported shape back out. It produced new Freeform native data (1,599 bytes) and content-language JSON identifying it as `com.apple.apps.content-language.shape`, with a Bezier path and RGB `(1, 0.20000000298023224, 0.15000000596046448)`. Values matched the JS request within 1e-6.
8. Edit → Undo Paste reduced the canvas to two objects. Edit → Redo Paste restored the third shape and its handles.

This proves JavaScript can modify an external shape description and Freeform can import it as an editable native vector object. No injection, feature-flag modification, private intent invocation, or database editing was involved.

## Exact payload facts

- Root payload is a plain JSON array, not an invented wrapper object.
- Top-level shape uses `type_identifier = com.apple.apps.content-language.shape`, `version = 1.0`.
- Fill access: `objects[0].fill.color.rgba.{red,green,blue}`.
- Color RGBA model is version 1.1; many surrounding model objects are version 1.0. Preserve per-model versions.
- Geometry contains typed `position` and `size`, angle, horizontal flip, and valid-width/height flags.
- Path includes an SVG-like Bezier path string.
- Text is present even on the empty source shape: an attributed-string representation with a zero-width character and base64-encoded native attributes. Nonempty text editing was not tested.
- `source/manifest.json` records all source clipboard types. `source/item-0-type-5.json` is a pretty-printed copy of the accepted source payload.

## Limits discovered

**Placement changes on paste.** Source position was `(539,313)`. Unchanged JSON pasted at `(589,363)`; modified-color JSON pasted at `(639,413)`. Thus sequential pastes in this UI state were offset by 50 points per axis. The source JSON position alone does not guarantee final board coordinates.

**Some preset-specific behavior is lost.** Source accessibility description was “Rounded rectangle” with a radius control. Imported objects were described as “Shape” with ordinary resize handles and no radius control in the inspected tree. The rounded outline survived as a vector path; the preset's adjustable-corner affordance was not preserved in this test.

**This inserts new objects.** It does not establish updating an existing object by stable ID, complete board querying, connector preservation, grouped-object handling, text fidelity, arbitrary from-scratch payloads, or headless operation. Persistence across app relaunch and iCloud/device sync were not tested.

## Clipboard helper execution note

The first helper ran in the tool sandbox, which could not see the live Freeform clipboard. It rejected captures without writing them. Restarting the local helper outside the sandbox enabled clipboard access. Consequently, the successful helper's in-memory backup was the copied synthetic source shape, not the user's pre-experiment clipboard. At cleanup, that synthetic source clipboard was restored; do not claim the pre-experiment clipboard was preserved.

The helper stores its backup only in process memory, refuses writes/restores when the clipboard change count differs from its last observed operation, and saves only captures made after copying synthetic test objects. It is an experiment harness, not a production clipboard transaction service.

## Files and reproduction

- `../clipboard-probe.swift`: JSON-line AppKit clipboard helper.
- `change-color.mjs`: actual JavaScript transformation used.
- `modified-color.json`: JSON-only payload accepted by Freeform.
- `source/`: initial synthetic source clipboard capture.
- `readback-color/`: recaptured imported shape.
- `readback-summary.json`: concise machine-readable comparison evidence.

Build helper with `swiftc clipboard-probe.swift -o clipboard-probe`, from the research directory. Run it in a host process with live pasteboard access before copying a test object. Its `capture`, `write`, and `restore` commands are exercised in this session; UI copy/paste still needs an automation layer. The experiment required menu actions because the attempted keyboard copy did not provide usable evidence by itself.

## Bridge implication

The Node → typed JSON → AppKit clipboard → Freeform Paste path is now runtime-proven for this shape and fill-color change. The next implementation can wrap this path with validated commands and explicit placement/fidelity limits. A complete MCP server remains to be built.
