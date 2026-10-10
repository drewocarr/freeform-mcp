# Background Freeform editing investigation

**Continuing this work? Read [HANDOFF.md](HANDOFF.md) first.** It gives the last observed board state, exact resume commands, probe limitations, and next experiments with success criteria. This file is the evidence and results reference.

Tested 2026-10-09 on the regular Apple-signed Freeform 5.0 (656.1.2), macOS 27.0 (26A428). The production MCP bridge is unchanged. These are research probes against the disposable **Background Bridge Probe — 2026-10-09** and **Background Empty Paste — 2026-10-09** boards.

> **Read this before the tables: "background" has three separate meanings.** (1) **No activation:** Freeform never becomes frontmost and the user keeps keyboard focus. (2) **Window stays hidden:** Freeform's window doesn't rise above the user's windows. (3) **No clipboard.** Rounds 1–4 measured only (1). Phrases such as "Finder remained frontmost" or "without activation" in those rounds mean exactly that, **not** that Freeform stayed out of sight. Round 5 sampled window order and found that **Accessibility context menus (object Copy/Paste, board-card menu) raise Freeform's window to the top** without activating it. Clipboard-free toolbar, typing and position paths have not been window-sampled yet. [HANDOFF.md](HANDOFF.md) has a per-capability status table across all three properties.

## Result (Rounds 1–2; activation only)

**Native insertion, label replacement, movement, and resizing work without activating Freeform** (property 1; window order not measured). Several paths also avoid the clipboard entirely. Accessibility toolbar actions created a native sticky note and text boxes. Unicode keyboard events posted directly to Freeform's PID supplied their text. Accessibility position setters moved individual selected objects. Another application remained frontmost, and the successful probes recorded no application-activation notifications.

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

**Cause identified (resume session, `context-copy-timeline.json`):** a timestamped clipboard timeline showed Freeform's context-menu Copy publishing a complete one-object native payload (8178 bytes, all Freeform types plus content-language JSON) 17 ms after AXPress. At 437 ms, Pure Paste replaced it with plain text plus its `com.sindresorhus.Pure-Paste.hasRun` marker, removing the native JSON. Pure Paste is configured with `automaticallyClearFormatting = 1` and `excludedApps = [com.microsoft.Excel, com.apple.freeform]`; its exclusion evidently keys on the frontmost app, so it does not protect a Copy made while Freeform is in the background. The 0.5 s stability wait therefore always lost the race. Safari stayed frontmost, no activation events occurred, and selection held throughout. Restoration was correctly declined (expected 1205, observed 1207), so the user's prior clipboard was not restored on this run. Freeform and Universal Clipboard are not implicated by this evidence.

**Confirmed after removing Pure Paste (`context-copy-no-purepaste.json`):** the user uninstalled Pure Paste. The same `contextCopy --last` run then published the native payload at 18 ms, it stayed stable with no further clipboard changes during the 3 s post-watch, and readback returned exact label `Background paste`, size 140 × 70, model position (594, 403). The clipboard was restored (expected and observed change count 1209). Ghostty stayed frontmost with no activation events. This is one successful run, not yet a repeatability result.

### Remaining avenues, as of Round 2 (superseded)

