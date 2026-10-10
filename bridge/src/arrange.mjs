import assert from 'node:assert/strict';

export const alignments = ['left', 'center', 'right', 'top', 'middle', 'bottom'];
export function validateArrangement({ expectedSnapshot, targets, action }) {
  if (!/^[a-f0-9]{64}$/.test(expectedSnapshot ?? '')) throw new TypeError('Use snapshotToken from a fresh listObjects result as expectedSnapshot');
  if (!['group', 'ungroup', ...alignments].includes(action)) throw new TypeError('Unsupported arrangement action');
  if (!Array.isArray(targets) || (action === 'ungroup' ? targets.length !== 1 : targets.length < 2 || targets.length > 100)) throw new TypeError('Select 2–100 objects, or one group to ungroup');
  const indices = new Set();
  for (const target of targets) {
    if (!Number.isSafeInteger(target.objectIndex) || target.objectIndex < 0 || indices.has(target.objectIndex)) throw new TypeError('Targets must have distinct nonnegative object indices');
    if (typeof target.expectedDescription !== 'string' || !target.expectedDescription.trim() || target.expectedDescription.length > 10000) throw new TypeError('Each target needs its exact current description');
    indices.add(target.objectIndex);
  }
}
const close = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) < 0.001;
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return typeof value === 'number' ? Math.round(value * 1e5) / 1e5 : value;
}
function identity(object) {
  const copy = structuredClone(object);
  delete copy.geometry.position;
  return JSON.stringify(canonical(copy));
}
function children(group) {
  assert.equal(group.type_identifier, 'com.apple.apps.content-language.group');
  assert.ok(Array.isArray(group.children));
  return group.children.map(child => { assert.equal(child.primary_case, 'shape'); assert.ok(child.shape); return child.shape; });
}
export function verifyArrangement(action, before, after) {
  let old = before, now = after;
  if (action === 'group') { assert.equal(after.length, 1); now = children(after[0]); }
  else if (action === 'ungroup') { assert.equal(before.length, 1); old = children(before[0]); }
  assert.equal(old.length, now.length, 'Arrangement must preserve every requested object');
  const remaining = [...now];
  const pairs = old.map(object => {
    const index = remaining.findIndex(candidate => identity(candidate) === identity(object));
    assert.ok(index >= 0, 'Object content, style, and dimensions must remain unchanged');
    return [object, remaining.splice(index, 1)[0]];
  });
  const horizontal = ['left', 'center', 'right'].includes(action);
  const coordinate = object => {
    const { position: p, size: s } = object.geometry;
    return ({ left: p.x, center: p.x + s.width / 2, right: p.x + s.width, top: p.y, middle: p.y + s.height / 2, bottom: p.y + s.height })[action];
  };
  if (alignments.includes(action)) {
    for (const [a, b] of pairs) {
      assert.ok(close(a.geometry.position[horizontal ? 'y' : 'x'], b.geometry.position[horizontal ? 'y' : 'x']), 'Alignment must preserve the other axis');
      assert.ok(close(coordinate(b), coordinate(now[0])), 'Requested edges or centers must align');
    }
    // Freeform aligns to the selected objects' outer edges or collective center.
    const axis = horizontal ? 'x' : 'y', size = horizontal ? 'width' : 'height';
    const low = Math.min(...old.map(o => o.geometry.position[axis]));
    const high = Math.max(...old.map(o => o.geometry.position[axis] + o.geometry.size[size]));
    const expected = ['left', 'top'].includes(action) ? low : ['right', 'bottom'].includes(action) ? high : (low + high) / 2;
    assert.ok(close(coordinate(now[0]), expected), 'Alignment must use the original selection bounds');
  } else {
    for (const [a, b] of pairs) for (const axis of ['x', 'y']) assert.ok(close(a.geometry.position[axis], b.geometry.position[axis]), 'Grouping must preserve object positions');
  }
  return { content: true, dimensions: true, geometry: true, action };
}
