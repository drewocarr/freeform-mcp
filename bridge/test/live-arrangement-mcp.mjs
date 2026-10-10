// Opt-in: creates a disposable board. Stops after any failed mutation; never retries.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
const title = process.argv[2];
if (!title) throw new Error('Supply a unique disposable board title');
const evidence = { title, startedAt: new Date().toISOString(), steps: [] };
const client = new Client({ name: 'freeform-arrangement-live-test', version: '1.0.0' });
const transport = new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('../src/server.mjs', import.meta.url))], stderr: 'pipe' });
const path = new URL('../examples/arrangement-mcp-proof.json', import.meta.url);
async function call(name, args) {
  const result = await client.callTool({ name, arguments: args });
  const value = result.structuredContent;
  evidence.steps.push({ name, args, result: value ?? result.content });
  await writeFile(path, JSON.stringify(evidence, null, 2) + '\n');
  if (result.isError) throw new Error(result.content.find(x => x.type === 'text')?.text ?? 'Tool failed');
  return { value, result };
}
async function state() { return (await call('freeform_list_objects', { expectedBoardTitle: title })).value; }
async function arrange(action, indices) {
  const current = await state();
  return (await call(['group', 'ungroup'].includes(action) ? 'freeform_group_objects' : 'freeform_align_objects', {
    expectedBoardTitle: title, expectedSnapshot: current.snapshotToken, action,
    targets: indices.map(index => ({ objectIndex: index, expectedDescription: current.objects[index].description })),
  })).value;
}
try {
  await client.connect(transport);
  await call('freeform_create_board', { title });
  await call('freeform_insert_objects', { expectedBoardTitle: title, objects: [
    { shape: 'rectangle', x: 0, y: 0, width: 100, height: 60, text: 'Align A', fill: '#3377cc' },
    { shape: 'rectangle', x: 180, y: 90, width: 140, height: 80, text: 'Align B', fill: '#cc7733' },
    { shape: 'ellipse', x: 400, y: 180, width: 120, height: 100, text: 'Align C', fill: '#559955' },
    { shape: 'rectangle', x: 700, y: 400, width: 150, height: 60, text: 'Untouched', fill: '#996699' },
  ] });
  const shot = await call('freeform_screenshot', { expectedBoardTitle: title });
  const image = shot.result.content.find(x => x.type === 'image');
  assert.ok(image); assert.equal(shot.value.clipboardUsed, false);
  await writeFile(new URL('../examples/arrangement-screenshot.png', import.meta.url), Buffer.from(image.data, 'base64'));
  const initial = await state();
  const targets = initial.objects.filter(x => x.description.includes('Align ')).map(x => x.objectIndex);
  assert.equal(targets.length, 3);
  const grouped = await arrange('group', targets);
  assert.equal(grouped.verification.geometry, true); assert.equal(grouped.clipboardRestored, true);
  const group = grouped.objects.find(x => x.selected);
  assert.ok(group);
  const ungrouped = await arrange('ungroup', [group.objectIndex]);
  assert.equal(ungrouped.verification.geometry, true);
  for (const action of ['left', 'center', 'right', 'top', 'middle', 'bottom']) {
    const current = await state();
    const targets = current.objects.filter(x => x.description.includes('Align ')).map(x => x.objectIndex);
    const result = await arrange(action, targets);
    assert.equal(result.verification.geometry, true); assert.equal(result.clipboardRestored, true);
    await call('freeform_undo', { expectedBoardTitle: title });
  }
  const current = await state();
  const invalid = await client.callTool({ name: 'freeform_align_objects', arguments: {
    expectedBoardTitle: title, expectedSnapshot: '0'.repeat(64), action: 'left',
    targets: current.objects.slice(0, 2).map(x => ({ objectIndex: x.objectIndex, expectedDescription: x.description })),
  } });
  assert.equal(invalid.isError, true); assert.equal(invalid.structuredContent.mayHaveChanged, false);
  evidence.staleRejected = invalid.structuredContent;
  const wrong = await client.callTool({ name: 'freeform_screenshot', arguments: { expectedBoardTitle: title + ' WRONG' } });
  assert.equal(wrong.isError, true); evidence.wrongBoardRejected = true;
  evidence.passed = true;
} catch (error) { evidence.error = error.message; process.exitCode = 1; }
finally {
  await client.close();
  await writeFile(path, JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify({ title, passed: evidence.passed ?? false, error: evidence.error }));
}
