// Background editing of the regular Freeform app while another app stays frontmost.
// Calls the separate bin/freeform-background helper, which never activates Freeform.
import { fileURLToPath } from 'node:url';
import { runHelper, serialized } from './bridge.mjs';

export const SHAPES = ['square', 'circle', 'roundedRectangle', 'diamond', 'triangle', 'parallelogram', 'pentagon', 'terminator', 'arrow', 'textBox', 'stickyNote'];
export const SWATCHES = ['black', 'gray', 'white', 'cyan', 'magenta pink', 'dark indigo', 'red', 'orange', 'light amber', 'green', 'teal', 'blue'];
export const CONNECTION_STYLES = ['straight', 'corner', 'curve'];
export const ARROWHEADS = ['none', 'simple', 'filled', 'open'];

const executable = fileURLToPath(new URL('../bin/freeform-background', import.meta.url));

function fail(message) { throw new TypeError(message); }
function title(value, name = 'expectedBoardTitle') {
  if (typeof value !== 'string' || !value.trim() || value.length > 1000) fail(`${name} must be a nonempty string of at most 1000 characters`);
  return value;
}
function coordinate(value, name) {
  if (value === undefined) return undefined;
  if (!Number.isFinite(value) || Math.abs(value) > 100000) fail(`${name} must be finite and between -100000 and 100000`);
  return value;
}
function dimension(value, name) {
  if (value === undefined) return undefined;
  if (!Number.isFinite(value) || value < 10 || value > 10000) fail(`${name} must be between 10 and 10000`);
  return value;
}
function label(value) {
  if (value === undefined) return undefined;
  // Text is typed into Freeform; control characters such as Return would end editing.
  if (typeof value !== 'string' || !value.length || value.length > 1000 || /[\u0000-\u001f\u007f]/.test(value)) {
    fail('text must be 1–1000 characters without newlines or other control characters');
  }
  return value;
}
function fill(value) {
  if (value === undefined) return undefined;
  if (!SWATCHES.includes(value)) fail(`fill must be one of Freeform's named swatches: ${SWATCHES.join(', ')}`);
  return value;
}
function snapshot(value) {
  if (typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) fail('expectedSnapshot must be the snapshotToken from a recent list');
  return value;
}
function target(value, name = 'target') {
  if (!value || typeof value !== 'object') fail(`${name} must be an object`);
  const { objectIndex, expectedDescription } = value;
  if (!Number.isSafeInteger(objectIndex) || objectIndex < 0) fail(`${name}.objectIndex must be a nonnegative safe integer`);
  if (typeof expectedDescription !== 'string' || !expectedDescription.trim() || expectedDescription.length > 10000) fail(`${name}.expectedDescription must be the description from a recent list`);
  return { objectIndex, expectedDescription };
}
function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));
}

export function createBackgroundBridge({ run = request => runHelper(executable, request) } = {}) {
  const call = request => serialized(() => run(request));
  return {
    getStatus: () => call({ command: 'status' }),
    listObjects: ({ expectedBoardTitle }) => call({ command: 'listObjects', expectedBoardTitle: title(expectedBoardTitle) }),
    screenshot: ({ expectedBoardTitle }) => call({ command: 'screenshot', expectedBoardTitle: title(expectedBoardTitle) }),
    openBoard: ({ title: name }) => call({ command: 'openBoard', title: title(name, 'title') }),
    createBoard: ({ title: name, allowWindowRaise = false }) => {
      if (allowWindowRaise !== true) fail('allowWindowRaise must be true: naming a board uses a context menu that raises Freeform\'s window');
      return call({ command: 'createBoard', title: title(name, 'title'), allowWindowRaise: true });
    },
    renameBoard: ({ fromTitle, title: name, allowWindowRaise = false }) => {
      if (allowWindowRaise !== true) fail('allowWindowRaise must be true: renaming uses a context menu that raises Freeform\'s window');
      return call({ command: 'renameBoard', fromTitle: title(fromTitle, 'fromTitle'), title: title(name, 'title'), allowWindowRaise: true });
    },
    addShape: ({ expectedBoardTitle, shape, x, y, width, height, text, fill: color }) => {
      if (!SHAPES.includes(shape)) fail(`shape must be one of ${SHAPES.join(', ')}`);
      if (color !== undefined && (shape === 'textBox' || shape === 'stickyNote')) fail('fill applies to shapes, not text boxes or sticky notes');
      if (shape === 'textBox' && text === undefined) fail('A text box needs text; Freeform discards empty text boxes');
      return call(compact({ command: 'addShape', expectedBoardTitle: title(expectedBoardTitle), shape,
        x: coordinate(x, 'x'), y: coordinate(y, 'y'), width: dimension(width, 'width'), height: dimension(height, 'height'), text: label(text), fill: fill(color) }));
    },
    updateObject: ({ expectedBoardTitle, expectedSnapshot, objectIndex, expectedDescription, x, y, width, height, text, fill: color, style, arrowhead, allowWindowRaise }) => {
      if (style !== undefined && !CONNECTION_STYLES.includes(style)) fail(`style must be one of ${CONNECTION_STYLES.join(', ')}`);
      if (arrowhead !== undefined && !ARROWHEADS.includes(arrowhead)) fail(`arrowhead must be one of ${ARROWHEADS.join(', ')}`);
      if (arrowhead !== undefined && arrowhead !== 'none' && allowWindowRaise !== true) fail('Arrowheads use a pop-up menu that raises Freeform\'s window; pass allowWindowRaise: true');
      if (arrowhead === 'none') fail('Removing an arrowhead is not supported yet');
      const request = compact({ command: 'updateObject', expectedBoardTitle: title(expectedBoardTitle), expectedSnapshot: snapshot(expectedSnapshot),
        ...target({ objectIndex, expectedDescription }), x: coordinate(x, 'x'), y: coordinate(y, 'y'),
        width: dimension(width, 'width'), height: dimension(height, 'height'), text: label(text), fill: fill(color), style, arrowhead,
        allowWindowRaise: allowWindowRaise === true ? true : undefined });
      if (!['x', 'y', 'width', 'height', 'text', 'fill', 'style', 'arrowhead'].some(key => key in request)) fail('Provide at least one of x, y, width, height, text, fill, style, arrowhead');
      return call(request);
    },
    deleteObject: ({ expectedBoardTitle, expectedSnapshot, objectIndex, expectedDescription }) => call({ command: 'deleteObject',
      expectedBoardTitle: title(expectedBoardTitle), expectedSnapshot: snapshot(expectedSnapshot), ...target({ objectIndex, expectedDescription }) }),
    connect: ({ expectedBoardTitle, expectedSnapshot, from, to, style = 'straight', arrowhead = 'none', allowWindowRaise = false }) => {
      if (!CONNECTION_STYLES.includes(style)) fail(`style must be one of ${CONNECTION_STYLES.join(', ')}`);
      if (!ARROWHEADS.includes(arrowhead)) fail(`arrowhead must be one of ${ARROWHEADS.join(', ')}`);
      if (arrowhead !== 'none' && allowWindowRaise !== true) fail('Arrowheads use a pop-up menu that raises Freeform\'s window; pass allowWindowRaise: true or arrowhead: "none"');
      const a = target(from, 'from'), b = target(to, 'to');
      if (a.objectIndex === b.objectIndex) fail('from and to must be different objects');
      return call({ command: 'connect', expectedBoardTitle: title(expectedBoardTitle), expectedSnapshot: snapshot(expectedSnapshot),
        from: a, to: b, style, arrowhead, allowWindowRaise: allowWindowRaise === true });
    },
  };
}
