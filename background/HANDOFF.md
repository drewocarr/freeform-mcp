# Agent handoff: background Freeform editing

Updated 2026-10-09. Start here to continue the investigation without repeating completed experiments.

## Goal and current stopping point

Drew wants a model to create and edit native boards in the regular Freeform app while he keeps working in another application. Boards should remain normal Freeform boards that can sync to his phone and iPad. Avoiding clipboard interference is also desirable; preserving window focus and avoiding the clipboard are separate capabilities.

We have working background editing prototypes, including **one generated native object imported through context-menu Paste**. We do not yet have a reliable background MCP backend. The existing production bridge still uses foreground interaction. The next priority is making background Copy/readback reliable, then testing multi-object import and empty-board insertion.

Read [README.md](README.md) for the full results matrix and evidence filenames. Read [../bridge/README.md](../bridge/README.md) for the existing MCP. The root README's original feasibility narrative is historical, not current implementation status.

## Repository and environment

- Repository: `/Users/drewcarr/freeform-mcp`, branch `main` at handoff.
- Last commit: `c3abe57` — screenshots and guarded grouping/alignment. Prior commit: `6234695` — initial bridge, research, and FigJam import.
- **The entire `background/` directory is currently untracked and uncommitted**, including this handoff and its evidence. Preserve it. Check Git again before starting; this is a snapshot, not a guarantee of future state.
- Regular app: `/System/Applications/Freeform.app`, bundle ID `com.apple.freeform`, version 5.0 (656.1.2), macOS 27.0 (26A428), Apple Silicon.
- These experiments do not modify the app bundle, signing, security settings, or database. They use Accessibility, events addressed to Freeform's PID, and sometimes the shared clipboard.
- Host execution needs Accessibility access and live GUI/clipboard access; screenshots need screen capture permission. Previous probes ran outside the restricted command sandbox using the host execution permission mechanism. A restricted-sandbox failure is not proof that Freeform lacks a capability.
- The current probes require a running GUI session and an already-open board. “Background” means another application remains frontmost, not headless operation.

## Latest update (resume session, 2026-10-09)

Pure Paste caused the Copy failure and the user uninstalled it. Background Copy readback then passed every run that reached Copy. Context-menu Paste imported a two-object payload and a four-object diagram with exact labels, sizes, and common relative layout. See README Round 3. **The board now has 13 objects**: the seven below plus `Multi paste one`, `Multi paste two`, `Diagram input`, `to` (arrow), `Diagram process`, `Diagram output` (frames in `round3-screenshot-proof.json`). Remaining step-2 work: empty-board paste, larger payloads, grouped payloads, fill/path readback of multi-object pastes (needs multi-selection or a per-object Copy loop), and duplicate prevention after timeouts.

**Round 4 (same session):** a board was created in the background (**Untitled 6**, not yet renamed) and a four-object diagram was imported onto its empty canvas via a temporary bootstrap circle that was then deleted. That board now holds exactly the four diagram objects. Naming boards in the background is unsolved: the toolbar title has no AX actions and Edit ▸ Rename is disabled. Next: try the library board card's context menu, then open/switch boards in the background. Use `FREEFORM_PROBE_BOARD="Untitled 6"` to target it. See README Round 4.

## Last observed disposable board (before Round 3)

Exact title: **Background Bridge Probe — 2026-10-09**.

The last screenshot shows seven objects at 100% zoom. This is saved evidence, **not a fresh live inspection for this handoff**. Revalidate before editing. Selection, foreground app, open menus, geometry, and object ordering may have changed.

| Last observed object | AX screen frame: x, y, width, height |
| --- | --- |
| Background A, Rectangle | 340, 327, 180, 70 |
| Background B edited without clipboard, Rectangle | 580, 327, 140, 70 |
| Created in background without clipboard, sticky note | 340, 487, 200, 200 |
| Background text box — no clipboard, text box | 640, 517, approximately 298.3, 29 |
| Second background text — verified, text box | 640, 597, approximately 289.1, 29 |
| Circle | 779, 472, 150, 150 |
| Background paste, Oval | 834, 562, 140, 70 |

