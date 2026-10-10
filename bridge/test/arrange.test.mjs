import assert from 'node:assert/strict';
import test from 'node:test';
import { encodeObjects } from '../src/encode.mjs';
import { validateArrangement, verifyArrangement, alignments } from '../src/arrange.mjs';
const before = encodeObjects([
  { shape: 'rectangle', x: 0, y: 0, width: 100, height: 60, fill: '#123456', text: 'A' },
  { shape: 'rectangle', x: 200, y: 100, width: 80, height: 40, fill: '#654321', text: 'B' },
]);
const group = objects => ({ type_identifier: 'com.apple.apps.content-language.group', children: objects.map(shape => ({ primary_case: 'shape', shape })) });
test('grouping verification preserves children, positions, dimensions and content', () => {
  verifyArrangement('group', before, [group(before.toReversed())]);
  verifyArrangement('ungroup', [group(before)], before.toReversed());
  for (const mutate of [o => { o[0].geometry.position.x++; }, o => { o[0].text.attributed_string[0] = 'Lost'; }, o => { o.pop(); }]) {
    const changed = structuredClone(before); mutate(changed);
    assert.throws(() => verifyArrangement('group', before, [group(changed)]));
  }
});
test('all six alignments verify requested bounds while preserving the other axis', () => {
  for (const action of alignments) {
    const now = structuredClone(before), horizontal = ['left', 'center', 'right'].includes(action);
    for (const o of now) {
      const { position: p, size: s } = o.geometry;
      if (horizontal) p.x = action === 'left' ? 0 : action === 'right' ? 280 - s.width : 140 - s.width / 2;
      else p.y = action === 'top' ? 0 : action === 'bottom' ? 140 - s.height : 70 - s.height / 2;
    }
    verifyArrangement(action, before, now.toReversed());
    const corrupted = structuredClone(now); corrupted[0].geometry.position[horizontal ? 'y' : 'x']++;
    assert.throws(() => verifyArrangement(action, before, corrupted));
    assert.throws(() => verifyArrangement(action, before, before));
  }
});
test('arrangement refuses duplicate targets, stale-token format and unsupported actions before dispatch', () => {
  const args = { action: 'group', expectedSnapshot: 'a'.repeat(64), targets: [{ objectIndex: 0, expectedDescription: 'A' }, { objectIndex: 1, expectedDescription: 'B' }] };
  validateArrangement(args);
  for (const invalid of [{ ...args, expectedSnapshot: '' }, { ...args, targets: [args.targets[0], args.targets[0]] }, { ...args, action: 'delete' }, { ...args, action: 'ungroup' }, { ...args, targets: [args.targets[0]] }]) assert.throws(() => validateArrangement(invalid));
});
