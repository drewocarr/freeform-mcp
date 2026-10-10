import { validateArrangement, verifyArrangement } from './arrange.mjs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { encodeObjects } from './encode.mjs';
import { verifyImportedObjects } from './verify.mjs';

const executable = fileURLToPath(new URL('../bin/freeform-bridge', import.meta.url));
let queue = Promise.resolve();

function runNative(request) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      error ? reject(error) : resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      finish(new Error('HELPER_TIMEOUT: Inspect the board and clipboard before retrying; the action may have completed.'));
    }, 90_000);
    child.stdout.on('data', data => {
      stdout += data;
      if (stdout.length > 16_000_000) {
        child.kill('SIGTERM');
        finish(new Error('HELPER_OUTPUT_LIMIT: Inspect the board before retrying.'));
      }
    });
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-2000); });
    child.on('error', error => finish(new Error(`Cannot launch native helper: ${error.message}. Run npm run build:native.`)));
    child.stdin.on('error', () => {});
    child.on('close', code => {
      let result;
      try { result = JSON.parse(stdout); } catch {
        finish(new Error(`Native helper exited ${code} without a valid result.${stderr ? ` ${stderr}` : ''}`));
        return;
      }
      if (!result.ok) {
        const suffix = result.mayHaveInserted ? ' Insertion may have completed; inspect before retrying.' : result.mayHaveChanged ? ' The action may have completed; inspect before retrying.' : '';
        const clipboard = result.clipboardRestored === false ? ' Clipboard restoration failed; it may contain bridge data.' : '';
        finish(Object.assign(new Error(`${result.error}${suffix}${clipboard}`), { nativeResult: { ...result, retryAutomatically: false } }));
      } else finish(null, result);
    });
    child.stdin.end(JSON.stringify(request));
  });
}

// A server has one clipboard and one focused Freeform board. Serialize its calls.
function serialized(task) {
  const result = queue.then(task);
  queue = result.catch(() => {});
  return result;
}
function boardTitle(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 1000) {
    throw new TypeError('expectedBoardTitle must be a nonempty string of at most 1000 characters');
  }
  return value;
}
export function getStatus() { return serialized(() => runNative({ command: 'status' })); }
export function readSelection({ expectedBoardTitle }) {
  const title = boardTitle(expectedBoardTitle);
  return serialized(() => runNative({ command: 'readSelection', expectedBoardTitle: title }));
}
export function insertObjects({ expectedBoardTitle, objects }) {
  const title = boardTitle(expectedBoardTitle);
  const encoded = encodeObjects(objects);
  const expected = structuredClone(objects);
  return serialized(async () => {
    const result = await runNative({ command: 'insert', expectedBoardTitle: title, objects: encoded });
    let translation;
    try { translation = verifyImportedObjects(expected, result.objects); }
    catch (error) {
      const clipboard = result.clipboardRestored === false ? ' Clipboard restoration failed.' : '';
      throw Object.assign(new Error(`INSERT_UNVERIFIED: ${error.message}. Objects were inserted; inspect before retrying.${clipboard}`), { nativeResult: { ok: false, error: "INSERT_UNVERIFIED", mayHaveInserted: true, clipboardRestored: result.clipboardRestored, retryAutomatically: false } });
    }
    return { ...result, verification: { labels: true, fill: true, dimensions: true, relativeLayout: true, nativeShapeRepresentation: true },
      translation, placement: 'Freeform may translate the pasted selection; returned geometry is the actual placement.' };
  });
}

export function createBoard({ title }) {
  return serialized(() => runNative({ command: 'createBoard', title: boardTitle(title) }));
}
export function openBoard({ title }) {
  return serialized(() => runNative({ command: 'openBoard', title: boardTitle(title) }));
}
export function listObjects({ expectedBoardTitle }) {
  const title = boardTitle(expectedBoardTitle);
  return serialized(() => runNative({ command: 'listObjects', expectedBoardTitle: title }));
}
export function moveObject({ expectedBoardTitle, objectIndex, expectedDescription, dx, dy }) {
  const title = boardTitle(expectedBoardTitle);
  if (!Number.isSafeInteger(objectIndex) || objectIndex < 0) throw new TypeError('objectIndex must be a nonnegative safe integer');
  if (typeof expectedDescription !== 'string' || !expectedDescription.trim() || expectedDescription.length > 10000) {
    throw new TypeError('expectedDescription must be the nonempty description from a recent listObjects result');
  }
  for (const [name, value] of Object.entries({ dx, dy })) {
    if (!Number.isInteger(value) || Math.abs(value) > 100) throw new TypeError(`${name} must be an integer from -100 to 100`);
  }
  if (dx === 0 && dy === 0) throw new TypeError('At least one movement must be nonzero');
  return serialized(() => runNative({ command: 'moveObject', expectedBoardTitle: title, objectIndex, expectedDescription, dx, dy }));
}
export function undo({ expectedBoardTitle }) {
  const title = boardTitle(expectedBoardTitle);
  return serialized(() => runNative({ command: 'undo', expectedBoardTitle: title }));
}

export function screenshot({ expectedBoardTitle }) {
  const title = boardTitle(expectedBoardTitle);
  return serialized(() => runNative({ command: 'screenshot', expectedBoardTitle: title }));
}
export function arrangeObjects({ expectedBoardTitle, expectedSnapshot, targets, action }) {
  const title = boardTitle(expectedBoardTitle);
  validateArrangement({ expectedSnapshot, targets, action });
  const request = structuredClone({ command: 'arrangeObjects', expectedBoardTitle: title, expectedSnapshot, targets, action });
  return serialized(async () => {
    const value = await runNative(request);
    try { return { ...value, verification: verifyArrangement(action, value.before, value.after) }; }
    catch (error) {
      throw Object.assign(new Error(`ARRANGE_UNVERIFIED: ${error.message}. Inspect the board before retrying.`), {
        nativeResult: { ...value, ok: false, error: 'ARRANGE_UNVERIFIED', mayHaveChanged: true, retryAutomatically: false },
      });
    }
  });
}
