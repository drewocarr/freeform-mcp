import { readFile, writeFile } from 'node:fs/promises';

const source = new URL('./source/item-0-type-5.bin', import.meta.url);
const objects = JSON.parse(await readFile(source, 'utf8'));
if (objects.length !== 1 || objects[0].type_identifier !== 'com.apple.apps.content-language.shape') {
  throw new Error('Expected the single synthetic source shape');
}
const rgba = objects[0].fill.color.rgba;
const before = { red: rgba.red, green: rgba.green, blue: rgba.blue };
// Change only the fill color; retain the captured shape and model metadata.
Object.assign(rgba, { red: 1, green: 0.2, blue: 0.15 });
const output = new URL('./modified-color.json', import.meta.url);
await writeFile(output, JSON.stringify(objects, null, 2));
console.log(JSON.stringify({ output: output.pathname, before, after: { red: rgba.red, green: rgba.green, blue: rgba.blue } }));
