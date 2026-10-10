import assert from 'node:assert/strict';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/client';
import { InMemoryTransport } from '@modelcontextprotocol/server';
import { createBackgroundBridge } from '../src/background.mjs';
import { createServer } from '../src/server.mjs';

const snapshot = 'a'.repeat(64);
function recording() {
  const requests = [];
  const bridge = createBackgroundBridge({ run: async request => { requests.push(request); return { ok: true, echo: request.command }; } });
  return { bridge, requests };
}

test('background requests are validated and compacted before reaching the helper', async () => {
  const { bridge, requests } = recording();
  await bridge.addShape({ expectedBoardTitle: 'Board', shape: 'roundedRectangle', x: 10, y: 20, text: 'Start', fill: 'teal' });
  await bridge.connect({ expectedBoardTitle: 'Board', expectedSnapshot: snapshot,
    from: { objectIndex: 0, expectedDescription: 'Start, Shape' }, to: { objectIndex: 1, expectedDescription: 'End, Shape' } });
  assert.deepEqual(requests, [
    { command: 'addShape', expectedBoardTitle: 'Board', shape: 'roundedRectangle', x: 10, y: 20, text: 'Start', fill: 'teal' },
    { command: 'connect', expectedBoardTitle: 'Board', expectedSnapshot: snapshot, from: { objectIndex: 0, expectedDescription: 'Start, Shape' },
      to: { objectIndex: 1, expectedDescription: 'End, Shape' }, style: 'straight', arrowhead: 'none', allowWindowRaise: false },
  ]);
});

test('background rejects inputs that would raise the window without consent or cannot be typed', () => {
  const { bridge, requests } = recording();
  const base = { expectedBoardTitle: 'Board', expectedSnapshot: snapshot, from: { objectIndex: 0, expectedDescription: 'A' }, to: { objectIndex: 1, expectedDescription: 'B' } };
  assert.throws(() => bridge.connect({ ...base, arrowhead: 'filled' }), /allowWindowRaise/);
  assert.throws(() => bridge.connect({ ...base, to: base.from }), /different/);
  assert.throws(() => bridge.createBoard({ title: 'New' }), /allowWindowRaise/);
  assert.throws(() => bridge.addShape({ expectedBoardTitle: 'Board', shape: 'square', text: 'two\nlines' }), /control/);
  assert.throws(() => bridge.addShape({ expectedBoardTitle: 'Board', shape: 'square', fill: '#ff0000' }), /swatch/);
  assert.throws(() => bridge.addShape({ expectedBoardTitle: 'Board', shape: 'textBox', fill: 'red' }), /shapes/);
  assert.throws(() => bridge.addShape({ expectedBoardTitle: 'Board', shape: 'hexagon' }), /shape must be/);
  assert.throws(() => bridge.addShape({ expectedBoardTitle: 'Board', shape: 'square', width: 5 }), /width/);
  assert.throws(() => bridge.updateObject({ expectedBoardTitle: 'Board', expectedSnapshot: snapshot, objectIndex: 0, expectedDescription: 'A' }), /at least one/);
  assert.throws(() => bridge.updateObject({ expectedBoardTitle: 'Board', expectedSnapshot: 'stale', objectIndex: 0, expectedDescription: 'A', x: 1 }), /snapshotToken/);
  assert.throws(() => bridge.updateObject({ expectedBoardTitle: 'Board', expectedSnapshot: snapshot, objectIndex: 0, expectedDescription: 'A', arrowhead: 'filled' }), /allowWindowRaise/);
  assert.equal(requests.length, 0);
});

test('background MCP tools validate schemas and pass arguments through', async (t) => {
  const { bridge, requests } = recording();
  const server = createServer({}, undefined, bridge);
  const client = new Client({ name: 'freeform-background-test', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  t.after(async () => { await client.close(); await server.close(); });
  const { tools } = await client.listTools();
  const connect = tools.find(tool => tool.name === 'freeform_bg_connect');
  assert.equal(connect.annotations.readOnlyHint, false);
  assert.match(connect.description, /Never activates Freeform/);
  assert.equal(tools.find(tool => tool.name === 'freeform_bg_delete_object').annotations.destructiveHint, true);

  const ok = await client.callTool({ name: 'freeform_bg_add_shape', arguments: { expectedBoardTitle: 'Board', shape: 'circle', fill: 'red' } });
  assert.deepEqual(ok.structuredContent, { ok: true, echo: 'addShape' });
  for (const args of [
    { expectedBoardTitle: 'Board', shape: 'circle', fill: 'crimson' },
    { expectedBoardTitle: 'Board', shape: 'circle', surprise: true },
    { expectedBoardTitle: '', shape: 'circle' },
  ]) {
    const response = await client.callTool({ name: 'freeform_bg_add_shape', arguments: args });
    assert.equal(response.isError, true);
  }
  const raise = await client.callTool({ name: 'freeform_bg_connect', arguments: { expectedBoardTitle: 'Board', expectedSnapshot: snapshot,
    from: { objectIndex: 0, expectedDescription: 'A' }, to: { objectIndex: 1, expectedDescription: 'B' }, arrowhead: 'simple' } });
  assert.equal(raise.isError, true);
  const create = await client.callTool({ name: 'freeform_bg_create_board', arguments: { title: 'New board' } });
  assert.equal(create.isError, true);
  assert.deepEqual(requests.map(r => r.command), ['addShape']);
});
