# Agent handoff: background Freeform editing

Updated 2026-10-09 (end of the resume session). Start here to continue the investigation without repeating completed experiments. [README.md](README.md) holds the full results matrix, round by round, with evidence filenames.

## Goal

Drew wants a model to create and edit native boards in the regular Freeform app while he keeps working in another application. Boards should remain normal Freeform boards that can sync to his phone and iPad.

"Background" breaks down into **three separate properties**. Every result must state which of them it verified:

1. **No activation:** Freeform never becomes the frontmost application, and the user's app keeps keyboard focus. Measured with `NSWorkspace` frontmost identity and activation notifications.
2. **Window stays hidden:** Freeform's window does not rise above the user's windows. Measured with `zsample.swift` (Freeform's index among on-screen layer-0 windows, sampled every 100 ms).
3. **No clipboard:** the operation does not touch the system clipboard.

**Until Round 5, only property 1 was measured.** Any earlier claim that an app "remained frontmost" says nothing about window visibility. The user saw Freeform's window come up on screen during the tests, and the sampler confirmed it.

## Current status

| Capability | Activation | Window | Clipboard | Evidence |
| --- | --- | --- | --- | --- |
| Insert text box and type its label (toolbar AXPress + PID Unicode) | none | **stays hidden** | none | `zorder-clipboard-free/createTextAndType.*` |
| Insert sticky note (toolbar AXPress) | none | not sampled (same toolbar path) | none | `insert-sticky-ax.json` |
| Insert shape from the picker popover | none | **stays hidden** | none | `zorder-clipboard-free/chooseShapeCircle.*` |
| Type or replace a label (PID Unicode) | none | **stays hidden** | none | `zorder-clipboard-free/replaceLabel.*` |
| Move one object (AXPosition) | none | **stays hidden** | none | `zorder-clipboard-free/positionSelected.*` |
| Resize via middle-right handle | none | **brief rise to just below the key window (~0.3 s), then back** | none | `zorder-clipboard-free/resizeHandle.*` |
| Switch boards (library Go Back + card AXPress) | none | **stays hidden** | none | `zorder-clipboard-free/openBoard.*` |
| Window screenshot | none | **stays hidden** | none | `zorder-screenshot.txt` |
| Context-menu Copy readback | none | **raised to top** | temporary, restored | `context-copy-repeats.json`, `zorder-context-copy.txt` |
| Context-menu Paste of N objects (verified up to 4) | none | **raised (same menu path; not separately sampled)** | temporary, restored | `context-paste-two.json`, `context-paste-diagram.json` |
| Create board (New Board AXPress) | none | **not sampled** | none | `create-board-bg.json` |
| Paste onto an empty board (bootstrap circle, then delete) | none | **raised (context menu)** | temporary, restored | `empty-paste.json` |
| Rename board (library card Show Menu → Rename) and reopen | none | **raised to top** | none | `rename-board-bg-2.json`, `rename-zorder-2.txt` |

Taken together, you can create a board, name it, import a diagram, and move, resize and relabel objects without activating Freeform. **The clipboard-free paths (toolbar and picker inserts, typing, moving, switching boards) also keep Freeform's window hidden**, so they're invisible to the user. Handle resize briefly lifts the window to just below the key window. Every context-menu step (Copy, Paste, card menu) **visibly raises Freeform's window** over the user's work and leaves it there. The window rose about 0.6–1.7 s after the menu call. One manual test of the mitigation worked: AXRaise on the frontmost app's main window put it back on top with no activation, and Freeform dropped to second place, ahead of that app's other windows. A brief visible flash per menu operation would remain.

Other facts established this session:
- **Pure Paste caused the earlier Copy failures.** Its Freeform exclusion only applies while Freeform is frontmost, so it stripped background copies about 0.4 s after they appeared (`context-copy-timeline.json`). The user uninstalled it, and background Copy then succeeded on every run that reached Copy.
- **iPad sync confirmed for a background-created board:** at 7:35 PM on 2026-10-09 the user's iPad showed **Background Empty Paste — 2026-10-09** with its background rename and exactly the four pasted diagram objects (correct fills and layout, no bootstrap circle) (`ipad-sync-empty-paste.png`). iPhone delivery of background edits and restart persistence are still unchecked. The production bridge uses foreground interaction and is unchanged.

## Disposable boards

| Board | Last observed contents |
| --- | --- |
| **Background Bridge Probe — 2026-10-09** | 13 objects: Background A, Background B edited without clipboard, a sticky note, two text boxes, Circle, Background paste (oval), Multi paste one/two, Diagram input, `to` (arrow), Diagram process, Diagram output. Frames in `round3-screenshot-proof.json`. Overlaps are a side effect of insertion tests. |
| **Background Empty Paste — 2026-10-09** (was Untitled 6) | Exactly the four diagram objects (`empty-paste-screenshot.png`). It was the open board at handoff. |

These are saved observations. Revalidate them with `inspect` or `screenshot` before editing.

## Repository and environment

- Repository: `/Users/drewcarr/freeform-mcp`, branch `main`. `background/` is committed. Check `git log` for the latest state.
- Regular app: `/System/Applications/Freeform.app`, `com.apple.freeform`, 5.0 (656.1.2), macOS 27.0 (26A428), Apple Silicon.
- No changes to the app bundle, signing, security settings or database. The probes use Accessibility, events posted to Freeform's PID, and sometimes the shared clipboard.
- The host needs Accessibility, live GUI and clipboard access, and screen-capture permission. A failure inside a restricted sandbox doesn't show that Freeform lacks a capability.
- The probes need a running GUI session and an open board. Background does not mean headless.
- The user uninstalled Pure Paste on 2026-10-09. If another clipboard utility shows up, look for its marker types in the Copy timeline before suspecting Freeform.

## Resume safely

```sh
git status --short && git log -3 --oneline
node background/build-probe.mjs
FREEFORM_PROBE_BOARD="Background Empty Paste — 2026-10-09" background/.build/probe screenshot /tmp/ff.png > /tmp/ff.json
```

`FREEFORM_PROBE_BOARD` selects the exact board title. The default is the original probe board. `inspect` and `screenshot` don't edit the board, and `screenshot` was measured not to raise the window. Every probe activates Finder as setup if Freeform starts frontmost, so put another app in front first.

To measure window order around any probe:

```sh
swiftc background/zsample.swift -o /tmp/zsample && /tmp/zsample > /tmp/z.txt & ZP=$!
# run the probe here
kill $ZP; awk '{print $2, $3}' /tmp/z.txt | sort | uniq -c   # Freeform index (0 = topmost), frontmost app
```

If `BOARD_MISMATCH` occurs, check Freeform's actual window and menu state. Don't remove the exact-board guard. A menu, or the library view after a failed rename, can replace the focused board window.

### Probe modes (`probe-body.swift`)

| Mode | Effect |
| --- | --- |
| `inspect`, `inspectTitle`, `screenshot <png>` | Read-only |
| `contextCopy [--last]` | Selects an object; temporary clipboard; logs a clipboard timeline (type names, hashes, no contents) |
| `contextPaste <payload> [--last]` | Adds the payload's objects; verifies labels, sizes, a common translation, and unchanged existing frames |
| `emptyPaste <payload>` | Requires an empty board; bootstrap circle → Paste → deletes the circle with a PID Delete key |
| `createBoard "Background …"` | Presses New Board; tries an AX-only rename (fails: title has no actions); leaves the board as `Untitled N` |
| `renameBoard "Background …"` | Library → card `Show Menu` → Rename → AXConfirm → reopens the board |
| `openBoard "<exact title>"` | Library → card AXPress; switches boards without activation or raising the window |
| `chooseShape`, `createTextAndType`, `replaceLabel`, `resizeHandle`, `positionSelected`, … | Earlier clipboard-free mutations; not idempotent |

| File | Purpose |
| --- | --- |
| `build-probe.mjs` | Prepends production helper declarations (up to `var transaction: ClipboardTransaction?`) and compiles `.build/probe` |
| `zsample.swift` | Window-order and frontmost-app sampler |
| `payload*.json` | Encoded content-language fixtures: 1 oval, 2 objects, 4-object diagram. Every object needs a unique label for verification |
| `prepare.mjs` | Foreground setup for the original board; **do not rerun** |
| `../bridge/native/FreeformBridge.swift`, `../bridge/src/*.mjs` | Production helpers, encoder, verifier, MCP server |

## Traps

- `ok: true` means the probe finished. Check the operation-specific fields (`verified`, `copied`, `renamed`, `clipboardRestored`, activations) and, from now on, the window samples too.
- "Frontmost app unchanged" is **not** "invisible". Report activation and window order separately.
- Initial-count guard: 2–16 objects for most modes; exactly 0 for `emptyPaste`. Adapt bounds deliberately.
- Paste, insert, resize and text modes add or change objects on every run. Inspect before retrying.
- Context-menu opening often returns -25204 even though the menu appears. Don't retry blindly. Menu discovery is English and title-based. **Exclude menu-bar menus** when searching for a context-menu item; the first rename attempt matched the disabled Edit ▸ Rename.
- Board cards reject the standard AXShowMenu (-25200) but expose a custom `Name:Show Menu` action.
- AXSize, AXTextArea AXValue, AXSelectedChildren arrays (multi-select), and the main Edit menu all fail in the background. Main-menu items are disabled.
- Production `key`, `clickElement`, `menuAction`, and `ClipboardTransaction.copiedObjects` activate Freeform. Don't reuse them for background work.
- Clipboard payload writes use `.currentHostOnly`. Freeform's own Copy is not proven excluded from Universal Clipboard. Never overwrite newer clipboard contents to force a restore.
- Freeform places a paste relative to the right-clicked object, so absolute position isn't controlled. AXPosition moves can tidy objects afterward.

## Next experiments

1. **A fully invisible diagram builder.** Clipboard-free paths stay hidden (Round 6), so a diagram could be built from picker shapes, typed labels and AXPosition moves without any context menu. Open questions: setting fill colors and shape size without context menus or handle drags (format controls may be popovers; sample them), New Board's window behavior (not sampled), and speed relative to a single paste.
2. **Built-in window restoration.** Record the window that was topmost before each context-menu step, AXRaise it afterward, and measure how long Freeform stays visible. Find out whether hiding the menu sooner, or skipping the extra wait, shortens it. Consider whether showing a menu without raising is possible at all; that hasn't been explored.
3. **Import robustness.** Larger payloads, grouped payloads, fill/path readback of multi-object pastes (a per-object Copy loop or multi-selection), duplicate prevention after timeouts, and repeating paste placement then AXPosition layout.
4. **Clipboard-free editing.** Both resize axes, other zoom levels, more picker shapes, format controls, and Connection Line endpoints. Prove an attachment by moving the connected shape.
5. **Multi-selection, grouping, alignment.** Possibly process-targeted modified mouse events; check for cursor and window effects. Individual moves can align objects geometrically but don't count as native grouping.
6. **Lifecycle and durability.** Open and switch boards in the background (library AXPress reopened a board), minimized or offscreen windows, Undo (including the bootstrap-circle delete), and restart persistence. iPad sync of a background-created board is confirmed; later edits to an existing synced board (moves, relabels) are not.
7. **Direct import/XPC (low priority).** Only with a specific new endpoint hypothesis. See the XPC section of [README.md](README.md).

## Before promoting into the MCP

Add an explicit background backend with **no automatic foreground fallback**. Reuse serialization, exact board, window and selection guards, bounded timeouts, clipboard ownership checks and partial-success reporting. Each tool should report which background properties it guarantees, and should either restore window order after context menus or state clearly that it raises the window. Run `npm test` in `bridge/`, rebuild native code if needed, and do disposable-board live tests that capture activation, window order and clipboard evidence. Don't claim persistence or sync beyond what was observed.
