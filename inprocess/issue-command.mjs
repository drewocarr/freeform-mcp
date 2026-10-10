#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { createNativeBridge } from '../bridge/src/native-bridge.mjs';

const native=createNativeBridge({sessionFile:process.env.FREEFORM_NATIVE_SESSION_FILE ?? fileURLToPath(new URL('./lab/data/transport/session.json',import.meta.url))});
const [action,boardId,objectId,x,y,expected]=process.argv.slice(2);
let result;
switch(action) {
 case 'status': result=await native.getStatus(); break;
 case 'boards': result=await native.listBoards(); break;
 case 'objects': result=await native.listObjects({boardId}); break;
 case 'move':
  if(x===undefined||y===undefined||!expected)throw new Error('Move requires boardId objectId x y expectedGeometryJSON from a previous objects read.');
  result=await native.moveObject({boardId,objectId,x:Number(x),y:Number(y),expectedGeometry:JSON.parse(expected)});break;
 default:throw new Error('Usage: node issue-command.mjs status|boards|objects BOARD_ID|move BOARD_ID OBJECT_ID X Y EXPECTED_GEOMETRY_JSON');
}
console.log(JSON.stringify(result,null,2));
