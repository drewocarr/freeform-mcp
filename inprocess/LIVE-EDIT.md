# Native Freeform MCP

The MCP server can discover open boards, list their objects by persistent UUID, and move an existing object through Freeform's native undoable command. No preliminary shape edit or selection is required.

This backend runs only in the separate, instrumented **FreeformLab** app. Its boards live in a scratch directory, and its cloud dependencies are replaced by offline stand-ins. The installed Apple-signed Freeform app and its boards are not exposed through these native tools. The existing clipboard tools continue targeting the installed app.

## Start the lab and MCP server

From `/Users/drewcarr/freeform-mcp/inprocess`:

```sh
make
FF_OFFLINE_MODE=stub FF_STARTUP_SECONDS=0 python3 run-startup.py myrun1
```

Use a new alphanumeric run label each time. `0` runs until the lab app quits or the launcher is interrupted. For a bounded experiment, set a duration between 1 and 3600 seconds. The launcher prevents two launcher instances from sharing the lab store and removes its session manifest when the process exits normally.

In the lab app, continue onboarding and open a scratch board. You do not need to select or edit a shape. Onboarding currently repeats when the lab restarts.

Use [the MCP configuration example](../bridge/mcp-config.native.example.json) in your client, or launch the server with:

```sh
FREEFORM_NATIVE_SESSION_FILE=/Users/drewcarr/freeform-mcp/inprocess/lab/data/transport/session.json node ../bridge/src/server.mjs
```

No global MCP configuration has been installed. The configuration example uses the existing Node installation on this machine.

| Tool | What it does |
| --- | --- |
| `freeform_native_status` | Reports whether the configured lab session is available |
| `freeform_native_list_boards` | Lists open boards with UUIDs and titles |
| `freeform_native_list_objects` | Lists a board's objects, UUIDs, geometry, and preliminary move eligibility |
| `freeform_native_move_object` | Moves the specified object to absolute model coordinates, requiring its last-read geometry |

A move requires `boardId`, `objectId`, `x`, `y`, and `expectedGeometry: {x,y,width,height}` from the last object listing. The backend resolves the object from that board's current contents, checks that the editor has no open command group, rejects locked objects, compares the geometry, and validates the native command ABI before applying the move. Coordinates describe model geometry, not screen pixels. Rotation, grouping, and other object types need further live validation.

For direct terminal use:

```sh
node issue-command.mjs status
node issue-command.mjs boards
node issue-command.mjs objects BOARD_UUID
node issue-command.mjs move BOARD_UUID OBJECT_UUID 456 269 '{"x":426,"y":249,"width":150,"height":150}'
```

Use actual returned IDs and geometry; the values above illustrate the test. The old positional interface using a log filename and relative delta has been replaced.

## Request handling

Each process creates a new random transport session with private request/response directories. Clients write one atomic file per request with a unique ID, session ID, and expiration time. The app processes requests serially on its main thread, claims each request before execution, and does not replay it. Responses must match both IDs. Separate clients cannot overwrite each other's requests.

A move timeout has an unknown outcome. Inspect the board before submitting another move; clients never retry automatically. A stale geometry, wrong board/object, wrong session, expired request, or open command group returns an error instead of silently changing another object. Geometry is a precondition, not a general revision token for every object property.

## Verified behavior

Tested on Freeform 5.0 (656.1.2), macOS 27.0 (26A428), arm64e:

- A real stdio MCP client listed the open board and rectangle without an initial edit.
- The native move changed `(426,249)` to `(456,269)` with size `150 × 150` unchanged.
- Stale geometry and a nonexistent object were rejected; model state remained unchanged afterward.
- Undo restored `(426,249)` and Redo restored `(456,269)`.
- After restarting the app, the same board UUID, object UUID, and `(456,269)` geometry were read without selecting or editing the shape.
- A request for that object on another open board was rejected.
- Two separate clients received their own concurrent read results.
- Expired and wrong-session mutation requests were rejected before execution.
- Both lab processes exited with code 0; unavailable status was verified after session cleanup.
- Native libraries compiled for arm64 and arm64e; all 19 JavaScript tests passed.

Evidence: [MCP run](logs/native-mcp-proof.json), [Undo/concurrent clients](logs/native-mcp-undo.json), [Redo](logs/native-mcp-redo.json), [restart](logs/native-mcp-restart.json), [cross-board targeting](logs/native-cross-board-guard.json), [request guards](logs/native-transport-guards.json). The earlier low-level proof is preserved in [live-edit-proof.json](logs/live-edit-proof.json).

## Components and remaining scope

- `discovery.m`: captures live command controllers at initialization, holds them weakly, and resolves board/object UUIDs through validated getters.
- `command.m`: session queues, validation, native command submission, and model readback.
- `offline.m`: explicit cloud stand-ins and app-group path redirection to `lab/data`.
- `../bridge/src/native-bridge.mjs`: JS transport; `server.mjs` exposes the MCP tools.
- `movement.m` and `probe.m`: supporting instrumentation and earlier research probes.

Only open controller-backed boards are discoverable. Opening saved boards still uses the lab UI. Native creation, text/style editing, batch commands, general object types, and cloud collaboration are not implemented. The offline stand-ins stop on unsupported cloud requests. This is a version-specific research backend, not a general replacement for Freeform.

For a fresh lab copy, `prepare-lab.py` copies and re-signs the app with a separate identity, refuses overwrites, and never changes the installed app. Rebuild the launcher with `xcrun clang launch-probe.c -o launch-probe` if needed. Sandbox paths currently refer to this workspace. No global security settings were changed.
