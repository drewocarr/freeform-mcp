import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeObjects } from '../src/encode.mjs';

const box = { shape: 'rectangle', x: -20, y: 30, width: 240, height: 120, fill: '#FF8000', text: 'Start → finish' };

test('preserves requested layout, text, and color in a portable JSON payload', () => {
  const input = structuredClone(box);
  const result = JSON.parse(JSON.stringify(encodeObjects([input])))[0];
  assert.deepEqual(input, box);
  assert.equal(result.type_identifier, 'com.apple.apps.content-language.shape');
  assert.equal(result.geometry.position.x, -20);
  assert.equal(result.geometry.position.y, 30);
  assert.equal(result.geometry.size.width, 240);
  assert.equal(result.geometry.size.height, 120);
  assert.deepEqual(result.text.attributed_string, ['Start → finish', {}]);
  assert.equal(result.fill.color.rgba.red, 1);
  assert.equal(result.fill.color.rgba.green, 128 / 255);
  assert.equal(result.fill.color.rgba.blue, 0);
  assert.equal(result.path.bezier.path, 'M 0 0 L 240 0 L 240 120 L 0 120 Z');
});

test('all shapes use closed paths bounded by their requested dimensions', () => {
  for (const shape of ['rectangle', 'roundedRectangle', 'ellipse', 'arrow']) {
    const [result] = encodeObjects([{ ...box, shape, width: 200, height: 80 }]);
    const path = result.path.bezier.path;
    assert.match(path, /^M .* Z$/);
    const numbers = path.match(/-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/g).map(Number);
    const xs = numbers.filter((_, index) => index % 2 === 0);
    const ys = numbers.filter((_, index) => index % 2 === 1);
    assert.equal(Math.min(...xs), 0);
    assert.equal(Math.max(...xs), 200);
    assert.equal(Math.min(...ys), 0);
    assert.equal(Math.max(...ys), 80);
  }
});

test('arrow is a closed filled vector with a right-facing tip and no endpoint attachment', () => {
  const [result] = encodeObjects([{ ...box, shape: 'arrow', width: 50, height: 30 }]);
  assert.equal(result.path.bezier.path, 'M 0 10 L 30 10 L 30 0 L 50 15 L 30 30 L 30 20 L 0 20 Z');
  assert.equal(result.head, 'none');
  assert.equal(result.tail, 'none');
  assert.equal(result.type_identifier, 'com.apple.apps.content-language.shape');
});

test('multiple objects retain relative spacing and independent models', () => {
  const [a, b] = encodeObjects([box, { ...box, x: 300, text: 'Second' }]);
  assert.equal(b.geometry.position.x - a.geometry.position.x, 320);
  a.fill.color.rgba.red = 0;
  assert.equal(b.fill.color.rgba.red, 1);
});

test('rejects malformed or excessive inputs before clipboard work', () => {
  for (const input of [null, {}, [], new Array(1), Array(101).fill(box)]) {
    assert.throws(() => encodeObjects(input), TypeError);
  }
  for (const patch of [
    { shape: 'triangle' }, { x: NaN }, { x: Infinity }, { y: 100001 },
    { width: 0 }, { width: -1 }, { width: 10001 }, { height: '120' },
    { fill: 'red' }, { fill: '#123' }, { text: null }, { text: 'x'.repeat(10001) },
    { unexpected: true },
  ]) assert.throws(() => encodeObjects([{ ...box, ...patch }]), TypeError);
});

test('accepts boundary values and optional empty text', () => {
  const { text, ...withoutText } = box;
  const [result] = encodeObjects([{ ...withoutText, x: -100000, y: 100000, width: 10000, height: 10000, fill: '#abcdef' }]);
  assert.deepEqual(result.text.attributed_string, ['', {}]);
  assert.equal(encodeObjects(Array(100).fill(box)).length, 100);
});
