# Freeform JavaScript + MCP bridge

Create editable Freeform diagrams from JavaScript. This local prototype generates labeled rectangles, rounded rectangles, ellipses, and arrows from scratch, inserts them into an open board, and reads them back to check the result.

**Verified on this Mac:** Freeform 5.0 (656.1.2), macOS 27.0. The board **JavaScript Diagram Demo** contains three labeled shapes and two arrows created through the MCP server. No copied template or native attribute archive is used by the encoder.

## Use the existing build

Open Freeform and the intended board. Click its canvas or select objects; finish any text/title editing first. Commands require the exact board title and target Freeform's own Accessibility elements.

From this directory:

```sh
node src/cli.mjs status
node src/cli.mjs read-selection 'JavaScript Diagram Demo'
```

To insert another copy of the example (this adds five objects):

```sh
node src/cli.mjs insert 'JavaScript Diagram Demo' examples/diagram.json
```

The host launching the helper needs macOS Accessibility access and live clipboard access. It worked from this session's host process; the restricted tool sandbox could not access the clipboard. The helper checks permission without prompting or changing settings. It inspects English Edit commands and sends their standard keyboard shortcuts without opening the menu.

## JavaScript API

```js
import { getStatus, insertObjects, readSelection } from './src/bridge.mjs';

const result = await insertObjects({
  expectedBoardTitle: 'My Board',
  objects: [
    {
      shape: 'roundedRectangle',
      x: 0, y: 0, width: 220, height: 120,
      fill: '#A7D8FF',
      text: 'Editable label',
    },
    {
      shape: 'arrow',
      x: 235, y: 45, width: 50, height: 30,
      fill: '#64748B',
    },
  ],
});
console.log(result.translation, result.verification);
```

`objects` accepts 1–100 objects. Supported `shape` values are `rectangle`, `roundedRectangle`, `ellipse`, and `arrow`. Coordinates must be finite within ±100,000; dimensions must be greater than zero and at most 10,000. Colors use `#RRGGBB`; text is optional, at most 10,000 UTF-16 code units. Unknown object fields are rejected.

Positions define **relative layout**, not guaranteed absolute board placement. Freeform translates the pasted selection. The bridge verifies one common translation, returns it as `translation`, and returns actual geometry in `objects`. It checks labels, fill RGB, dimensions, relative positions, and native shape representation. It does not compare every curve point or prove all styling fidelity.

`readSelection({expectedBoardTitle})` reads selected objects only. It also successfully read a native Freeform group containing three generated shapes. The insertion API currently accepts flat object arrays, not groups.

## MCP

Launch the stdio server:

```sh
node /Users/drewcarr/freeform-mcp/bridge/src/server.mjs
```

It exposes:

| Tool | Behavior |
|---|---|
| `freeform_status` | Reports running state, Accessibility access, board title, and canvas object count when readable |
| `freeform_create_board` | Creates and names a board in regular Freeform |
| `freeform_open_board` | Opens a uniquely matching visible board card by title |
| `freeform_list_objects` | Lists accessible canvas objects with temporary indices and descriptions |
| `freeform_move_object` | Selects a guarded object, nudges it, and reads geometry before/after |
| `freeform_undo` | Invokes the board’s latest Undo action; this may include a manual edit |
| `freeform_insert_objects` | Generates and inserts objects, then verifies selected-object readback |
| `freeform_read_selection` | Returns the selected objects' content-language models |

Use [mcp-config.example.json](mcp-config.example.json) in an MCP client's server configuration. Paths in that file are specific to this Mac. No global MCP/client configuration was changed. The server was tested using a real SDK stdio client, not just direct JavaScript calls.

