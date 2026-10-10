#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';
import { createNativeBridge } from './native-bridge.mjs';

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

export function createServer({ getStatus, insertObjects, readSelection, createBoard, openBoard, listObjects, moveObject, undo, screenshot, arrangeObjects }, native = createNativeBridge()) {
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
  return server;
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
