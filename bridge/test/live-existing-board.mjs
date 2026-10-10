// Opt-in: appends two shapes, verifies the count, then undoes that insertion.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { insertObjects, listObjects, undo, readSelection } from '../src/bridge.mjs';

const expectedBoardTitle = process.argv[2];
if (!expectedBoardTitle) throw new Error('Supply the exact disposable board title. Never automatically retry.');
const evidence = { title: expectedBoardTitle, startedAt: new Date().toISOString() };
try {
  evidence.before = await listObjects({ expectedBoardTitle });
  assert.ok(evidence.before.objects.length > 0, 'This test requires existing objects');
  evidence.insertion = await insertObjects({ expectedBoardTitle, objects: [
    { shape: 'rectangle', x: 0, y: 240, width: 180, height: 80, fill: '#336699', text: 'Existing board insertion' },
    { shape: 'ellipse', x: 240, y: 240, width: 120, height: 80, fill: '#996633', text: 'Second new object' },
  ] });
  assert.equal(evidence.insertion.clipboardRestored, true);
  evidence.after = await listObjects({ expectedBoardTitle });
  assert.equal(evidence.after.objects.length, evidence.before.objects.length + 2);
  evidence.readback = await readSelection({ expectedBoardTitle });
  assert.equal(evidence.readback.objects.length, 2);
  assert.equal(evidence.readback.clipboardRestored, true);
  evidence.undo = await undo({ expectedBoardTitle });
  evidence.restored = await listObjects({ expectedBoardTitle });
  assert.deepEqual(evidence.restored.objects.map(x => x.description), evidence.before.objects.map(x => x.description));
  evidence.passed = true;
} catch (error) {
  evidence.error = error.message;
  process.exitCode = 1;
} finally {
  await writeFile(new URL('../examples/existing-board-proof.json', import.meta.url), JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify({ title: expectedBoardTitle, passed: evidence.passed ?? false, error: evidence.error }));
}
