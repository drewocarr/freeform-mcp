# Background Freeform editing investigation

**Continuing this work? Read [HANDOFF.md](HANDOFF.md) first.** It gives the last observed board state, exact resume commands, probe limitations, and next experiments with success criteria. This file is the evidence and results reference.

Tested 2026-10-09 on the regular Apple-signed Freeform 5.0 (656.1.2), macOS 27.0 (26A428). The production MCP bridge is unchanged. These are research probes against the disposable **Background Bridge Probe — 2026-10-09** board.

## Result

**Native insertion, label replacement, movement, and resizing work without activating Freeform.** Several paths also avoid the clipboard entirely. Accessibility toolbar actions created a native sticky note and text boxes. Unicode keyboard events posted directly to Freeform's PID supplied their text. Accessibility position setters moved individual selected objects. Another application remained frontmost, and the successful probes recorded no application-activation notifications.

This corrects the previous assumption that regular-app editing necessarily needs foreground focus. It does not establish a background replacement for every existing bridge operation.

| Operation | Observed result | Evidence |
| --- | --- | --- |
| Inspect background canvas/objects | Works; exposes position/size setters and object actions | `inspect.json` |
| Set AXPosition while two shapes selected | Both moved +20 screen points; setter affects selection | `position.json` |
| Select exactly one object, then PID-addressed right arrow | Only that object moved +1; Finder remained frontmost | `nudge.json` |
| Select exactly one, then set AXPosition | Only that object moved +20; Finder remained frontmost | `position-selected.json` |
| Set AXSize | Returned AX success but dimensions did not change | `resize-selected.json` |
| Build multi-selection with AXSelectedChildren | Returned success but selected only the last object | `align-ax.json` |
| Set AXSelected individually | Selecting the next item deselected the previous one | `select-each.json` |
| AX Paste | Menu item reported disabled; AXPress returned success without insertion | `paste-ax.json` |
| PID-addressed Cmd+V, with and without explicit Unicode v | No new object; Finder remained frontmost; clipboard restored | `paste-pid.json`, `paste-unicode.json` |
| PID-addressed Cmd+C | No copied object; run also interrupted by Ghostty becoming frontmost, so focus result is inconclusive | `copy-pid.json` |
| AX alignment menu | Disabled in this background state; no alignment sent | `align-ax.json` |
| Insert Sticky Note toolbar AXPress | Added one native sticky note; Finder remained frontmost | `insert-sticky-ax.json` |
| Type into selected sticky using PID-addressed Unicode key event | Exact label appeared; Finder remained frontmost; no clipboard transaction | `type-sticky-pid.json` |
| Complete text-box creation and typing | Added exactly one text box and verified its label; Safari remained frontmost for all steps | `create-text-complete.json` |
| Lay out two rectangles, sticky note, and two text boxes | All five positions verified; Ghostty stayed frontmost throughout; no clipboard | `layout.json`, `final-screenshot-proof.json`, `final-screenshot.png` |
| ScreenCaptureKit window capture | Captured only Freeform's window while Safari stayed frontmost; no clipboard | `screenshot-proof.json`, `screenshot.png` |

The first standalone text-box insertion coincided with Safari replacing Finder as frontmost (`insert-text-ax.json`). Freeform did not activate, but that run cannot prove the frontmost app was preserved. The later complete creation/typing test removed that ambiguity. Likewise, the Copy probe's `FOCUS_STOLEN` label is an early generic diagnostic, not proof that Freeform caused Ghostty to activate. Later probe code calls this `FOCUS_CHANGED_DURING_PROBE`.

The initial probe stalled because an unqualified `pause()` resolved to Darwin's signal-wait function instead of the intended Swift default-argument helper. It was stopped before edits and renamed. A first standalone background screenshot aborted in CoreGraphics initialization; initializing NSApplication with activation policy `.prohibited` fixed it. The final capture succeeded without activation.

## What the working path does

