import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rename, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createNativeBridge } from '../src/native-bridge.mjs';

async function fixture(t, responder) {
  const root = await mkdtemp(join(tmpdir(), 'ff-native-'));
  const requests = join(root, 'requests'), responses = join(root, 'responses');
  await mkdir(requests); await mkdir(responses);
  const sessionFile = join(root, 'session.json');
  await writeFile(sessionFile, JSON.stringify({ protocolVersion: 1, sessionId: 'session1', pid: process.pid, requestDirectory: requests, responseDirectory: responses }));
  const seen = [];
  let running = true;
  const poll = (async () => {
    while (running) {
      for (const name of await readdir(requests)) {
        if (!name.endsWith('.json') || seen.some(r => `${r.id}.json` === name)) continue;
        const request = JSON.parse(await readFile(join(requests, name), 'utf8'));
        seen.push(request);
        if (responder) {
          const response = await responder(request);
          const temp = join(responses, `.${name}.tmp`);
          await writeFile(temp, JSON.stringify(response)); await rename(temp, join(responses, name));
        }
      }
      await delay(5);
    }
  })();
  t.after(async () => { running = false; await poll; await rm(root, { recursive: true, force: true }); });
  return { root, requests, seen, sessionFile, bridge: createNativeBridge({ sessionFile, timeoutMs: 250, pollMs: 5 }) };
}
const good = req => ({ id: req.id, sessionId: req.sessionId, ok: true, result: { action: req.action } });

test('native calls serialize, use unique IDs, private atomic requests and expiry', async t => {
  const f = await fixture(t, good);
  assert.deepEqual(await Promise.all([f.bridge.listBoards(), f.bridge.listObjects({ boardId: 'board' })]), [{ action: 'list_boards' }, { action: 'list_objects' }]);
  assert.equal(new Set(f.seen.map(r => r.id)).size, 2);
  assert.deepEqual(f.seen.map(r => r.action), ['list_boards', 'list_objects']);
  for (const req of f.seen) {
    assert.equal(req.sessionId, 'session1'); assert.ok(Number.isFinite(req.expiresAt));
    assert.equal((await stat(join(f.requests, `${req.id}.json`))).mode & 0o777, 0o600);
  }
});

test('response from another session cannot satisfy request', async t => {
  const f = await fixture(t, req => ({ ...good(req), sessionId: 'old-session' }));
  await assert.rejects(f.bridge.listBoards(), /NATIVE_SESSION_MISMATCH/);
});

test('timeout never replays a move and reports unknown outcome', async t => {
  const f = await fixture(t);
  await assert.rejects(f.bridge.moveObject({ boardId: 'b', objectId: 'o', x: 1, y: 2, expectedGeometry: { x: 0, y: 0, width: 10, height: 20 } }), /outcome unknown/);
  await delay(30);
  assert.equal(f.seen.length, 1); assert.equal(f.seen[0].action, 'move_object');
});

test('unavailable lab gives readable status, bad queue paths rejected', async t => {
  const f = await fixture(t, good);
  assert.equal((await createNativeBridge({ sessionFile: join(f.root, 'missing') }).getStatus()).available, false);
  const manifest = JSON.parse(await readFile(f.sessionFile, 'utf8'));
  await writeFile(f.sessionFile, JSON.stringify({ ...manifest, requestDirectory: tmpdir() }));
  await assert.rejects(f.bridge.listBoards(), /Queues must be inside/);
});
