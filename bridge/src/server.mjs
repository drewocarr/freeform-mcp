#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';
import { createNativeBridge } from './native-bridge.mjs';
import { ARROWHEADS, CONNECTION_STYLES, SHAPES, SWATCHES, createBackgroundBridge } from './background.mjs';

const boardTitle = z.string().min(1).max(512)
  .describe('Exact title of the already open Freeform board. The bridge refuses to act on a different board.');
const color = z.string().regex(/^#[0-9a-fA-F]{6}$/);
const objectSchema = z.object({
  shape: z.enum(['rectangle', 'roundedRectangle', 'ellipse', 'arrow']),
  x: z.number().finite().min(-100000).max(100000),
  y: z.number().finite().min(-100000).max(100000),
  width: z.number().finite().positive().max(10000),
  height: z.number().finite().positive().max(10000),
  fill: color,
  text: z.string().max(10000).optional(),
  direction: z.enum(['right', 'left', 'up', 'down']).optional()
    .describe('Arrows only: which way the arrow points. Defaults to right.'),
}).strict();

function result(value) {
  if (value?.mimeType === 'image/png' && typeof value.imageBase64 === 'string') {
    const { imageBase64, ...metadata } = value;
    return { content: [{ type: 'image', mimeType: 'image/png', data: imageBase64 },
      { type: 'text', text: JSON.stringify(metadata) }], structuredContent: metadata };
  }
  return {
    content: [{ type: 'text', text: JSON.stringify(value ?? null) }],
    ...(value && typeof value === 'object' && !Array.isArray(value)
      ? { structuredContent: value } : {}),
  };
}

function handler(operation) {
  return async (args) => {
    try {
      return result(await operation(args));
    } catch (error) {
      return {
        isError: true,
        ...(error?.nativeResult ? { structuredContent: error.nativeResult } : {}),
        content: [{ type: 'text', text: error instanceof Error ? error.message : String(error) }],
      };
    }
  };
}

export function createServer({ getStatus, insertObjects, readSelection, createBoard, openBoard, listObjects, moveObject, undo, screenshot, arrangeObjects }, native = createNativeBridge(), background = createBackgroundBridge()) {
  const server = new McpServer({ name: 'freeform-js-bridge', version: '0.1.0' });
  server.registerTool('freeform_status', {
    description: 'Inspect Freeform availability, permissions, and the current board without changing board content.',
    inputSchema: z.object({}).strict(),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, handler(() => getStatus()));
  server.registerTool('freeform_insert_objects', {
    description: 'Insert editable vector shapes into the already open Freeform board. Coordinates define relative layout; Freeform chooses paste placement. Repeating this call adds duplicates. This does not update existing objects. Arrows are independent vector shapes, not attached connectors. Text and rounded-corner editing depend on the experimental clipboard format.',
    inputSchema: z.object({
      expectedBoardTitle: boardTitle,
      objects: z.array(objectSchema).min(1).max(100),
    }).strict(),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, handler(insertObjects));
  server.registerTool('freeform_read_selection', {
    description: 'Read the selected objects from the already open Freeform board by copying their structured representation. Does not change board content; temporarily uses the system clipboard.',
    inputSchema: z.object({ expectedBoardTitle: boardTitle }).strict(),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, handler(readSelection));
  const regularTitle = boardTitle.refine(value => value.trim().length > 0);
  const uiMutation = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };
  server.registerTool('freeform_create_board', {
    description: 'Create and name a board in the regular installed Freeform app through its UI. Normal Freeform iCloud settings govern syncing; success does not verify delivery to other devices. An interrupted call may have created a board: inspect before retrying.',
    inputSchema: z.object({ title: regularTitle }).strict(), annotations: uiMutation,
  }, handler(createBoard));
  server.registerTool('freeform_open_board', {
    description: 'Open a board by exact title in the regular installed Freeform app through its UI. Changes the visible app window. Use a unique title to avoid ambiguity.',
    inputSchema: z.object({ title: regularTitle }).strict(),
    annotations: { ...uiMutation, idempotentHint: true },
  }, handler(openBoard));
  server.registerTool('freeform_list_objects', {
    description: 'Inspect objects exposed by Accessibility on the already open regular Freeform board. Returned indices and descriptions refer to the current UI, not persistent object IDs. Includes snapshotToken for guarded grouping/alignment. Read again after edits, zooming, or scrolling before choosing an object.',
    inputSchema: z.object({ expectedBoardTitle: regularTitle }).strict(),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, handler(listObjects));
  server.registerTool('freeform_move_object', {
    description: 'Experimentally move an existing object in the regular Freeform app using selection and arrow keys. Requires its index and exact description from a recent freeform_list_objects result. dx/dy are signed keyboard nudge counts, not absolute model or screen coordinates. Changes selection and creates undo history. Never automatically retry: partial movement may have occurred; inspect the board first.',
    inputSchema: z.object({
      expectedBoardTitle: regularTitle,
      objectIndex: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
      expectedDescription: z.string().min(1).max(10000).refine(value => value.trim().length > 0),
      dx: z.number().int().min(-100).max(100),
      dy: z.number().int().min(-100).max(100),
    }).strict().refine(value => value.dx !== 0 || value.dy !== 0, 'At least one movement must be nonzero'),
    annotations: uiMutation,
  }, handler(moveObject));
  server.registerTool('freeform_undo', {
    description: 'Undo the most recent edit on the already open regular Freeform board through its UI. This may undo a user edit and is not restricted to bridge changes. One call performs one Undo; do not automatically repeat or retry.',
    inputSchema: z.object({ expectedBoardTitle: regularTitle }).strict(),
    annotations: { ...uiMutation, destructiveHint: true },
  }, handler(undo));
  server.registerTool('freeform_screenshot', {
    description: 'Capture only the exact open Freeform board window as a PNG image. Captures the current viewport including window controls, not the entire infinite board. Does not use the clipboard or change content. Requires existing Screen Recording permission; does not request it.',
    inputSchema: z.object({ expectedBoardTitle: regularTitle }).strict(),
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, handler(screenshot));
  const target = z.object({ objectIndex: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
    expectedDescription: z.string().min(1).max(10000).refine(s => s.trim().length > 0) }).strict();
  const arrangement = { expectedBoardTitle: regularTitle, expectedSnapshot: z.string().regex(/^[a-f0-9]{64}$/), targets: z.array(target).min(1).max(100) };
  const validTargets = args => new Set(args.targets.map(t => t.objectIndex)).size === args.targets.length;
  server.registerTool('freeform_group_objects', {
    description: 'Group 2–100 explicitly listed shapes, or ungroup one simple group. Requires snapshotToken and exact unique descriptions from a fresh freeform_list_objects. Refuses stale board layout, ambiguous targets, rotated/flipped shapes, and nested groups. Changes selection, temporarily uses/restores the clipboard, verifies content and positions, and creates undo history. Inspect after any error; never automatically retry.',
    inputSchema: z.object({ ...arrangement, action: z.enum(['group', 'ungroup']) }).strict()
      .refine(validTargets, 'Targets must be distinct').refine(a => a.action === 'ungroup' ? a.targets.length === 1 : a.targets.length >= 2, 'Grouping needs at least two objects; ungrouping needs one group'),
    annotations: uiMutation,
  }, handler(arrangeObjects));
  server.registerTool('freeform_align_objects', {
    description: 'Align 2–100 explicitly listed unrotated/unflipped shapes to left, center, right, top, middle, or bottom of their collective bounds. Requires snapshotToken and exact unique descriptions from a fresh freeform_list_objects. Refuses stale or ambiguous targets. Changes selection, temporarily uses/restores the clipboard, verifies content and geometry, and creates undo history. Inspect after any error; never automatically retry.',
    inputSchema: z.object({ ...arrangement, targets: z.array(target).min(2).max(100), action: z.enum(['left', 'center', 'right', 'top', 'middle', 'bottom']) }).strict().refine(validTargets, 'Targets must be distinct'),
    annotations: uiMutation,
  }, handler(arrangeObjects));
  const nativeId = z.string().min(1).max(512);
  const position = z.number().finite().min(-100000).max(100000);
  const geometry = z.object({ x: position, y: position, width: z.number().finite().positive(), height: z.number().finite().positive() }).strict();
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
  server.registerTool('freeform_native_status', {
    description: 'Inspect the explicitly configured isolated Freeform lab session. Reports unconfigured when FREEFORM_NATIVE_SESSION_FILE is absent. Never connects to the installed Freeform app.',
    inputSchema: z.object({}).strict(), annotations: readOnly,
  }, handler(() => native.getStatus()));
  server.registerTool('freeform_native_list_boards', {
    description: 'List boards currently discoverable in the isolated Freeform lab process, with persistent model UUIDs. Only open boards are discoverable; this does not enumerate all saved boards or open them.',
    inputSchema: z.object({}).strict(), annotations: readOnly,
  }, handler(() => native.listBoards()));
  server.registerTool('freeform_native_list_objects', {
    description: 'Inspect objects on a discoverable isolated lab board. Use returned IDs and geometry for an explicit move; UUIDs persist across restarts; list boards again to verify the target is currently open.',
    inputSchema: z.object({ boardId: nativeId }).strict(), annotations: readOnly,
  }, handler(args => native.listObjects(args)));
  server.registerTool('freeform_native_move_object', {
    description: 'Move one existing object on an isolated lab board to absolute model geometry coordinates (not screen pixels) through Freeform native commands. Requires geometry from a recent read; stale or unsupported objects are rejected. Creates undo history. A timeout has unknown outcome: inspect before retrying.',
    inputSchema: z.object({ boardId: nativeId, objectId: nativeId, x: position, y: position, expectedGeometry: geometry }).strict(),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, handler(args => native.moveObject(args)));
  registerBackgroundTools(server, background);
  return server;
}

// Background tools act on the regular Freeform app while another app stays frontmost.
function registerBackgroundTools(server, background) {
  const guarantees = 'Never activates Freeform or takes keyboard focus; refuses to run if Freeform is frontmost, with no foreground fallback. Results report background.activated, background.windowRaised, background.windowRestored, and background.clipboardUsed.';
  const title = z.string().min(1).max(512).describe('Exact title of the board open in Freeform\'s focused window.');
  const snapshot = z.string().regex(/^[a-f0-9]{64}$/).describe('snapshotToken from freeform_bg_list_objects or the previous background edit.');
  const index = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
  const description = z.string().min(1).max(10000).refine(value => value.trim().length > 0);
  const target = z.object({ objectIndex: index, expectedDescription: description }).strict();
  const coordinate = z.number().finite().min(-100000).max(100000).describe('Points from the top-left of the visible canvas at the current zoom and scroll.');
  const size = z.number().finite().min(10).max(10000);
  const text = z.string().min(1).max(1000).regex(/^[^\u0000-\u001f\u007f]*$/, 'No newlines or control characters');
  const fill = z.enum(SWATCHES).describe('One of Freeform\'s named swatches. Custom colors are not available in the background.');
  const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
  const mutation = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };
  server.registerTool('freeform_bg_status', {
    description: 'Report whether background editing is possible: Freeform running, Accessibility trust, the frontmost app, and the focused board. Does not change anything.',
    inputSchema: z.object({}).strict(), annotations: readOnly,
  }, handler(() => background.getStatus()));
  server.registerTool('freeform_bg_wake', {
    description: 'Make Freeform\'s board canvas available to the background tools after Freeform was launched in the background (they report CANVAS_NOT_READY). Briefly activates Freeform (about half a second, until the canvas exists), then reactivates the app you were using. Does nothing if the canvas or library is already available. Requires allowActivation true. Results report background.activated and background.wokeWithActivationSeconds.',
    inputSchema: z.object({ allowActivation: z.literal(true) }).strict(), annotations: { ...mutation, idempotentHint: true },
  }, handler(args => background.wake(args)));
  server.registerTool('freeform_bg_list_objects', {
    description: `List objects on the board with temporary indices, Accessibility descriptions, and frames in visible-canvas coordinates, plus a snapshotToken for edits. Read-only. ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title }).strict(), annotations: readOnly,
  }, handler(args => background.listObjects(args)));
  server.registerTool('freeform_bg_screenshot', {
    description: `Capture the Freeform board window as a PNG without bringing it forward. Requires Screen Recording permission. ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title }).strict(), annotations: readOnly,
  }, handler(args => background.screenshot(args)));
  server.registerTool('freeform_bg_open_board', {
    description: `Switch Freeform to a board by exact title through its library, keeping its window hidden. ${guarantees}`,
    inputSchema: z.object({ title }).strict(), annotations: { ...mutation, idempotentHint: true },
  }, handler(args => background.openBoard(args)));
  server.registerTool('freeform_bg_create_board', {
    description: `Create and name a board. Naming uses the board card's context menu, which raises Freeform's window briefly; allowWindowRaise must be true, and the window order is restored afterward. An error may follow a created board: inspect before retrying. ${guarantees}`,
    inputSchema: z.object({ title, allowWindowRaise: z.literal(true) }).strict(), annotations: mutation,
  }, handler(args => background.createBoard(args)));
  server.registerTool('freeform_bg_rename_board', {
    description: `Rename a board by exact current title through its library card's context menu, which raises Freeform's window briefly; allowWindowRaise must be true, and the window order is restored. Reopens the board afterward. ${guarantees}`,
    inputSchema: z.object({ fromTitle: title, title, allowWindowRaise: z.literal(true) }).strict(), annotations: mutation,
  }, handler(args => background.renameBoard(args)));
  server.registerTool('freeform_bg_add_shape', {
    description: `Add one native object without the clipboard: a picker shape (optionally sized, positioned, labeled, and filled with a named swatch), a text box, or a sticky note. Resizing briefly lifts Freeform's window just below the frontmost window. Repeating adds duplicates; on error, inspect before retrying. ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title, shape: z.enum(SHAPES), x: coordinate.optional(), y: coordinate.optional(),
      width: size.optional(), height: size.optional(), text: text.optional(), fill: fill.optional() }).strict(),
    annotations: mutation,
  }, handler(args => background.addShape(args)));
  server.registerTool('freeform_bg_update_object', {
    description: `Move, resize, relabel, or recolor one existing object, or restyle a connection line, without the clipboard. Requires a fresh snapshotToken and the object's index and exact description. Setting an arrowhead raises the window (allowWindowRaise required; order restored). ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title, expectedSnapshot: snapshot, objectIndex: index, expectedDescription: description,
      x: coordinate.optional(), y: coordinate.optional(), width: size.optional(), height: size.optional(), text: text.optional(), fill: fill.optional(),
      style: z.enum(CONNECTION_STYLES).optional().describe('Connection lines only.'),
      arrowhead: z.enum(ARROWHEADS.filter(a => a !== 'none')).optional().describe('Connection lines only; raises the window, so requires allowWindowRaise.'),
      allowWindowRaise: z.boolean().optional() }).strict()
      .refine(a => ['x', 'y', 'width', 'height', 'text', 'fill', 'style', 'arrowhead'].some(key => a[key] !== undefined), 'Provide at least one change')
      .refine(a => a.arrowhead === undefined || a.allowWindowRaise === true, 'Arrowheads require allowWindowRaise: true'),
    annotations: mutation,
  }, handler(args => background.updateObject(args)));
  server.registerTool('freeform_bg_connect', {
    description: `Connect two objects with a native Connection Line that stays attached when they move. Straight, corner, or curved style keep Freeform hidden. Arrowheads use a pop-up menu that raises the window: they require allowWindowRaise true, and the window order is restored. ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title, expectedSnapshot: snapshot, from: target, to: target,
      style: z.enum(CONNECTION_STYLES).optional(), arrowhead: z.enum(ARROWHEADS).optional(), allowWindowRaise: z.boolean().optional() }).strict()
      .refine(a => a.from.objectIndex !== a.to.objectIndex, 'from and to must differ')
      .refine(a => (a.arrowhead ?? 'none') === 'none' || a.allowWindowRaise === true, 'Arrowheads require allowWindowRaise: true'),
    annotations: mutation,
  }, handler(args => background.connect(args)));
  server.registerTool('freeform_bg_delete_object', {
    description: `Delete one object, identified by a fresh snapshotToken plus its index and exact description. ${guarantees}`,
    inputSchema: z.object({ expectedBoardTitle: title, expectedSnapshot: snapshot, objectIndex: index, expectedDescription: description }).strict(),
    annotations: { ...mutation, destructiveHint: true },
  }, handler(args => background.deleteObject(args)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const bridge = await import('./bridge.mjs');
    await createServer(bridge).connect(new StdioServerTransport());
  } catch (error) {
    console.error(`Freeform MCP failed to start: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