The implementation uses the [official MCP TypeScript SDK v2](https://ts.sdk.modelcontextprotocol.io/v2/) with pinned dependencies. It runs locally over stdio; it does not open a network listener.

## Build and tests

Requires Node 20+ and the Swift compiler from Xcode/Command Line Tools:

```sh
npm ci
npm run build:native
npm test
```

**27 automated tests passed**, covering generated geometry/content, rejected inputs, observed Freeform normalization, MCP tool schemas/errors, and actual stdio initialization/discovery.

The opt-in live test inserts into the supplied board:

```sh
node test/live-mcp.mjs 'Exact Disposable Board Title' examples/diagram.json
```

**Live test passed:** actual MCP status → insertion → selection readback. Five native objects, exact nonempty labels, RGB within 1e-6, dimensions/relative geometry within 1e-4 points, and clipboard restoration on both insertion and inspection. [Captured result](examples/live-mcp-result.json).

Additional live checks: wrong-board requests were rejected with canvas count unchanged; generated objects could be grouped and read as one group with three children; Undo removed the generated diagrams normally. Grouping evidence: [readback](examples/live-group-readback.json).

Two observed normalizations are explicitly handled: empty labels become one U+200B character, and native rectangles can omit their redundant Bezier path on export.

## Behavior and limits

- Regular-app tools can create named boards and open uniquely matching visible board cards. They do not enumerate the entire saved library.
- Insertion adds new objects. Regular-app moves use temporary Accessibility indices and descriptions, not persistent object IDs; re-list before each move. Identical descriptions cannot establish stable identity.
- Arrows are independent editable vector shapes. They do not attach to boxes or follow moved boxes. Native attached connectors remain a separate reverse-engineering task.
- Rounded rectangles use vector curves; the special corner-radius handle is not preserved.
- Labels use Freeform's default text formatting. Explicit fonts, rich styling, images, tables, and arbitrary imported paths are outside this API.
- Guarded grouping/ungrouping and six alignment commands are available for explicitly listed unrotated, unflipped shapes; see below.
- Tested on the installed Freeform/macOS version only. The content-language format is private and may change.
- The user confirmed the test boards and their generated shapes appeared on iPhone. iPad delivery and cross-device editing remain unverified.

## Clipboard and failure handling

The native helper keeps the clipboard backup in memory, refuses to proceed if any advertised representation cannot be preserved, writes only the typed JSON payload, copies the result for verification, and restores the backup when the observed clipboard change count still matches. It reports restoration failures rather than silently claiming success.

JavaScript calls are serialized; a process lock prevents overlapping helper operations. The helper checks board title and canvas focus before work, and checks window identity/title again immediately before pressing Copy/Paste. These checks reduce accidental targeting but cannot make concurrent human UI activity atomic. Avoid switching boards or copying other content while a command is running.

No mutation is automatically retried. If a timeout or uncertain result occurs, inspect the board before retrying: the paste may already have completed. Killing the helper can interrupt clipboard restoration; timeout errors call out that uncertainty.

## Source map

- `src/encode.mjs`: template-free content-language encoder.
- `src/verify.mjs`: observed-format-aware content/layout verification.
- `src/bridge.mjs`: serialized JavaScript API and helper lifecycle.
- `native/FreeformBridge.swift`: AppKit clipboard and targeted Accessibility commands.
- `src/server.mjs`: MCP tool schemas and stdio transport.
- `src/cli.mjs`: command-line interface.

Apple documents the targeted native action mechanism in [AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction). The Freeform wire format here was established through the local reverse-engineering experiments in the parent directory.

## Native editing in the isolated lab copy

The native tools discover open lab boards and their existing objects, then move an object through Freeform's own undoable command. They require the separately launched, instrumented **FreeformLab** copy. They never inject into or select the installed Freeform app. Existing clipboard tools still target the installed app as documented above.

Use [mcp-config.native.example.json](mcp-config.native.example.json) or explicitly configure the lab session when launching MCP:

```sh
FREEFORM_NATIVE_SESSION_FILE=/Users/drewcarr/freeform-mcp/inprocess/lab/data/transport/session.json node src/server.mjs
```

| Tool | Behavior |
|---|---|
| `freeform_native_status` | Reports lab status, or that the lab is not configured/available |
| `freeform_native_list_boards` | Lists currently discoverable **open** boards, with persistent UUIDs |
| `freeform_native_list_objects` | Reads objects and geometry for a supplied board ID; no preliminary shape edit is needed |
| `freeform_native_move_object` | Moves a supported object to absolute `x,y`, requiring its current `expectedGeometry` |

Open the disposable board in the lab UI first. List boards, list objects, then pass the returned board/object IDs and `{x,y,width,height}` geometry to a move. Board/object UUIDs survived the restart test; re-list boards after restart to establish which are currently open. This does not yet open saved boards, create objects through native methods, or expose iCloud synchronization. It does not make the installed app's boards available to the lab.

```js
import { createNativeBridge } from './src/native-bridge.mjs';
const native = createNativeBridge({
  sessionFile: '/Users/drewcarr/freeform-mcp/inprocess/lab/data/transport/session.json',
});
const { boards } = await native.listBoards();
const { objects } = await native.listObjects({ boardId: boards[0].id });
const object = objects[0];
await native.moveObject({
  boardId: boards[0].id, objectId: object.id,
  x: object.geometry.x + 30, y: object.geometry.y + 20,
  expectedGeometry: object.geometry,
});
```

Only run the example on a disposable board you intend to change. Moves create undo history and are not marked idempotent. A stale geometry precondition or unknown object is rejected. A timeout has **unknown outcome**; inspect the board before trying again. No request is automatically retried. Each request has a unique ID, session identity and expiry; native processing serializes work on the application main thread. Requests are written atomically with mode 0600. The manifest and queues must remain inside the explicit lab transport directory. The manifest is replaced when the lab restarts.

**Live MCP verification passed:** discovery, move by (+30,+20), stale geometry rejection, unknown object rejection, canvas update, Undo/Redo readback, and two independent clients reading concurrently. Evidence: [native MCP proof](../inprocess/logs/native-mcp-proof.json). Stable UUIDs and saved geometry also passed a full restart, and a cross-board object request was rejected. See [live editing setup](../inprocess/LIVE-EDIT.md) for the instrumented app. No global MCP configuration was installed.

## Everyday boards and iCloud

The regular-app tools operate on the installed Apple Freeform app, so boards follow its normal saving and iCloud behavior. They do not use the isolated lab database. All devices need the same Apple Account and Freeform enabled in iCloud ([Apple setup instructions](https://support.apple.com/en-ie/guide/icloud/mmd1b86048ac/icloud)). Tool success is not a cloud-delivery receipt.

On 2026-10-09 the user supplied an iPhone screenshot showing **Bridge iCloud Check — 2026-10-09** and **Mac Bridge Sync Test — 2026-10-09** in All Boards. The user subsequently confirmed that the shapes were present as well. This establishes Mac-to-iPhone board and content delivery in this test. iPad arrival remains unverified.

`freeform_move_object` requires an index and exact description from `freeform_list_objects`. `dx` and `dy` are integer arrow-key counts from -100 to 100. Read the returned geometry to determine the actual change. These are UI operations: avoid interacting with Freeform during a call. No mutation is automatically retried. Undo affects the latest normal app action, not a bridge-owned transaction.

The opt-in `node test/live-regular-mcp.mjs 'Unique Disposable Title' --create` creates a board and inserts five shapes before testing a one-step move and Undo. Without `--create`, it requires an existing empty board. Do not run it on an everyday work board.

### Current regular-app test status

The full regular-app MCP test now passes on **Clipboard Reliability Test — 2026-10-09 C**: create/name, five-shape insertion with content and geometry verification, list, one-point move, Undo with geometry readback, and rejection of a stale object description. Clipboard restoration succeeded for the tested insertion, movement, and readback calls. See [full test evidence](examples/regular-mcp-proof.json).

The command path now inspects menu availability but uses standard keyboard shortcuts without opening Edit. Earlier menu-opening AX actions left Freeform in a menu-tracking loop, causing subsequent Copy/Paste failures. This pass required normal app restarts while diagnosing the old implementation; the final implementation completed the full test without a restart between operations. Pure Paste's Freeform exclusion was previously confirmed in its UI. That exclusion alone did not fix the menu-loop failure.

Bridge-written payloads, verification markers, and restored clipboard contents use `currentHostOnly`. Freeform's own Copy publication can still participate in Universal Clipboard; this is not a complete Universal Clipboard exclusion. Restoring existing contents locally does not preserve their previous cross-device availability setting. iCloud board syncing is separate; this pass did not reverify delivery on other devices.

Readback no longer adopts arbitrary clipboard change counts as safe to restore over. Board/selection checks surround Copy; clipboard checks precede Paste and Copy. A clipboard change that cannot be verified is left alone and restoration failure is reported. The system clipboard is still shared and has no atomic ownership transaction: avoid copying or interacting with Freeform during a call, especially another Freeform Copy. These guards reduce conflicts; they cannot guarantee isolation from simultaneous user activity.

The follow-up populated-board test also passed on the same board without a restart: added two objects, verified only those two were selected and copied, then undid the insertion and confirmed the original five descriptions remained.

27 automated tests pass. `npm run test:clipboard` separately uses a unique private AppKit pasteboard to verify multi-format restoration, preservation of a newer copy, rejection of a conflicting write, and empty-clipboard restoration. It does not touch the general clipboard. The live populated-board test is `node test/live-existing-board.mjs 'Disposable Board Title'`; inspect its [evidence](examples/existing-board-proof.json) before rerunning after any failure.

Partial native errors now retain machine-readable outcome flags and `retryAutomatically:false` in MCP responses. No mutation is automatically retried. This prevents the bridge itself from blindly duplicating an uncertain insertion; it does not deduplicate a caller's repeated request or automatically recover an interrupted call. `freeform_undo` still reports `verified:false`; the full live test independently verifies its effect. Killing or timing out the helper can still interrupt clipboard restoration.


## Screenshots, grouping, and alignment

`freeform_screenshot` returns a PNG as MCP image content, so a client can see the board directly. It captures only the requested Freeform window, including its controls and current viewport, with a maximum dimension of 1600 pixels. It does not fit or export the whole infinite board, use the clipboard, or change board content. It brings Freeform forward and requires existing Accessibility and Screen Recording access. It refuses ambiguous window matches and discards the capture if the focused board/window bounds change. There is no desktop-capture fallback. Window capture uses [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).

```sh
node src/cli.mjs screenshot 'Exact Board Title' /tmp/board.png
```

For edits, call `freeform_list_objects` first. Choose the exact objects and pass its `snapshotToken` as `expectedSnapshot`, alongside their indices and descriptions:

```js
import { listObjects, arrangeObjects } from './src/bridge.mjs';
const expectedBoardTitle = 'Disposable Board';
const current = await listObjects({ expectedBoardTitle });
const targets = current.objects.slice(0, 2).map(object => ({
  objectIndex: object.objectIndex,
  expectedDescription: object.description,
}));
const result = await arrangeObjects({
  expectedBoardTitle,
  expectedSnapshot: current.snapshotToken,
  targets,
  action: 'left',
});
```

MCP tools:

- `freeform_group_objects`: `action: "group"` for 2–100 shapes, or `"ungroup"` for one simple group.
- `freeform_align_objects`: `action: "left" | "center" | "right" | "top" | "middle" | "bottom"` for 2–100 shapes. Alignment uses the selection's collective bounds.
- `freeform_screenshot`: `expectedBoardTitle` only.

The edits reject stale layout snapshots, duplicate indices, ambiguous descriptions, wrong boards, text-editing focus, disabled commands, rotated/flipped shapes, and nested groups. The snapshot covers Accessibility descriptions and screen bounds; zoom, scrolling, and window changes may invalidate it. It is not a persistent object identity or an atomic lock against human activity. Re-list after each edit. Only objects exposed by Accessibility are eligible.

The bridge selects exactly the requested objects, reads their native data, performs one command, and reads back the result. Verification checks preserved content/styles/dimensions, positions for grouping, and the requested alignment plus unchanged opposite-axis positions. Unrequested objects must retain their Accessibility identities and screen bounds. Selection changes are not restored. Verification uses the existing shared-clipboard transaction; the prior Universal Clipboard and concurrent-user limitations still apply. An error may follow a completed edit: inspect before retrying. There is no automatic rollback or mutation retry.

Live MCP verification passed on **Bridge Arrangement Test — 2026-10-09 A**: window screenshot (visually inspected), grouping three shapes while leaving a fourth untouched, ungrouping, all six alignments with Undo between them, stale-snapshot rejection before mutation, and wrong-board screenshot rejection. All arrangement calls reported successful clipboard restoration. Evidence: [live proof](examples/arrangement-mcp-proof.json), [screenshot](examples/arrangement-screenshot.png). This test did not verify iCloud delivery.

The opt-in test `node test/live-arrangement-mcp.mjs 'Unique Disposable Title'` creates a board with four test objects and stops on any failure. The server now advertises 15 tools: 11 regular-app tools and four isolated-lab tools.
