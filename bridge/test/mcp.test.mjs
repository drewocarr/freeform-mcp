import assert from 'node:assert/strict';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { InMemoryTransport } from '@modelcontextprotocol/server';
import { createServer } from '../src/server.mjs';

async function harness(t, overrides = {}) {
  const calls = [];
  const bridge = {
    getStatus: async () => ({ available: true }),
    insertObjects: async (args) => { calls.push(args); return { inserted: args.objects.length }; },
    readSelection: async (args) => ({ title: args.expectedBoardTitle, objects: [] }),
    ...overrides,
  };
  const server = createServer(bridge);
  const client = new Client({ name: 'freeform-protocol-test', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  t.after(async () => { await client.close(); await server.close(); });
  return { client, calls };
}

const valid = {
  expectedBoardTitle: 'Bridge test',
  objects: [{ shape: 'rectangle', x: 0, y: 0, width: 200, height: 100, fill: '#abcdef', text: 'Hello' }],
};

test('MCP advertises the clipboard and native lab tools and their mutation behavior', async (t) => {
  const { client } = await harness(t);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(tool => tool.name).sort(), ['freeform_create_board', 'freeform_insert_objects', 'freeform_list_objects', 'freeform_move_object', 'freeform_native_list_boards', 'freeform_native_list_objects', 'freeform_native_move_object', 'freeform_native_status', 'freeform_open_board', 'freeform_read_selection', 'freeform_status', 'freeform_undo']);
  const insertion = tools.find(tool => tool.name === 'freeform_insert_objects');
  assert.equal(insertion.annotations.readOnlyHint, false);
  assert.equal(insertion.annotations.destructiveHint, false);
  assert.equal(insertion.annotations.idempotentHint, false);
  assert.equal(insertion.inputSchema.additionalProperties, false);
  assert.equal(insertion.inputSchema.properties.objects.items.additionalProperties, false);
});

test('validated insertion reaches bridge and returns structured output', async (t) => {
  const { client, calls } = await harness(t);
  const response = await client.callTool({ name: 'freeform_insert_objects', arguments: valid });
  assert.deepEqual(response.structuredContent, { inserted: 1 });
  assert.deepEqual(calls, [valid]);
});

test('invalid and unknown fields fail before any insertion', async (t) => {
  const { client, calls } = await harness(t);
  for (const args of [
    { ...valid, expectedBoardTitle: '' },
    { ...valid, unexpected: 'field' },
    { ...valid, objects: [] },
    { ...valid, objects: [{ ...valid.objects[0], width: -1 }] },
    { ...valid, objects: [{ ...valid.objects[0], fill: 'red' }] },
    { ...valid, objects: [{ ...valid.objects[0], shape: 'connector' }] },
    { ...valid, objects: [{ ...valid.objects[0], surprise: true }] },
    { ...valid, objects: Array.from({ length: 101 }, () => valid.objects[0]) },
  ]) {
    const response = await client.callTool({ name: 'freeform_insert_objects', arguments: args });
    assert.equal(response.isError, true);
  }
  assert.deepEqual(calls, []);
});

test('native failures return tool errors rather than successful results', async (t) => {
  const { client } = await harness(t, { readSelection: async () => { throw new Error('Wrong board'); } });
  const response = await client.callTool({ name: 'freeform_read_selection', arguments: { expectedBoardTitle: 'Board' } });
  assert.equal(response.isError, true);
  assert.equal(response.content[0].text, 'Wrong board');
});

test('real stdio entry point initializes and lists tools without touching Freeform', async (t) => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('../src/server.mjs', import.meta.url))],
    stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr?.on('data', chunk => { stderr += chunk; });
  const client = new Client({ name: 'freeform-stdio-smoke', version: '1.0.0' });
  t.after(async () => { await client.close(); });
  await client.connect(transport);
  assert.equal((await client.listTools()).tools.length, 12);
  assert.equal(stderr, '');
});

 test('unconfigured native status is explicit and native moves require stale-state precondition', async t => {
  const { client } = await harness(t);
  const response = await client.callTool({ name: 'freeform_native_status', arguments: {} });
  assert.equal(response.structuredContent.configured, false);
  const move = await client.callTool({ name: 'freeform_native_move_object', arguments: { boardId: 'b', objectId: 'o', x: 10, y: 20 } });
  assert.equal(move.isError, true);
});

test('regular app commands preserve targets and expose non-retryable mutations', async t => {
  const received = [];
  const operations = Object.fromEntries(['createBoard', 'openBoard', 'listObjects', 'moveObject', 'undo'].map(name => [name, async args => { received.push({ name, args }); return { ok: true }; }]));
  const { client } = await harness(t, operations);
  const requests = [
    ['freeform_create_board', { title: 'Disposable board' }],
    ['freeform_open_board', { title: 'Disposable board' }],
    ['freeform_list_objects', { expectedBoardTitle: 'Disposable board' }],
    ['freeform_move_object', { expectedBoardTitle: 'Disposable board', objectIndex: 0, expectedDescription: 'Blue rectangle', dx: 10, dy: -5 }],
    ['freeform_undo', { expectedBoardTitle: 'Disposable board' }],
  ];
  for (const [name, args] of requests) {
    const response = await client.callTool({ name, arguments: args });
    assert.equal(response.isError, undefined);
    assert.deepEqual(response.structuredContent, { ok: true });
  }
  assert.deepEqual(received.map(call => call.args), requests.map(request => request[1]));
  const { tools } = await client.listTools();
  for (const name of ['freeform_create_board', 'freeform_move_object', 'freeform_undo']) {
    assert.equal(tools.find(tool => tool.name === name).annotations.idempotentHint, false);
  }
});

test('unsafe regular movement inputs are rejected before dispatch', async t => {
  const calls = [];
  const { client } = await harness(t, { moveObject: async args => { calls.push(args); return {}; } });
  const args = { expectedBoardTitle: 'Board', objectIndex: 0, expectedDescription: 'Rectangle', dx: 1, dy: 0 };
  for (const invalid of [
    { ...args, objectIndex: -1 }, { ...args, objectIndex: 1.5 },
    { ...args, expectedDescription: '' }, { ...args, expectedDescription: ' ' },
    { ...args, expectedBoardTitle: ' ' }, { ...args, dx: 101 },
    { ...args, dy: -101 }, { ...args, dx: 0.5 }, { ...args, dx: 0 },
    { ...args, unexpected: true },
  ]) {
    const response = await client.callTool({ name: 'freeform_move_object', arguments: invalid });
    assert.equal(response.isError, true);
  }
  assert.deepEqual(calls, []);
});


test('partial insertion errors retain non-retryable outcome details for MCP clients', async t => {
  const nativeResult = { ok: false, error: 'INSERT_UNVERIFIED', mayHaveInserted: true, clipboardRestored: false, retryAutomatically: false };
  let attempts = 0;
  const { client } = await harness(t, { insertObjects: async () => {
    attempts++;
    throw Object.assign(new Error('Inspect the board before retrying.'), { nativeResult });
  } });
  const response = await client.callTool({ name: 'freeform_insert_objects', arguments: valid });
  assert.equal(response.isError, true);
  assert.deepEqual(response.structuredContent, nativeResult);
  assert.equal(attempts, 1);
});
