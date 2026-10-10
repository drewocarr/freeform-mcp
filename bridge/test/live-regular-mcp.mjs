// Opt-in: creates a board (with --create), inserts five shapes and tests one move/Undo.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const [title, mode] = process.argv.slice(2);
if (!title) throw new Error('Supply an exact disposable board title and optionally --create. Never automatically retry this test.');
const evidence = { title, startedAt: new Date().toISOString(), syncVerified: false };
const client = new Client({ name: 'regular-freeform-live-test', version: '1.0.0' });
async function call(name, args) {
  const response = await client.callTool({ name, arguments: args });
  assert.notEqual(response.isError, true, response.content?.[0]?.text);
  return response.structuredContent ?? JSON.parse(response.content[0].text);
}
try {
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('../src/server.mjs', import.meta.url))] }));
  if (mode === '--create') evidence.creation = await call('freeform_create_board', { title });
  else evidence.opening = await call('freeform_open_board', { title });
  const expectedBoardTitle = title;
  const initial = await call('freeform_list_objects', { expectedBoardTitle });
  assert.equal(initial.objects.length, 0, 'Test requires an empty disposable board; no insertion attempted.');
  const objects = JSON.parse(await readFile(new URL('../examples/diagram.json', import.meta.url)));
  evidence.insertion = await call('freeform_insert_objects', { expectedBoardTitle, objects });
  assert.equal(evidence.insertion.clipboardRestored, true);
  evidence.list = await call('freeform_list_objects', { expectedBoardTitle });
  assert.equal(evidence.list.objects.length, objects.length);
  const target = evidence.list.objects.find(object => object.description.startsWith('1. Describe a diagram,'));
  assert.ok(target);
  evidence.move = await call('freeform_move_object', { expectedBoardTitle, objectIndex: target.objectIndex, expectedDescription: target.description, dx: 1, dy: 0 });
  assert.equal(evidence.move.clipboardRestored, true);
  const before = evidence.move.before[0].geometry.position;
  const after = evidence.move.after[0].geometry.position;
  assert.equal(after.x, before.x + 1);
  assert.equal(after.y, before.y);
  evidence.undo = await call('freeform_undo', { expectedBoardTitle });
  evidence.readback = await call('freeform_read_selection', { expectedBoardTitle });
  assert.deepEqual(evidence.readback.objects[0].geometry, evidence.move.before[0].geometry);
  evidence.stale = await client.callTool({ name: 'freeform_move_object', arguments: { expectedBoardTitle, objectIndex: target.objectIndex, expectedDescription: 'deliberately incorrect', dx: 1, dy: 0 } });
  assert.equal(evidence.stale.isError, true);
  evidence.passed = true;
} catch (error) {
  evidence.error = error.message;
  process.exitCode = 1;
} finally {
  await client.close();
  await writeFile(new URL('../examples/regular-mcp-proof.json', import.meta.url), JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify({ title, passed: evidence.passed ?? false, error: evidence.error }));
}
