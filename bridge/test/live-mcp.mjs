// Opt-in integration test. This INSERTS objects into the supplied open board.
// Usage: node test/live-mcp.mjs 'Exact Board Title' examples/diagram.json
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { verifyImportedObjects } from '../src/verify.mjs';

const [expectedBoardTitle, objectsFile] = process.argv.slice(2);
if (!expectedBoardTitle || !objectsFile) {
  console.error('Usage: node test/live-mcp.mjs "Exact Board Title" objects.json\nThis test inserts objects. Do not retry automatically after a failure.');
  process.exit(2);
}
const objects = JSON.parse(await readFile(objectsFile, 'utf8'));
assert.ok(Array.isArray(objects) && objects.length > 0, 'Input must be a nonempty object array');
const client = new Client({ name: 'freeform-live-integration', version: '1.0.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [fileURLToPath(new URL('../src/server.mjs', import.meta.url))],
  stderr: 'inherit',
});
function verify(result) {
  assert.equal(result.ok, true);
  assert.equal(result.boardTitle, expectedBoardTitle);
  assert.equal(result.clipboardRestored, true, 'Clipboard was not restored');
  assert.equal(result.selectedObjectCount, objects.length);
  assert.equal(result.objects.length, objects.length);
  verifyImportedObjects(objects, result.objects);
}
async function call(name, args) {
  const response = await client.callTool({ name, arguments: args });
  assert.notEqual(response.isError, true, response.content?.[0]?.text);
  return response.structuredContent ?? JSON.parse(response.content[0].text);
}
try {
  await client.connect(transport);
  const status = await call('freeform_status', {});
  assert.equal(status.accessibilityTrusted, true, 'Accessibility permission required');
  assert.equal(status.boardTitle, expectedBoardTitle, 'Open the intended board first');
  const insertion = await call('freeform_insert_objects', { expectedBoardTitle, objects });
  verify(insertion);
  assert.equal(insertion.inserted, true);
  assert.equal(insertion.insertedCount, objects.length);
  const selection = await call('freeform_read_selection', { expectedBoardTitle });
  verify(selection);
  const destination = new URL('../examples/live-mcp-result.json', import.meta.url);
  await writeFile(destination, JSON.stringify({ verifiedAt: new Date().toISOString(), expectedBoardTitle, status, insertion, selection }, null, 2) + '\n');
  console.log(`Verified ${objects.length} editable shapes and their labels through MCP. Results: ${fileURLToPath(destination)}`);
} catch (error) {
  console.error(`Live MCP verification failed: ${error.message}\nInspect the board before retrying; insertion may have completed.`);
  process.exitCode = 1;
} finally {
  await client.close();
}
