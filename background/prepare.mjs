import { createBoard, insertObjects } from '../bridge/src/bridge.mjs';
import { encodeObjects } from '../bridge/src/encode.mjs';
import { writeFile } from 'node:fs/promises';
const title = 'Background Bridge Probe — 2026-10-09';
await createBoard({ title });
const inserted = await insertObjects({ expectedBoardTitle: title, objects: [
 { shape: 'rectangle', x: 0, y: 0, width: 140, height: 70, fill: '#3377cc', text: 'Background A' },
 { shape: 'rectangle', x: 240, y: 140, width: 140, height: 70, fill: '#cc7733', text: 'Background B' },
] });
await writeFile(new URL('./initial.json', import.meta.url), JSON.stringify(inserted, null, 2));
await writeFile(new URL('./payload.json', import.meta.url), JSON.stringify(encodeObjects([
 { shape: 'ellipse', x: 0, y: 300, width: 140, height: 70, fill: '#559955', text: 'Background paste' },
])));
console.log(JSON.stringify({ title, inserted: inserted.insertedCount, clipboardRestored: inserted.clipboardRestored }));
