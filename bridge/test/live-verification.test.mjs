import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { verifyImportedObjects } from '../src/verify.mjs';
const expected = [
  { shape: 'roundedRectangle', fill: '#336699', x: 0, y: 0, width: 100, height: 50, text: 'Hello' },
  { shape: 'arrow', fill: '#336699', x: 200, y: 0, width: 50, height: 20 },
  { shape: 'arrow', fill: '#336699', x: 300, y: 0, width: 50, height: 20 },
];
const copied = () => expected.map(object => ({
  type_identifier: 'com.apple.apps.content-language.shape',
  fill: { color: { rgba: { red: 0.2, green: 0.4, blue: 0.6 } } },
  path: { bezier: { path: 'M 0 0 L 1 1' } },
  text: { attributed_string: [object.text ?? '\u200b', {}] },
  geometry: { size: { width: object.width, height: object.height }, position: { x: object.x + 15, y: object.y - 10 } },
}));
test('live verifier accepts reordering, one paste offset, and empty labels represented as U+200B', () => {
  assert.deepEqual(verifyImportedObjects(expected, copied().reverse()), { x: 15, y: -10 });
});
test('live verifier rejects changed nonempty labels and changed relative positions', () => {
  const labels = copied();
  labels[0].text.attributed_string[0] += '\u200b';
  assert.throws(() => verifyImportedObjects(expected, labels));
  const positions = copied();
  positions[2].geometry.position.x += 1;
  assert.throws(() => verifyImportedObjects(expected, positions));
  const empty = copied();
  empty[1].text.attributed_string[0] = '\u200b\u200b';
  assert.throws(() => verifyImportedObjects(expected, empty));
});

test('live verifier accepts the observed native rectangle without a path, but rejects it for other shapes', () => {
  const fixture = JSON.parse(readFileSync(new URL('../examples/live-diagram-result.json', import.meta.url), 'utf8')).objects[1];
  const rectangle = { shape: 'rectangle', x: 300, y: 0, width: 220, height: 120, fill: '#BDE5C8', text: '2. JavaScript builds it' };
  assert.equal('path' in fixture, false);
  assert.doesNotThrow(() => verifyImportedObjects([rectangle], [fixture]));
  assert.throws(() => verifyImportedObjects([{ ...rectangle, shape: 'ellipse' }], [fixture]));
  assert.throws(() => verifyImportedObjects([rectangle], [{ ...fixture, image: {} }]));
  assert.throws(() => verifyImportedObjects([{ ...rectangle, fill: '#FFFFFF' }], [fixture]));
});
