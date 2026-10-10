import { readFile, writeFile } from 'node:fs/promises';
import { getStatus, insertObjects, readSelection, createBoard, openBoard, listObjects, moveObject, undo, screenshot, arrangeObjects } from './bridge.mjs';

const [command, board, path, description, dx, dy] = process.argv.slice(2);
try {
  let result;
  if (command === 'status') result = await getStatus();
  else if (command === 'create-board') result = await createBoard({ title: board });
  else if (command === 'open-board') result = await openBoard({ title: board });
  else if (command === 'list-objects') result = await listObjects({ expectedBoardTitle: board });
  else if (command === 'undo') result = await undo({ expectedBoardTitle: board });
  else if (command === 'move-object') result = await moveObject({ expectedBoardTitle: board, objectIndex: Number(path), expectedDescription: description, dx: Number(dx), dy: Number(dy) });
  else if (command === 'screenshot' && path) {
    const { imageBase64, ...metadata } = await screenshot({ expectedBoardTitle: board });
    await writeFile(path, Buffer.from(imageBase64, 'base64'));
    result = { ...metadata, path };
  }
  else if (command === 'arrange' && path) {
    const request = JSON.parse(await readFile(path, 'utf8'));
    result = await arrangeObjects({ ...request, expectedBoardTitle: board });
  }
  else if (command === 'read-selection') result = await readSelection({ expectedBoardTitle: board });
  else if (command === 'insert' && path) {
    const objects = JSON.parse(await readFile(path, 'utf8'));
    result = await insertObjects({ expectedBoardTitle: board, objects });
  } else throw new Error('Usage: node src/cli.mjs status | screenshot BOARD OUTPUT.png | arrange BOARD REQUEST.json | create-board TITLE | open-board TITLE | list-objects BOARD | move-object BOARD INDEX DESCRIPTION DX DY | undo BOARD | read-selection BOARD | insert BOARD OBJECTS.json');
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