Evidence: `round2-screenshot.png` and `round2-screenshot-proof.json`. Circle and oval overlap some text deliberately as a consequence of insertion tests; this is not a finished layout. AX screen coordinates differ from native model coordinates. The oval's copied model position was (594, 403), size 140 × 70.

The last completed experiment was `contextCopy --last` with a clipboard timeline, saved as `context-copy-timeline.json`. It **identified the readback failure**: Freeform published the native one-object payload at 17 ms; Pure Paste rewrote it to plain text (adding `com.sindresorhus.Pure-Paste.hasRun`) at 437 ms. Pure Paste excludes Freeform only when Freeform is frontmost, so background Copy is always stripped. Safari stayed frontmost with no activation; restoration was correctly declined (1205 expected, 1207 observed). The earlier `context-copy-stable.json` failure has the same shape. **The user then uninstalled Pure Paste**, and a repeat (`context-copy-no-purepaste.json`) succeeded: exact label, 140 × 70, position (594, 403), clipboard restored, Ghostty frontmost, no activation. One run only; repeat a few times before calling Copy reliable. A live inspect and window capture immediately beforehand showed the same seven objects and frames as the table above. No probe process was left running.

## What is established

**Without clipboard use:** Accessibility toolbar actions create sticky notes and text boxes; the shape picker created a native circle. Selecting one object and posting Unicode text directly to Freeform's PID replaced its label. Setting AXPosition moved objects. Moving the middle-right AXHandle resized a rectangle by exactly +40 width. ScreenCaptureKit captured the Freeform window behind another app.

**With temporary clipboard use:** The selected object's context menu exposed enabled Copy and Paste commands, even though main-menu commands were disabled. AXPress on context-menu Paste inserted one generated native oval. Ghostty remained frontmost and the clipboard restored. Separate context-menu Copy read back its exact text and dimensions, but restoration declined because the clipboard changed later.

Successful evidence includes `insert-circle.json`, `resize-handle.json`, `replace-existing-label.json`, `context-paste-retry.json`, and `context-copy-imported.json`. Earlier context Copy restored successfully in `context-copy-refined.json`. These runs prove possibility, not repeatable reliability across all states.

Phone/iPad sync was user-confirmed earlier for the regular foreground bridge. **These particular background edits have not been checked on another device or after restarting Freeform.**

## Resume safely: first commands and source map

From the repository root, inspect code and evidence before launching a mutation:

```sh
git status --short
git log -2 --oneline
cat background/context-copy-stable.json
node background/build-probe.mjs
background/.build/probe inspect > /tmp/freeform-background-resume-inspect.json
```

Review the resulting JSON before proceeding. `inspect` records board state and AX capabilities; it does not edit board objects. However, every probe currently activates Finder as setup if Freeform starts frontmost. Start with another app frontmost if testing uninterrupted focus. The activation observer is reset after that setup, so an empty event list does not cover this initial Finder activation.

An optional non-editing window capture:

```sh
background/.build/probe screenshot /tmp/freeform-background-resume.png > /tmp/freeform-background-resume-screenshot.json
```

If `BOARD_MISMATCH` occurs, inspect Freeform's actual window/menu state. Do not remove the exact-board guard. A menu can temporarily replace the focused board window. If the board must be reopened with a foreground operation, label that as setup, outside the background proof.

| File | Purpose |
| --- | --- |
| `background/probe-body.swift` | Actual experiment modes, focus observer, board guards, result logging |
| `background/build-probe.mjs` | Combines production helper declarations with the probe body and compiles `.build/probe` |
| `background/payload.json` | Encoded native content-language JSON for one labeled green oval; suitable for current contextPaste mode |
| `background/prepare.mjs` | Foreground setup that creates the disposable board and two controls; **do not rerun on resume** |
| `bridge/native/FreeformBridge.swift` | Production AX helpers, clipboard transaction, screenshot, and foreground operations |
| `bridge/src/bridge.mjs` | Production JS bridge orchestration and serialization; inspect before adding a backend |
| `bridge/src/encode.mjs`, `bridge/src/verify.mjs` | Native payload generation and result verification |
| `bridge/src/server.mjs` | MCP tool exposure |
| `background/inspect-xpc.py`, `background/xpc-protocols.json` | Build-specific static renderer protocol inspection |