1. Locate the already open, exact-title board through its Accessibility tree.
2. Keep the current non-Freeform app frontmost. Early probes deliberately selected Finder as a controlled foreground app; later probes preserve whichever app is already frontmost.
3. Invoke the observed `Insert Sticky Note` or `Insert Text Box` toolbar button directly with AXPress.
4. Check the added object/selection before typing. Post a Unicode keyboard event with `CGEvent.postToPid(freeformPID)`; finish with a PID-addressed Escape.
5. For movement, select exactly one object and set its AXPosition. Verify the result, not just the AX return code.
6. Check before/after foreground identity and observe application activations throughout each operation.

These operations use the regular app's actual objects. There is no injection, re-signing, database editing, XPC connection, or clipboard publication on the successful creation/typing/movement paths. Geometry evidence is Accessibility screen geometry at the tested 100% zoom, not clipboard model coordinates. Cross-device delivery, restart persistence, Undo behavior, other zoom levels, minimized/offscreen windows, and concurrent user input have not been verified here.

Apple documents [process-targeted events](https://developer.apple.com/documentation/coregraphics/cgevent) and [window-filtered screenshots](https://developer.apple.com/documentation/screencapturekit/sccontentfilter). Their existence alone does not guarantee that any particular Freeform command handles them; the matrix above records the observed behavior.

## XPC investigation

No callable board-editing XPC service was identified in this bounded inspection. This is not a proof that none exists.

- No bundled `Contents/XPCServices` service was found. The app bundles a share extension and a USD renderer extension.
- The USD renderer extension declares `com.apple.freeform.USD-renderer-remote-UI`.
- The main executable's observed XPC protocols cover renderer creation, scene updates, snapshots, surface models, and model compression. `xpc-protocols.json` contains decoded selectors. `performActions:response:` belongs to `_CRLUSDAsyncRenderingXPC`; it is not evidence of a board-edit command channel.
- No `NSXPCListener`, named-service initializer, exported-object setter, or listener-endpoint selector was found in the inspected main-executable string inventory. Framework-managed connections remain possible.
- The app's entitlement list includes named services it may look up. Those outgoing permissions do not establish an exported Freeform editing service.
- Earlier Add Item App Intent attempts were rejected by Shortcuts import; the hidden utility's manipulate operation is explicitly unimplemented on macOS. See `../direct-import/runtime-results.md` and `../direct-import-static.md`.

`inspect-xpc.py` decodes the relevant selector references from the locally generated, unmodified arm64e executable slice. Its addresses are specific to this app build. It does not contact a service.

## Reproduction and next implementation

`prepare.mjs` creates the disposable board and two control shapes using the existing foreground bridge. It is setup, not a background creation proof. Do not repeat setup or a failed mutation blindly. The remaining probes require that exact disposable board already open and verify the title.

```sh
node background/build-probe.mjs
background/.build/probe inspect
background/.build/probe positionSelected
background/.build/probe screenshot /tmp/freeform-background.png
```

The individual modes and expected selection are explicit in `probe-body.swift`. Probe `ok` means the probe completed, not that an attempted edit succeeded: consult before/after state and the results table. `createTextAndType` has explicit object-count, identity, selection, and exact-label assertions. Each mutation probe is opt-in, can change the disposable board, and may leave partial edits if interrupted. They are not concurrent-client-safe production tools.

Recommended next step: add a separate, fail-closed background backend for screenshot, object listing, single-object movement, sticky-note creation, and text-box creation. Reuse the production lock and stale-target checks; preserve foreground identity; never silently fall back to foreground interaction. Report unsupported operations explicitly. Round 2 below advances native clipboard insertion, shape-library insertion, label replacement, and resizing. Multi-selection/grouping and full diagram recreation still require further tests. Do not switch the existing MCP tools to background mode based solely on these prototypes.


## Round 2: context menus, shape controls, and existing labels

All mutations remained on the disposable board. The production MCP code is unchanged.

| Operation | Observed result | Evidence |
| --- | --- | --- |
| Resize using the middle-right AXHandle position | Rectangle width increased exactly 40 points, height unchanged; Ghostty stayed frontmost | `resize-handle.json` |
| Insert Shape toolbar and Circle picker button | Added one native 150 x 150 circle without activation | `shape-picker.json`, `insert-circle.json` |
| Set a shape's child AXTextArea value | Reported success but did not change text | `child-text.json` |
| Return followed by setting editor AXValue | Cleared the old label but did not insert replacement; unsuitable route | `edit-existing.json` |
| Select shape and send replacement Unicode text directly to PID | Replaced Background B with exact label Background B edited without clipboard; Safari stayed frontmost | `replace-existing-label.json` |
| Restore first rectangle label with PID Unicode | Exact Background A restored; Ghostty stayed frontmost | `restore-label.json` |
| Context-menu Copy | Produced native shape JSON while Safari remained frontmost; clipboard restored on this run | `context-copy-refined.json` |
| Context-menu Paste of generated native object JSON | Added exactly one Background paste oval, 140 x 70, while Ghostty stayed frontmost; clipboard restored | `context-paste-retry.json` |
| Context-menu Copy of imported oval | Read back exact text and 140 x 70 native geometry; no activation; clipboard restoration declined because change count changed later | `context-copy-imported.json` |
| Window capture after these changes | Captured seven objects without activation | `round2-screenshot-proof.json`, `round2-screenshot.png` |

The important distinction is **the object's context menu versus the application's main Edit menu**. The context menu exposed enabled Copy and Paste actions in the background. AXPress dispatched those actions successfully. This demonstrates one-object native import and readback, not yet reliable multi-object diagram import.

Showing a context menu sometimes returns AX error -25204 (cannot complete), although the menu actually opens. The focused window can also temporarily refer to the menu rather than the board. The research probe therefore validates the original board window's title while dispatching a command in the menu it just found. A production version needs stronger window/selection identity checks, bounded menu dismissal, and final board validation. It must not retry mutations solely because AX returned an error.

The initial Copy probe stopped at its focused-window guard before Copy (`context-copy.json`). The first Paste probe stopped before Paste because the foreground changed from Safari to Ghostty (`context-paste.json`); it recorded no Freeform activation and no new object. Only then was that step repeated. The successful retry recorded no activation events.

Clipboard-free native creation and text editing avoid clipboard sharing. Context-menu import/readback still uses the system clipboard temporarily. Our payload writes use currentHostOnly. That does not prove that Freeform's own Copy publication is excluded from Universal Clipboard. One readback observed a later clipboard change and correctly refused to overwrite it; the cause is unproven. The probe was subsequently given the production bridge's stability-wait pattern and change-count diagnostics, but this is still research, not a concurrency guarantee. The stabilized repeat (`context-copy-stable.json`) did not obtain a stable one-object JSON payload within 15 seconds and declined restoration: expected change count 1202, observed 1204. Safari stayed frontmost with no activation events. The cause of those clipboard changes is not established; Copy/readback is demonstrably not reliable yet.

### Remaining avenues, in priority order

1. **Expand the successful background import path:** multi-object payloads, an initially empty canvas, paste positioning, connector relationships, grouped payloads, and duplicate prevention after timeouts. Test readback and restore behavior repeatedly with clipboard utilities present.
2. **Finish clipboard-free editing:** more shape-picker entries, both resize axes and non-100-percent zoom, style popovers, and Connection Line endpoints. The picker exposes Connection Line, but attachment to existing objects is not verified.
3. **Multi-selection and arrangement:** process-targeted modified mouse events or other observed Accessibility controls. AXSelectedChildren arrays only selected the last object in earlier tests. Group/ungroup and native align commands remain unverified in the background. Moving objects individually can implement geometric alignment, but does not establish grouping.
4. **Background board lifecycle:** create, open, and switch boards without activation; minimized/offscreen windows; dialogs; Undo; restart persistence and phone/iPad sync for these specific background edits. Current probes require an already-open board and a running GUI session.
5. **Direct import/XPC:** continue only with a concrete callable endpoint. The inspected renderer protocols are not board-editing services. Context-menu import is currently the stronger empirical lead.

The next production change should be an explicit background mode with no silent foreground fallback, serialized operations, exact board and selection guards, and verified outcomes. These probes do not yet supply that mode.
