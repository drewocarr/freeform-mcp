# Freeform MCP

JavaScript and MCP tools for creating editable objects in the regular macOS Freeform app, with research prototypes for an isolated app copy.

Start with [bridge setup and tools](bridge/README.md). The [FigJam recreation](bridge/examples/laa-lot-tracker/README.md) includes the source board export, conversion scripts, and verification evidence.

For ongoing background-editing work, start with the [agent handoff](background/HANDOFF.md), then the [experiment results](background/README.md). The MCP now includes **background tools** (`freeform_bg_*`) that edit boards while you keep working in another app. See [Background editing](bridge/README.md#background-editing-keep-working-in-another-app). The regular tools are unchanged.

**Background status, 2026-10-09:** without activating Freeform or taking keyboard focus, probes can create and rename a board, import a multi-object diagram (including onto an empty canvas), and insert, move, resize and relabel objects. **Caveat:** Accessibility context menus, which import, readback and rename depend on, raise Freeform's window above the user's work even though Freeform doesn't activate. Raising the user's window again afterward restored the order in one test. Clipboard-free operations (toolbar and picker inserts, typing, moving, switching boards) keep Freeform's window hidden as well. Those hidden paths also cover 12 named fill colors and **native connectors that stay attached** when shapes move. The handoff tracks activation, window visibility and clipboard use as separate properties.

This repository contains the bridge, tests, import tools, fixtures, and research notes. Copied Apple binaries, lab runtime data, generated disassembly, logs, and build outputs are kept locally but excluded from Git. Historical evidence retains the paths where it was originally collected. The original research folder is preserved at `/Users/drewcarr/freeform-bridge-research`.

---

# Freeform JavaScript bridge feasibility

**Add Item intent test, 2026-10-09:** Shortcuts rejected both a Create Board → Add Item workflow and a minimal Add Item-only workflow with no supplied parameters as unsupported on this device. Neither ran or created objects. The public Create Board control imported successfully. Add Files to Board remains visible, but editable-shape import through it is unverified. [Live test results](direct-import/runtime-results.md#add-item-intent-import-test).

**Direct-import investigation, 2026-10-09:** Hidden import/export utility operations are unimplemented in the shipped Mac binary. A separate real QA importer is behind an internal-OS check and the FileImportExport feature gate. Shortcuts rejected the hidden read-only probe while importing the public Create Board control with the same packaging. [Static trace](direct-import-static.md) · [Live test results](direct-import/runtime-results.md).

**Regular-app and sync update, 2026-10-09:** The full regular-app MCP workflow now passes: create/name, insert five editable shapes, verify contents, move, Undo/readback, and stale-target rejection. Menu-tracking failures were addressed by issuing validated keyboard commands without opening Edit. Clipboard writes made by the bridge are Mac-only; Freeform's own Copy is not covered by that guarantee. The user previously confirmed test boards and generated shapes reached their iPhone; iPad and this latest test's delivery remain unverified. See [current test status](bridge/README.md#current-regular-app-test-status).

**Native MCP integration, 2026-10-09:** The MCP server now discovers open boards and existing objects by persistent UUID, reads their geometry, and moves objects through Freeform's native command system without a preliminary edit. Live MCP, Undo/Redo, restart persistence, stale-geometry rejection, and cross-board targeting checks passed. This backend operates only in the isolated lab copy. [Run instructions](inprocess/LIVE-EDIT.md) · [MCP configuration](bridge/mcp-config.native.example.json).

**Working bridge, 2026-10-09:** [JavaScript API and MCP server](bridge/README.md) now generate and insert labeled shapes and arrows from scratch, verify readback, and inspect selections. The full live MCP test passed with five editable objects; 14 automated tests passed. The resulting board is **JavaScript Diagram Demo**. See the bridge README for launch/configuration and current limits.

**Runtime update, 2026-10-09:** The decisive JSON-only clipboard test passed. A Node script changed a shape's fill color, and Freeform imported it as a native vector shape. Copy-back verified the color/path; Undo and Redo worked. Placement offsets and loss of the preset radius handle were observed. See [experiment results](experiment/RESULTS.md). The sections below preserve the initial feasibility investigation and its then-unverified findings.

Inspected 2026-10-09 on macOS 27.0 (26A428), Freeform 5.0 (656.1.2). Actual installation: `/System/Applications/Freeform.app`; no app exists at `/Applications/Freeform.app` on this machine.

An external JavaScript service wrapping Freeform is feasible for limited board operations. A full object-level API remains an unproven but promising reverse-engineering project. No existing embedded JavaScript board API was found.

## What a user could do

The first version could expose commands to create, open, rename, and add files to boards through dedicated Shortcuts workflows. More ambitious commands such as creating precisely positioned editable shapes require further validation of the structured clipboard route. Reading every object and updating one by stable ID are not established capabilities.

| Route | Evidence | Assessment |
|---|---|---|
| Shortcuts/App Intents | Five actions visible in live picker; host CLI lists workflows successfully | Best initial integration; no Freeform action executed in this investigation |
| Structured JSON clipboard | Native bidirectional content-language import/export code and versioned model framework | Best object-level reverse-engineering lead; actual payload acceptance untested |
| Accessibility | Live canvas, toolbar, menus and insertion controls readable | UI fallback; arbitrary object selection/geometry editing untested |
| Hidden utility intent | Declared importBoard/exportBoard/manipulate operations with string arguments | Potentially powerful; argument grammar and external invocation unknown |
| AppleScript/JXA document API | No dictionary found | No useful board object model discovered |
| Inject JavaScript into Freeform | Native executable; platform signing and library validation | Poor foundation for a normal installable integration |
| Direct database writes | Coherence CRDT/CloudKit model | Not recommended; would bypass app model and merge behavior |

## Runtime checks versus bundle evidence

The live Shortcuts editor search for Freeform showed exactly **Create Board, Delete Boards, Open Board, Rename Board, Add Files to Board**. The full list fit without scrolling. An existing empty shortcut was opened only to inspect its action catalog, then closed; no action was added or run.

The app ships metadata for 24 intents. Richer insertion actions and selection styling exist in that metadata but were not visible in the picker. Several declare a `Freeform/AppIntents` capability requirement. This discrepancy does not establish its cause: flags, deprecation, platform restrictions, or registration may affect availability.

`/System/Library/FeatureFlags/Domain/Freeform.plist` declares both `AppIntents` and `ContentLanguageCopyPaste` with `DevelopmentPhase = FeatureComplete`. That is not proof of the effective runtime flag value. No flag was changed.

Freeform's live accessibility tree exposed an empty canvas and buttons for text, shapes, sticky notes, tables, media, sharing, and new boards. This verifies readable controls, not successful creation or an exhaustive object API.

## Recommended bridge design

```text
MCP client
    → Node/TypeScript server with typed, validated commands
        → installed Shortcuts workflows for board operations
        → small native helper for typed clipboard data (experimental)
        → macOS Accessibility for targeted UI operations and verification
```

The Node layer should call `/usr/bin/shortcuts` with argument arrays, not shell interpolation. The CLI invokes installed shortcut names/IDs, not arbitrary App Intent identifiers. Dedicated workflows would parse input and return structured output. Use private temporary input/output files and explicit timeouts; do not automatically retry a create/add command if its result is ambiguous.

A standalone helper would need its own applicable macOS automation/accessibility permissions. This investigation's working CUA access does not grant those permissions to a future helper. Clipboard operations should be serialized and preserve existing contents when safe, without overwriting a new clipboard value copied by the user during the operation.

Apple documents CLI input/output and notes that workflows asking for input pause execution: [Run shortcuts from the command line](https://support.apple.com/en-gb/guide/shortcuts-mac/-apd455c82f02/mac).

## Next proof needed before claiming full board automation

1. On a disposable test board, copy one native shape, text box, sticky note, and connector; inspect the typed clipboard representations and determine whether content-language JSON is emitted.
2. Decode and repaste unchanged JSON, then change one property and verify that the result remains a native editable object. Record required fields, version, asset handling, and placement behavior.
3. Run one dedicated board workflow from Node and read back the resulting board identity. Verify that updates target the intended board when multiple boards are open.
4. Test object discovery and replacement separately. Inserting a new object does not prove updating an existing one or preserving connector relationships.
5. If structured clipboard is unavailable, investigate the hidden utility intent's `manipulate` parser before considering native runtime instrumentation.

This was a feasibility investigation. No bridge/MCP server was installed, no board was created or edited, and no private intent was invoked. It establishes available entry points and the next experiments, not end-to-end execution.

## Detailed evidence

- [Automation inventory and intent contracts](automation.md)
- [Native runtime, signing, and WebKit findings](runtime.md)
- [Clipboard, content-language, and board format findings](formats.md)
- [Extracted intent metadata](app-intents.json)

Raw symbol/string files alongside these notes derive from the installed app bundle, not personal board contents.
