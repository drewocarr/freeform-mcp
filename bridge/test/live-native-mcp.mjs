import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const sessionFile=process.env.FREEFORM_NATIVE_SESSION_FILE;
const [boardId,objectId,output]=process.argv.slice(2);
if(!sessionFile||!boardId||!objectId||!output)throw new Error('Set FREEFORM_NATIVE_SESSION_FILE; pass explicit boardId objectId output.json. This test moves the selected test object by (+30,+20).');
const client=new Client({name:'freeform-native-live-test',version:'1.0.0'});
const transport=new StdioClientTransport({command:process.execPath,args:[fileURLToPath(new URL('../src/server.mjs',import.meta.url))],env:{...process.env,FREEFORM_NATIVE_SESSION_FILE:sessionFile},stderr:'pipe'});
const evidence={boardId,objectId,manualEditRequired:false};
const call=async(name,args={})=>client.callTool({name,arguments:args});
const value=r=>{assert.notEqual(r.isError,true,JSON.stringify(r));return r.structuredContent;};
try{
 await client.connect(transport);
 evidence.tools=(await client.listTools()).tools.map(t=>t.name);
 evidence.status=value(await call('freeform_native_status'));
 assert.equal(evidence.status.labOnly,true);
 evidence.boards=value(await call('freeform_native_list_boards'));
 assert.ok(evidence.boards.boards.some(b=>b.id===boardId));
 evidence.before=value(await call('freeform_native_list_objects',{boardId}));
 const object=evidence.before.objects.find(o=>o.id===objectId);assert.ok(object);assert.ok(object.writable);
 const request={boardId,objectId,x:object.geometry.x+30,y:object.geometry.y+20,expectedGeometry:object.geometry};
 evidence.move=value(await call('freeform_native_move_object',request));
 assert.equal(evidence.move.after.x,request.x);assert.equal(evidence.move.after.y,request.y);
 evidence.stale=await call('freeform_native_move_object',request);
 assert.equal(evidence.stale.isError,true);assert.match(evidence.stale.content[0].text,/stale_geometry/);
 evidence.wrongObject=await call('freeform_native_move_object',{...request,objectId:'00000000-0000-0000-0000-000000000000',expectedGeometry:evidence.move.after});
 assert.equal(evidence.wrongObject.isError,true);assert.match(evidence.wrongObject.content[0].text,/object_not_found/);
 evidence.after=value(await call('freeform_native_list_objects',{boardId}));
 assert.deepEqual(evidence.after.objects.find(o=>o.id===objectId).geometry,evidence.move.after);
 evidence.passed=true;
 await writeFile(output,JSON.stringify(evidence,null,2)+'\n');
 console.log(JSON.stringify({passed:true,before:object.geometry,after:evidence.move.after,staleRejected:true,wrongObjectRejected:true,tools:evidence.tools},null,2));
}finally{await client.close();}
