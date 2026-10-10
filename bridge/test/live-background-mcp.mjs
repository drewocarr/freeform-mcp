// Opt-in live test of the background tools through a real stdio MCP client.
// Usage (with another app frontmost): node test/live-background-mcp.mjs 'Unique Disposable Title' [evidence.json] ['Existing empty board to rename']
// Creates the board, builds a small flowchart, edits it, and stops on the first failure.
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const [title, evidencePath] = process.argv.slice(2);
if (!title) throw new Error('Pass a unique disposable board title');
const client = new Client({ name: 'freeform-background-live-test', version: '1.0.0' });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('../src/server.mjs', import.meta.url))] }));
const steps = [];
async function call(name, args) {
  const started = Date.now();
  const response = await client.callTool({ name, arguments: args });
  const value = response.structuredContent ?? {};
  const { imageBase64, ...rest } = value;
  steps.push({ tool: name, ms: Date.now() - started, ok: !response.isError, background: value.background, error: response.isError ? response.content?.[0]?.text : undefined });
  console.log(`${response.isError ? 'FAIL' : 'ok  '} ${name} ${JSON.stringify(value.background ?? {})}${response.isError ? ' ' + response.content?.[0]?.text : ''}`);
  if (response.isError) throw new Error(`${name} failed`);
  return rest;
}
const find = (list, prefix) => {
  const matches = list.objects.filter(o => o.description.startsWith(prefix));
  if (matches.length !== 1) throw new Error(`Expected one object starting with ${prefix}; found ${matches.length}`);
  return { objectIndex: matches[0].objectIndex, expectedDescription: matches[0].description };
};
try {
  await call('freeform_bg_status', {});
  const fromTitle = process.argv[4];
  // Optional third argument: rename an existing empty board instead of creating one.
  await call(fromTitle ? 'freeform_bg_rename_board' : 'freeform_bg_create_board', fromTitle ? { fromTitle, title, allowWindowRaise: true } : { title, allowWindowRaise: true });
  const board = { expectedBoardTitle: title };
  await call('freeform_bg_add_shape', { ...board, shape: 'roundedRectangle', x: 150, y: 150, width: 180, height: 80, text: 'Start', fill: 'teal' });
  await call('freeform_bg_add_shape', { ...board, shape: 'square', x: 450, y: 150, width: 180, height: 80, text: 'Process', fill: 'blue' });
  let last = await call('freeform_bg_add_shape', { ...board, shape: 'circle', x: 470, y: 380, text: 'Done', fill: 'green' });
  let list = await call('freeform_bg_list_objects', board);
  last = await call('freeform_bg_connect', { ...board, expectedSnapshot: list.snapshotToken, from: find(list, 'Start'), to: find(list, 'Process'), style: 'straight' });
  list = await call('freeform_bg_list_objects', board);
  last = await call('freeform_bg_connect', { ...board, expectedSnapshot: list.snapshotToken, from: find(list, 'Process'), to: find(list, 'Done'),
    style: 'straight', arrowhead: 'filled', allowWindowRaise: true });
  list = await call('freeform_bg_list_objects', board);
  last = await call('freeform_bg_update_object', { ...board, expectedSnapshot: list.snapshotToken, ...find(list, 'Done'), width: 150, height: 150, text: 'Finished', fill: 'orange' });
  await call('freeform_bg_add_shape', { ...board, shape: 'textBox', x: 150, y: 420, text: 'Built in the background' });
  list = await call('freeform_bg_list_objects', board);
  const shot = await client.callTool({ name: 'freeform_bg_screenshot', arguments: board });
  steps.push({ tool: 'freeform_bg_screenshot', ok: !shot.isError, background: shot.structuredContent?.background });
  const image = shot.content?.find(item => item.type === 'image')?.data;
  if (image && evidencePath) await writeFile(evidencePath.replace(/\.json$/, '.png'), Buffer.from(image, 'base64'));
  console.log(`${shot.isError ? 'FAIL' : 'ok  '} freeform_bg_screenshot ${JSON.stringify(shot.structuredContent?.background ?? {})}`);
  const summary = { title, passed: true, objects: list.objects.map(o => o.description), steps };
  if (evidencePath) await writeFile(evidencePath, JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary.objects, null, 2));
} catch (error) {
  if (evidencePath) await writeFile(evidencePath, JSON.stringify({ title, passed: false, error: error.message, steps }, null, 2));
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await client.close();
}