The build script extracts declarations before `var transaction: ClipboardTransaction?` in the production Swift source. Rebuild after any probe or shared-helper change; `.build/` is ignored. Use `probeWait`, not an unqualified `pause()` (which previously resolved to Darwin's blocking function). Keep the standalone `NSApplication` activation policy `.prohibited`; without AppKit initialization a screenshot probe previously aborted.

## Probe limitations and traps

- `ok: true` means the probe finished. Check operation-specific `inserted`, `copied`, `exactLabelVerified`, geometry, counts, foreground identity, activation events, and `clipboardRestored`. `context-copy-stable.json` is an explicit example of `ok: true` with a failed operation.
- Current initial-count guard is **2 through 16 objects** (raised from 8 for Round 3; board has 13). The current Paste verifier expects exactly **one** added object; Copy expects exactly **one** copied object. These must be deliberately adapted for empty-board or batch tests. Do not simply remove bounds.
- Commands such as `chooseShape Circle`, `contextPaste`, and `createTextAndType` add objects every run. `resizeHandle` adds another 40 points of width. They are not idempotent. Inspect partial results before retries.
- `--last` selects the last AX object, not a persistent object ID. It was the oval when tested. `replaceLabel 0/1` uses control indices. `layout` expects older descriptions and only five known objects; it is not a reset for the current board.
- AXSize and AXTextArea AXValue returned success without effect. A Return-based text-edit experiment erased the first control's label; it was restored afterward. Direct selected-object Unicode typing worked instead.
- AXPosition affects the entire selection. Select and verify exactly one object before moving or resizing it. AXSelectedChildren arrays and sequential AXSelected writes did not establish multi-selection.
- Context-menu opening sometimes returned -25204 even though the menu appeared. It is not grounds for blind retry. Menu discovery is currently English/title-based (`Change Shape`, `Copy`, `Paste`).
- The menu-aware guard checks the cached board title, weaker than a production identity check. Selection and clipboard state also need revalidation immediately before dispatch. Error exits do not guarantee menu cleanup.
- Production `key`, `clickElement`, `menuAction`, and `ClipboardTransaction.copiedObjects` activate Freeform. Do not reuse those paths as background operations. The transaction's snapshot/put/restore methods can be reused independently.
- Capture the foreground identity and activation notifications throughout a test. A user switching between Safari and Ghostty invalidates “same foreground throughout” but does not prove Freeform stole focus. Never silently fall back to foreground execution.
- Our clipboard payload writes use `.currentHostOnly`; **Freeform's own Copy is not proven excluded from Universal Clipboard**. Do not claim this route is clipboard-free. Never overwrite newer clipboard contents to force a successful restore.

## Experiments to do next

### 1. Background Copy/readback: cause found, decide on a route

**Resolved diagnosis:** Pure Paste rewrites Freeform's background Copy about 0.4 s after publication (see `context-copy-timeline.json`). The user resolved this by uninstalling Pure Paste; background Copy readback then succeeded once. Remaining work: repeat it several times, and keep the probe/production detection of the `com.sindresorhus.Pure-Paste.hasRun` marker (or any other rewrite) so a future clipboard utility produces an explicit conflict error rather than a timeout. Next priority is step 2. The historical notes below predate the diagnosis.

Latest code waits for stable native JSON for 0.5 seconds, with a 15-second timeout. This change did **not** fix the latest run. The source of the subsequent clipboard changes is unknown: do not attribute them to Pure Paste, Freeform, Universal Clipboard, or user activity without evidence.

Add bounded, timestamped diagnostics around Copy: change count, representation type names, native payload presence/hash/length, selection, and foreground identity. Avoid logging unrelated clipboard contents. Record whether instability is from count changes, missing data, or a different object count. Inspect the current clipboard utility configuration read-only; don't change user settings merely to make a test pass.

After refreshing the board and selecting the intended oval, the existing readback probe is:

```sh
background/.build/probe contextCopy --last > /tmp/freeform-background-copy-next.json
```

This changes selection and temporarily uses the clipboard. Treat it as an opt-in experiment, not a status command. Success requires the intended native object, unchanged foreground/no Freeform activation, and either safe restoration or an accurately reported newer-copy conflict. Repeated unexplained conflicts mean the route is not ready for production. Do not automatically adopt any new clipboard count as “ours.”

### 2. Expand native import beyond one object

First strengthen the probe to accept a known expected payload count and verify object identity and relative geometry, rather than only count. Use the existing encoder for a small, uniquely labeled multi-object fixture. Save it separately from `payload.json`; the current probe consumes encoded content-language JSON, not the public JS object-spec format.

Test two objects, then a small diagram. Readback should verify labels, dimensions, fills, and a common placement translation as the production verifier does. Do not require absolute paste coordinates. Stop on ambiguous outcomes and inspect for already-inserted objects before retrying.

The existing **single-object mutation** command, for reference only:

```sh
background/.build/probe contextPaste /Users/drewcarr/freeform-mcp/background/payload.json > /tmp/freeform-background-paste-next.json
```

Then investigate Paste on a new empty disposable board. The current route requires an existing shape's context menu and cannot establish empty-canvas behavior. A possible bootstrap is background creation of a native shape, but its safe removal and effect on Undo must be verified, not assumed. Grouped payloads and attached connectors are separate tests; the current encoder's flat arrows are not proof of attached Connection Lines.

### 3. Expand editing without clipboard use

Explore both resize axes, alternate zoom levels, native shape entries, and observed format controls. Test nonempty label replacement separately from text-box creation. For a Connection Line, inspect endpoint handles and prove attachment by moving the connected shape and verifying the endpoint follows. Merely placing a line beside a shape is insufficient.

Success requires exact intended changes to only the selected target, unchanged object count where appropriate, no clipboard writes, and no activation. Restore a reversible geometry test to its captured starting geometry when practical; do not use broad Undo as cleanup for unknown intervening edits.

### 4. Multi-selection, grouping, and alignment

Candidate routes include process-targeted modified mouse events and further observed AX controls. Neither has been proven. Validate the selected set before invoking any grouping/arrangement action; do not mistake the last selected object for the full set. If testing mouse events, also check cursor movement and focus effects.

Individual verified moves could implement geometric alignment without multi-selection. That would not establish native grouping or the native align commands. Verify group membership and ungroup round-trip separately.

### 5. Board lifecycle and durable behavior

Test background create/open/switch, minimized or offscreen windows, multiple open boards, dialogs, Undo, and another zoom level. Keep each scenario isolated. Finally verify save/reopen and device sync of a uniquely labeled background-created object. Mac state alone cannot prove delivery to the phone/iPad; use device observation or user confirmation.

### 6. Direct import/XPC, lower priority

No callable board-editing XPC endpoint was found. The inspected protocols belong to USD rendering, not board editing. Earlier Add Item intent experiments did not yield a working route. See [../direct-import/runtime-results.md](../direct-import/runtime-results.md), [../direct-import-static.md](../direct-import-static.md), and the XPC section of [README.md](README.md).

Continue this avenue only with a specific new endpoint or invocation hypothesis. Do not repeat broad string searches and relabel renderer actions as editing APIs. Lab-app injection/swizzling results do not establish access to the regular signed app or its synced store.

## Before promoting a result into the MCP

Introduce an explicit background backend/mode with no automatic foreground fallback. Reuse operation serialization and strengthen board/window identity, selection, stale-state checks, bounded timeouts, clipboard ownership checks, and partial-success reporting. Reject unsupported operations clearly. Keep experiments separate from production until each capability has an actual effect test.

Run the existing bridge tests from `bridge/` (`npm test`), rebuild native code if changed (`npm run build:native`), and perform targeted disposable-board live tests for changed behavior. Existing tests passing alone do not prove focus preservation. Save evidence of before/after objects, operation-specific verification, focus events, and clipboard handling. Update the results matrix and this handoff with the new stopping point. Do not claim full diagram automation, persistence, or sync beyond what was observed.

This handoff request authorizes documentation; it does not request a commit or a switch of the production MCP to background mode.