Rounds 3–5 below completed multi-object and empty-canvas import, background board creation and rename. They also found the window-raising behavior. The current prioritized list is in [HANDOFF.md](HANDOFF.md#next-experiments).

1. **Expand the successful background import path:** multi-object payloads, an initially empty canvas, paste positioning, connector relationships, grouped payloads, and duplicate prevention after timeouts. Test readback and restore behavior repeatedly with clipboard utilities present.
2. **Finish clipboard-free editing:** more shape-picker entries, both resize axes and non-100-percent zoom, style popovers, and Connection Line endpoints. The picker exposes Connection Line, but attachment to existing objects is not verified.
3. **Multi-selection and arrangement:** process-targeted modified mouse events or other observed Accessibility controls. AXSelectedChildren arrays only selected the last object in earlier tests. Group/ungroup and native align commands remain unverified in the background. Moving objects individually can implement geometric alignment, but does not establish grouping.
4. **Background board lifecycle:** create, open, and switch boards without activation; minimized/offscreen windows; dialogs; Undo; restart persistence and phone/iPad sync for these specific background edits. Current probes require an already-open board and a running GUI session.
5. **Direct import/XPC:** continue only with a concrete callable endpoint. The inspected renderer protocols are not board-editing services. Context-menu import is currently the stronger empirical lead.

The next production change should be an explicit background mode with no silent foreground fallback, serialized operations, exact board and selection guards, and verified outcomes. These probes do not yet supply that mode.


## Round 3: Copy reliability and multi-object import

Pure Paste was uninstalled by the user after `context-copy-timeline.json` showed it rewriting background Copy (see above). All runs below kept the non-Freeform app frontmost with no activation events.

| Operation | Observed result | Evidence |
| --- | --- | --- |
| Context-menu Copy readback, repeated | 4 of 4 runs that reached Copy succeeded, plus the confirmation run: exactly two clipboard changes (placeholder, Freeform), exact label, clipboard restored. One run stopped at the initial `FOCUS_CHANGED` guard before any menu or Copy because Finder became frontmost for an unattributed reason; clipboard restored | `context-copy-no-purepaste.json`, `context-copy-repeats.json` |
| Context-menu Paste of two generated objects | Exactly two added; exact labels and sizes; one common translation; seven existing objects unchanged; clipboard restored | `payload-two.json`, `context-paste-two.json` |
| Context-menu Paste of a four-object diagram (rounded rectangle, arrow, rectangle, ellipse) | Exactly four added with exact labels, sizes, and common translation; existing nine unchanged; clipboard restored | `payload-diagram.json`, `context-paste-diagram.json` |
| Window capture after Round 3 | Thirteen objects; fills and relative layout visually match the fixtures | `round3-screenshot-proof.json`, `round3-screenshot.png` |

`contextPaste` now reads expected labels, model positions, and sizes from the payload, requires uniquely labeled objects, and verifies count, per-label match, size, a common screen translation, and unchanged pre-existing frames. This is Accessibility verification at 100% zoom; it does not compare fills or paths (the window capture is the only fill evidence). Paste placement follows the right-clicked object, so pasted objects overlap existing ones; absolute placement is not controlled. The initial-count guard was deliberately raised from 8 to 16 objects for these tests; the board now has 13.

## Round 4: background board creation and empty-board import

| Operation | Observed result | Evidence |
| --- | --- | --- |
| `createBoard`: AXPress **New Board** from the probe board | Created an empty board, **Untitled 6**, with Ghostty frontmost and no activation | `create-board-bg.json` |
| Rename via toolbar title | Title is an AXStaticText with no actions (AXPress returned -25206); no text field appeared. Production's click fallback was deliberately omitted, so the probe stopped with `TITLE_EDITOR_NEEDS_FOREGROUND` | `create-board-bg.json`, `inspect-title.json` |
| Edit ▸ Rename | Present but disabled in the background, like the other main-menu commands | `inspect-title.json` |
| `emptyPaste` of the four-object diagram onto the empty board | Bootstrap circle inserted from the shape picker, context-menu Paste added exactly four objects (labels, sizes, common translation verified), then a PID-addressed Delete removed only the circle; four pasted objects intact; clipboard restored; frontmost app unchanged; no activation | `empty-paste.json`, `empty-paste-screenshot.png`, `empty-paste-screenshot-proof.json` |

The empty canvas exposes no context menu (`canvas` actions are empty in `inspect`), so a temporary native shape supplies one. Deleting the bootstrap is part of the board's undo history; Undo behavior was not tested. The probe now reads its board title from `FREEFORM_PROBE_BOARD` (default: the original probe board), and `emptyPaste` requires zero initial objects. Board naming in the background remains unsolved; candidate next route: the board card's context menu in the library view.

## Round 5: background rename, and window raising

**Correction to earlier rounds:** "background" in this document has meant *the frontmost (key) application did not change and Freeform did not activate*. It did **not** mean Freeform's window stayed hidden. The user observed Freeform's window on screen during these tests. A 100 ms window-order sampler (`zsample.swift`, CGWindowList index of Freeform among on-screen layer-0 windows, plus the frontmost app) showed:

| Operation | Freeform window order | Frontmost app | Evidence |
| --- | --- | --- | --- |
| Window screenshot | Stayed behind (index 8) | Ghostty throughout | `zorder-screenshot.txt` |
| contextCopy (object context menu via AXShowMenu) | **Rose to topmost (index 0) about 1.7 s in and stayed there** | Ghostty throughout; no activation | `zorder-context-copy.txt`, `context-copy-zorder.json` |
| renameBoard (card Show Menu → Rename) | Rose to topmost about 0.6 s in and stayed there | Ghostty throughout; no activation | `rename-zorder-2.txt`, `rename-board-bg-2.json` |
| Failed first rename (Go Back only; AXShowMenu rejected) | Stayed behind | Ghostty | `rename-zorder.txt`, `rename-board-bg.json` |

So every context-menu Copy/Paste run in Rounds 2–4 very likely raised Freeform's window over the user's work, without taking keyboard focus. Clipboard-free toolbar/typing/position operations have not yet been sampled. **Mitigation observed once:** AXRaise on the frontmost app's main window (Ghostty) put it back on top with no activation; Freeform dropped to index 1 (behind that window, ahead of the app's other windows). That leaves a brief visible flash per context-menu operation.

