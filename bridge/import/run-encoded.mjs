import {readFile,writeFile} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const [title,path,out]=process.argv.slice(2);
if(!title||!path||!out) throw new Error('Supply exact board title, encoded objects file, and evidence output');
const objects=JSON.parse(await readFile(path));
const executable=fileURLToPath(new URL('../bin/freeform-bridge',import.meta.url));
const evidence={title,source:path,startedAt:new Date().toISOString(),expectedCount:objects.length};
try {
 const result=await new Promise((resolve,reject)=>{
  const child=execFile(executable,[],{timeout:180000,maxBuffer:32000000},(error,stdout)=>{
   try { const value=JSON.parse(stdout); evidence.result=value; if(error||!value.ok) reject(new Error(value.error||error?.message)); else resolve(value); }
   catch(e){reject(e)}
  });
  child.stdin.end(JSON.stringify({command:process.argv[5]==='--read'?'readSelection':'insert',expectedBoardTitle:title,objects,fitAfterPaste:true,selectAll:process.argv[5]==='--read'}));
 });
 assert.equal(result.objects.length,objects.length);
 assert.equal(result.clipboardRestored,true);
 const pos=o=>o.geometry.position;
 const text=o=>{const s=o.text?.attributed_string?.[0]??'';return s==='\u200b'?'':s};
 const dx=Math.min(...result.objects.map(o=>pos(o).x))-Math.min(...objects.map(o=>pos(o).x));
 const dy=Math.min(...result.objects.map(o=>pos(o).y))-Math.min(...objects.map(o=>pos(o).y));
 const remaining=[...result.objects];
 for(const expected of objects){
  const i=remaining.findIndex(o=>text(o)===text(expected)&&Math.abs(pos(o).x-pos(expected).x-dx)<.01&&Math.abs(pos(o).y-pos(expected).y-dy)<.01&&Math.abs(o.geometry.size.width-expected.geometry.size.width)<.01&&Math.abs(o.geometry.size.height-expected.geometry.size.height)<.01);
  assert.ok(i>=0,'Missing or altered text/geometry: '+text(expected).slice(0,100));remaining.splice(i,1);
 }
 evidence.translation={x:dx,y:dy};evidence.verified=true;
}catch(error){evidence.error=error.message;process.exitCode=1;}
await writeFile(out,JSON.stringify(evidence));
console.log(JSON.stringify({title,verified:evidence.verified??false,count:evidence.result?.objects?.length,error:evidence.error,clipboardRestored:evidence.result?.clipboardRestored}));
