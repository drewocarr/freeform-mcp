const PREFIX = 'com.apple.apps.content-language.';
const FIELDS = new Set(['shape', 'x', 'y', 'width', 'height', 'fill', 'text']);
const SHAPES = new Set(['rectangle', 'roundedRectangle', 'ellipse', 'arrow']);

const model = (type, fields, version = '1.0') => ({
  type_identifier: PREFIX + type,
  version,
  ...fields,
});

function validate(object, index) {
  const fail = message => { throw new TypeError(`objects[${index}]: ${message}`); };
  if (!object || typeof object !== 'object' || Array.isArray(object)) fail('must be an object');
  for (const key of Object.keys(object)) if (!FIELDS.has(key)) fail(`unknown field ${key}`);
  if (!SHAPES.has(object.shape)) fail('shape must be rectangle, roundedRectangle, ellipse, or arrow');
  for (const key of ['x', 'y']) {
    if (!Number.isFinite(object[key]) || Math.abs(object[key]) > 100000) fail(`${key} must be finite and between -100000 and 100000`);
  }
  for (const key of ['width', 'height']) {
    if (!Number.isFinite(object[key]) || object[key] <= 0 || object[key] > 10000) fail(`${key} must be finite, greater than 0, and at most 10000`);
  }
  if (typeof object.fill !== 'string' || !/^#[0-9a-f]{6}$/i.test(object.fill)) fail('fill must be #RRGGBB');
  if (object.text !== undefined && (typeof object.text !== 'string' || object.text.length > 10000)) fail('text must be a string of at most 10000 UTF-16 code units');
}

function pathFor(shape, w, h) {
  if (shape === 'rectangle') return `M 0 0 L ${w} 0 L ${w} ${h} L 0 ${h} Z`;
  // A filled vector arrow is independent of neighboring shapes; it has no attached endpoints.
  if (shape === 'arrow') return `M 0 ${h / 3} L ${w * 0.6} ${h / 3} L ${w * 0.6} 0 L ${w} ${h / 2} L ${w * 0.6} ${h} L ${w * 0.6} ${h * 2 / 3} L 0 ${h * 2 / 3} Z`;
  const k = 0.5522847498307936;
  if (shape === 'ellipse') {
    const rx = w / 2, ry = h / 2;
    return `M ${w} ${ry} C ${w} ${ry + k * ry} ${rx + k * rx} ${h} ${rx} ${h} C ${rx - k * rx} ${h} 0 ${ry + k * ry} 0 ${ry} C 0 ${ry - k * ry} ${rx - k * rx} 0 ${rx} 0 C ${rx + k * rx} 0 ${w} ${ry - k * ry} ${w} ${ry} Z`;
  }
  const r = Math.min(w, h) * 0.15;
  const d = r * k;
  return `M ${r} 0 L ${w - r} 0 C ${w - r + d} 0 ${w} ${r - d} ${w} ${r} L ${w} ${h - r} C ${w} ${h - r + d} ${w - r + d} ${h} ${w - r} ${h} L ${r} ${h} C ${r - d} ${h} 0 ${h - r + d} 0 ${h - r} L 0 ${r} C 0 ${r - d} ${r - d} 0 ${r} 0 Z`;
}

function encodeObject({ shape, x, y, width, height, fill, text = '' }) {
  const channels = [1, 3, 5].map(start => parseInt(fill.slice(start, start + 2), 16) / 255);
  return model('shape', {
    description: '',
    aspect_ratio_locked: false,
    tail: 'none',
    head: 'none',
    stroke: 'empty',
    opacity: 1,
    fill: model('fill', {
      primary_case: 'color',
      color: model('color', {
        primary_case: 'rgba',
        rgba: model('color.rgba', {
          red: channels[0], green: channels[1], blue: channels[2],
          alpha: 1, headroom: 1, color_space: 'srgb',
        }, '1.1'),
      }),
    }),
    path: model('path', {
      primary_case: 'bezier',
      bezier: model('path.bezier-path', { path: pathFor(shape, width, height) }),
    }),
    text: model('text', { primary_case: 'attributed_string', attributed_string: [text, {}] }),
    geometry: model('geometry', {
      position: model('position', { x, y }),
      size: model('size', { width, height }),
      flip_horizontally: false,
      width_valid: true,
      height_valid: true,
      angle: 0,
    }),
    layout_properties: model('layout-properties', {
      shrink_to_fit: true,
      vertical_alignment: 'center',
      padding: model('insets', { left: 10, right: 10, top: 10, bottom: 10 }),
    }),
  });
}

/**
 * Build Freeform content-language JSON objects without native archives or templates.
 * Coordinates describe relative layout; Freeform chooses the final paste location.
 * Curves are editable vector shapes, without Freeform's parametric shape handles.
 */
export function encodeObjects(objects) {
  if (!Array.isArray(objects) || objects.length < 1 || objects.length > 100) {
    throw new TypeError('objects must be an array containing 1 to 100 objects');
  }
  // Validate the complete request before producing any objects.
  for (let i = 0; i < objects.length; i++) validate(objects[i], i);
  return objects.map(encodeObject);
}
