import assert from 'node:assert/strict';
const tolerance = 1e-4;
const close = (actual, expected) => Number.isFinite(actual) && Math.abs(actual - expected) <= tolerance;
const plainText = object => (object.text?.attributed_string ?? [])
  .filter(part => typeof part === 'string').join('');

function sameContent(expected, actual) {
  const text = expected.text ?? '';
  const copiedText = plainText(actual);
  // Freeform represents an empty label with a single zero-width space.
  const sameText = copiedText === text || (text === '' && copiedText === '\u200b');
  const channels = [1, 3, 5].map(start => parseInt(expected.fill.slice(start, start + 2), 16) / 255);
  const rgba = actual.fill?.color?.rgba;
  const sameFill = ['red', 'green', 'blue'].every((key, index) =>
    Number.isFinite(rgba?.[key]) && Math.abs(rgba[key] - channels[index]) <= 1e-6);
  // Freeform omits the path when it recognizes a plain native rectangle.
  const sameShape = actual.type_identifier === 'com.apple.apps.content-language.shape'
    && !('image' in actual) && (Boolean(actual.path?.bezier?.path)
      || (expected.shape === 'rectangle' && !('path' in actual)));
  return sameShape && sameFill && sameText && close(actual.geometry?.size?.width, expected.width)
    && close(actual.geometry?.size?.height, expected.height);
}

/** Verify imported content independently of clipboard order, allowing one paste offset. */
export function verifyImportedObjects(expected, actual) {
  assert.equal(actual.length, expected.length);
  assert.ok(expected.length > 0);
  for (const object of actual) {
    assert.equal(object.type_identifier, 'com.apple.apps.content-language.shape');
  }
  for (const anchor of actual.filter(object => sameContent(expected[0], object))) {
    const dx = anchor.geometry.position.x - expected[0].x;
    const dy = anchor.geometry.position.y - expected[0].y;
    const remaining = [...actual];
    let matches = true;
    for (const object of expected) {
      const index = remaining.findIndex(candidate => sameContent(object, candidate)
        && close(candidate.geometry?.position?.x, object.x + dx)
        && close(candidate.geometry?.position?.y, object.y + dy));
      if (index === -1) { matches = false; break; }
      remaining.splice(index, 1);
    }
    if (matches) return { x: dx, y: dy };
  }
  assert.fail('Copied objects must preserve native shape representation, fill RGB within 0.000001, exact nonempty labels, dimensions, and relative positions within 0.0001 points');
}