**Background rename works through the library:** Go Back (AXPress), then the board card's custom AX action `Show Menu` (the standard AXShowMenu returned -25200), revealing Open in New Tab, Open in New Window, Move to, Duplicate, Rename, Delete, Favorite, Share, New Folder. AXPress **Rename** produced a text field holding the old title; setting AXValue plus AXConfirm renamed the card, and AXPress on the card reopened the board. **Untitled 6** is now **Background Empty Paste — 2026-10-09**. Frontmost app unchanged, no activation. The menu search must exclude menu-bar menus (the first attempt matched the disabled Edit ▸ Rename).

**Device sync (user-confirmed):** the user's iPad showed **Background Empty Paste — 2026-10-09**, created, renamed and populated entirely through background probes, with exactly the four diagram objects, matching fills and relative layout, and no bootstrap circle (`ipad-sync-empty-paste.png`, 7:35 PM). This is the first iPad delivery confirmation in the project.

## Round 6: window order for clipboard-free operations

The same sampler ran around each probe, restoring the user's window on top first (Freeform started at index 15). Safari stayed frontmost, with no activation, in every run. All edits were verified.

| Operation | Edit verified | Freeform window | Evidence (`zorder-clipboard-free/`) |
| --- | --- | --- | --- |
| `openBoard` (library Go Back, card AXPress) | Switched to the original probe board | Stayed at 15 | `openBoard.*` |
| `replaceLabel 1` (select + PID Unicode) | Exact label | Stayed at 15 | `replaceLabel.*` |
| `positionSelected` (AXPosition) | Background A moved exactly +20 | Stayed at 15 | `positionSelected.*` |
| `resizeHandle` (AXPosition on handle) | Width +40, height unchanged | **Index 1 for ~0.3 s** (just below Safari's key window), then back to 15 | `resizeHandle.*` |
| `createTextAndType` (toolbar + PID Unicode) | One text box added, exact label | Stayed at 15 | `createTextAndType.*` |
| `chooseShape Circle` (picker popover) | One circle added | Stayed at 15 | `chooseShapeCircle.*` |

**Conclusion:** the clipboard-free paths keep Freeform both inactive and hidden. Context menus are what raise the window. A hidden diagram builder could rely on picker inserts, typing and moves; fills and sizing without handles are still open. The probe board now has 15 objects (adds a second "Second background text — verified" text box and a Circle), and Background A is 220 wide and shifted +20.

## Round 7: fills, sizing, and New Board without context menus

Window order was sampled around every run. The user's app stayed frontmost (Safari, or System Settings for two runs), with no activation. Evidence is in `round7/`.

| Operation | Result | Freeform window |
| --- | --- | --- |
| Selected object's custom action **Show format options** | Shows a format bar: Fill Inspector (value = current fill name, e.g. `teal`), Stroke Inspector, Text Inspector | Stayed hidden (`format-options.*`) |
| Fill Inspector AXPress | Popover with 12 named swatches (black, gray, white, cyan, magenta pink, dark indigo, red, orange, light amber, green, teal, blue), No Fill, Color Picker | Stayed hidden (`fill-inspector.*`) |
| Press swatch `red` | Fill Inspector value changed `teal` → `red`; object count unchanged | Stayed hidden (`fill-red.*`) |
| Press **Color Picker** | AX success but nothing happened: no Colors panel, no new popover controls, value unchanged (twice) | Stayed hidden (`color-picker*.json`) |
| Lower middle handle +30 | Height 150 → 180 exactly, width unchanged | Index 1 for ~0.2 s, then back (`resize-height.*`) |
| Lower right handle +20,+20 | 150×180 → 170×200 exactly | Index 1 for ~0.2 s, then back (`resize-corner.*`) |
| New Board (AXPress) | Created an empty board (`Untitled 6` again, since the earlier one was renamed); AX rename failed as before | **Rose to index 1 (just below the key window) and stayed**; reported window y moved 107 → 386 (`new-board.*`) |

**What a hidden diagram builder can do:** picker shapes, typed labels, moves, and fills from the 12 named swatches all keep Freeform inactive and hidden. Sizing via handles works on both axes, with a ~0.2 s rise to just below the key window. Custom (hex) colors are **not** available this way. The Color Picker is inert in the background, so arbitrary colors still require context-menu Paste, which raises the window. Board creation leaves the window just below the key window, and rename (card context menu) raises it to the top. Connectors and stroke/text styling were not tested. The probe board's Circle is now red and 170×200, and a new empty `Untitled 6` exists in the library.

## Round 8: attached connectors without context menus

`connectorTest` ran on the empty **Untitled 6** with window sampling. Safari stayed frontmost with no activation, and **Freeform's window stayed at index 11 throughout** (`round8/connector-zorder.txt`).

| Step | Result |
| --- | --- |
| Picker **Square** ×2, moved apart with AXPosition | Squares at x 529 and 929 (150×150) |
| Picker **Connection Line** | `connection line, curved`; actions AXShowMenu, AXPress, Show format options. Selected, it exposes **Tail handle**, **Head handle**, and **Curvature control** |
| AXPosition of Tail handle onto A's right edge, Head handle onto B's left edge | Handle descriptions became `Tail handle, Connected from Square` / `Head handle, Connected to Square`. Line: `connection line, Connected from Square to Square, curved` |
| Move B down 100 (AXPosition) | **The line followed**: frame height 66 → 122, top 761 → 804 |
| Picker **Line Arrow** | Inserted a free arrow line (AX description `Line`), not attached |

The window capture (`round8/connector-screenshot.png`) shows the curved connector joining both squares after the move. **Native attached connectors therefore work with Freeform inactive and hidden, without clipboard or context menus.** Still open: arrowheads and straight/elbow style for connection lines (likely Stroke Inspector or format bar), attaching to labeled shapes and specific edges, and whether connectors survive sync (the paste route's flat arrows were never attached).

### Connector style (Round 8, continued)

The connection line's **Show format options** bar has Stroke Inspector, Line Ends Inspector, and Connection Line Style Inspector (`round8/connector-stroke.json`, `round8/line-ends-inspector.json`, `round8/connection-line-style-inspector.json`). Every inspector opened with the window hidden.

| Attempt | Result | Freeform window |
| --- | --- | --- |
| Style segment **Straight Connection Type** | Line became `…Connected from Square to Square, straight` | Hidden (`style-straight.*`) |
| Stroke Inspector contents | Solid / Dotted / Dashed / Feathered segments, Stroke Width field and incrementor, color well | Hidden |
| Line Ends pop-up (index 1 = head) via AXPress + menu item | Menu items: None, Simple arrow, Filled circle, Open arrow, Filled arrow, Open circle, Line. Choosing **Filled arrow** made the line `…straight, End: Filled arrow` | **Raised to top** when the menu closed (`line-end-menu.*`) |
| Set the pop-up's AXValue directly | Not settable | (a probe bug pressed the button first, which opened the menu: `line-end-value.*`) |
| Focus the pop-up, then PID Down arrow ×2 | No change | Hidden (`line-end-key.*`) |
| Attach the free picker **Line Arrow** by dragging its Tail/Head onto squares | Did not attach; did not follow a moved square | Hidden (`attach-line-arrow.*`) |

**Conclusion:** straight, corner and curved connectors, stroke style and stroke width are hidden operations. **Arrowheads need the Line Ends pop-up menu, which raises the window once per connector** (restorable with AXRaise of the user's window). Untested alternative: a one-time **Save as Insert Style** on a connector with an arrowhead, so future Connection Lines inherit it. It changes the user's default connector style, so it needs the user's agreement.

## Round 9: production background mode

The findings were promoted into the MCP as the `freeform_bg_*` tools. Build issues found while doing so:

| Issue | Cause | Fix |
| --- | --- | --- |
| Coordinates far outside the window | AXLayoutArea is the full scrollable canvas | Use its parent AXScrollArea as the viewport |
| Go Back ignored after New Board | New board not ready | Retry Go Back while still on the board |
| New board card missing from library | Freeform discards an empty new board when it is left; the card can also appear late | Placeholder sticky note until named, then deleted; wait up to 5 s for the card |
| Shape picker without buttons on a new board | Popover content loads late | Wait for the specific button; placeholder uses the toolbar sticky note instead |
| Inspector not found | "Show format options" toggles the format bar | Invoke it only when the bar is not showing |
| Arrowhead menu items blank | Lazy rendering of pop-up item titles | Fixed-order fallback, verified by `End: …` in the connector description |
| `windowRestored: false` with herdr frontmost | The app exposes no AX windows | Hide and unhide Freeform, which returns its window just below the frontmost window |
| Intermittent missing label | Typing before selection settled | Pause after selecting; one retry only when no object's text changed |

Hiding Freeform during edits was tested as an alternative and rejected: listing works while hidden, but the shape picker popover never appears.
