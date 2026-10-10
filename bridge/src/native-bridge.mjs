import { open, readFile, realpath, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, isAbsolute, join, relative, sep } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const fail = (message) => { throw new Error(message); };
const identifier = (value) => typeof value === 'string' && value.length > 0 && value.length <= 512;
const coordinate = (value) => Number.isFinite(value) && Math.abs(value) <= 100000;
function inside(root, path) {
  const rel = relative(root, path);
  return rel !== '' && !rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel);
}

/** Connect only to an explicitly configured isolated Freeform lab session. */
export function createNativeBridge({ sessionFile = process.env.FREEFORM_NATIVE_SESSION_FILE, timeoutMs = 10000, pollMs = 25 } = {}) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isFinite(pollMs) || pollMs <= 0) throw new TypeError('Invalid native transport timeout');
  let queue = Promise.resolve();
  async function session() {
    if (!sessionFile) fail('NATIVE_UNCONFIGURED: Set FREEFORM_NATIVE_SESSION_FILE to the isolated lab session manifest.');
    if (!isAbsolute(sessionFile)) fail('NATIVE_SESSION_INVALID: Manifest path must be absolute.');
    const manifestPath = await realpath(sessionFile);
    const root = dirname(manifestPath);
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
    if (manifest.protocolVersion !== 1 || !identifier(manifest.sessionId) || !Number.isSafeInteger(manifest.pid) || manifest.pid <= 0) fail('NATIVE_SESSION_INVALID: Invalid session identity.');
    for (const field of ['requestDirectory', 'responseDirectory']) {
      if (typeof manifest[field] !== 'string' || !isAbsolute(manifest[field])) fail('NATIVE_SESSION_INVALID: Queue paths must be absolute.');
      manifest[field] = await realpath(manifest[field]);
      if (!inside(root, manifest[field])) fail('NATIVE_SESSION_INVALID: Queues must be inside the manifest directory.');
    }
    if (manifest.requestDirectory === manifest.responseDirectory) fail('NATIVE_SESSION_INVALID: Queues must be distinct.');
    return manifest;
  }
  async function exchange(action, args) {
    const manifest = await session();
    const id = randomUUID();
    const expiresAt = Date.now() + timeoutMs;
    const request = { ...args, id, sessionId: manifest.sessionId, action, expiresAt };
    const requestPath = join(manifest.requestDirectory, `${id}.json`);
    const tempPath = join(manifest.requestDirectory, `.${id}.tmp`);
    const responsePath = join(manifest.responseDirectory, `${id}.json`);
    const file = await open(tempPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await file.writeFile(JSON.stringify(request)); } finally { await file.close(); }
    try { await rename(tempPath, requestPath); } catch (error) { await unlink(tempPath).catch(() => {}); throw error; }
    while (Date.now() < expiresAt) {
      let response;
      try {
        const handle = await open(responsePath, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          if ((await handle.stat()).size > 16_000_000) fail('NATIVE_RESPONSE_INVALID: Response too large; operation outcome unknown.');
          response = JSON.parse(await handle.readFile('utf8'));
        } finally { await handle.close(); }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      if (response !== undefined) {
        if (response.id !== id || response.sessionId !== manifest.sessionId) fail('NATIVE_SESSION_MISMATCH: Response identity mismatch; operation outcome unknown. Do not retry automatically.');
        await unlink(responsePath).catch(() => {});
        if (response.ok !== true) fail(`NATIVE_ERROR: ${typeof response.error === 'string' ? response.error : JSON.stringify(response.error ?? response)}. Inspect state before retrying a move.`);
        return response.result;
      }
      await delay(Math.min(pollMs, Math.max(1, expiresAt - Date.now())));
    }
    fail(`NATIVE_TIMEOUT: ${action} outcome unknown. The request is never replayed; inspect the board before retrying. Request ${id}.`);
  }
  function invoke(action, args = {}) {
    const pending = queue.then(() => exchange(action, args));
    queue = pending.catch(() => {});
    return pending;
  }
  return {
    getStatus: async () => {
      if (!sessionFile) return { configured: false, available: false, reason: 'Set FREEFORM_NATIVE_SESSION_FILE to an isolated lab session manifest.' };
      try { return await invoke('status'); } catch (error) {
        if (error.code === 'ENOENT') return { configured: true, available: false, reason: 'Lab session manifest or queue is not available.' };
        throw error;
      }
    },
    listBoards: () => invoke('list_boards'),
    listObjects: ({ boardId }) => {
      if (!identifier(boardId)) throw new TypeError('boardId is required');
      return invoke('list_objects', { boardId });
    },
    moveObject: ({ boardId, objectId, x, y, expectedGeometry }) => {
      if (!identifier(boardId) || !identifier(objectId) || !coordinate(x) || !coordinate(y) || !expectedGeometry || !coordinate(expectedGeometry.x) || !coordinate(expectedGeometry.y) || !Number.isFinite(expectedGeometry.width) || expectedGeometry.width <= 0 || !Number.isFinite(expectedGeometry.height) || expectedGeometry.height <= 0) throw new TypeError('Move requires board/object IDs, finite coordinates, and expected geometry.');
      return invoke('move_object', { boardId, objectId, x, y, expectedGeometry: { x: expectedGeometry.x, y: expectedGeometry.y, width: expectedGeometry.width, height: expectedGeometry.height } });
    },
  };
}
