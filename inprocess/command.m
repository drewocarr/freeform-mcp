#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "discovery.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>

static NSString *const TransportRoot=@"/Users/drewcarr/freeform-bridge-research/inprocess/lab/data/transport";
static NSString *SessionID,*RequestDirectory,*ResponseDirectory;
static NSMutableSet *ProcessedIDs;
static void Log(NSDictionary *event) {
 const char *path=getenv("FF_PROBE_LOG");if(!path)return;
 NSData *json=[NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];if(!json)return;
 NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];
 int fd=open(path,O_WRONLY|O_APPEND|O_NOFOLLOW);if(fd<0)return;write(fd,line.bytes,line.length);close(fd);
}
static BOOL ABI(id object,SEL selector,const char *expected) {
 Method method=object?class_getInstanceMethod(object_getClass(object),selector):NULL;
 return method && !strcmp(method_getTypeEncoding(method),expected);
}
static id Get(id object,SEL selector) {return ((id(*)(id,SEL))objc_msgSend)(object,selector);}
static NSDictionary *Failure(NSString *code,NSString *message) {return @{@"ok":@NO,@"error":@{@"code":code,@"message":message}};}
static NSDictionary *Success(NSDictionary *result) {return @{@"ok":@YES,@"result":result};}
static BOOL Number(id value,double limit) {return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && fabs([value doubleValue])<=limit;}
static NSDictionary *Geometry(id item) {
 SEL gs=sel_registerName("geometry");if(!ABI(item,gs,"@16@0:8"))return nil;
 id g=Get(item,gs);
 if(!ABI(g,sel_registerName("position"),"{CGPoint=dd}16@0:8") || !ABI(g,sel_registerName("size"),"{CGSize=dd}16@0:8"))return nil;
 CGPoint p=((CGPoint(*)(id,SEL))objc_msgSend)(g,sel_registerName("position"));
 CGSize s=((CGSize(*)(id,SEL))objc_msgSend)(g,sel_registerName("size"));
 if(!isfinite(p.x)||!isfinite(p.y)||!isfinite(s.width)||!isfinite(s.height))return nil;
 return @{@"x":@(p.x),@"y":@(p.y),@"width":@(s.width),@"height":@(s.height)};
}
static BOOL SameGeometry(NSDictionary *a,NSDictionary *b) {
 if(![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class])return NO;
 for(NSString *key in @[@"x",@"y",@"width",@"height"])if(!Number(a[key],1e9)||!Number(b[key],1e9)||fabs([a[key] doubleValue]-[b[key] doubleValue])>1e-6)return NO;
 return YES;
}
typedef id __attribute__((ns_returns_retained)) (*InitIMP)(id __attribute__((ns_consumed)),SEL,id,id);
static NSDictionary *Execute(NSDictionary *request) {
 NSCAssert(NSThread.isMainThread,@"Native requests require the main thread");
 NSString *action=request[@"action"];
 if([action isEqual:@"status"])return Success(@{@"configured":@YES,@"available":@YES,@"labOnly":@YES,@"scope":@"open_boards",@"sessionId":SessionID,@"pid":@(getpid()),@"capabilities":@[@"list_boards",@"list_objects",@"move_object"],@"boards":FFDiscoveryListBoards()});
 if([action isEqual:@"list_boards"])return Success(@{@"boards":FFDiscoveryListBoards(),@"scope":@"open_boards"});
 NSString *boardID=request[@"boardId"];
 if(![boardID isKindOfClass:NSString.class])return Failure(@"invalid_board_id",@"An explicit boardId is required.");
 id controller=FFDiscoveryController(boardID);
 if(!controller)return Failure(@"board_not_open",@"Open the requested board in the isolated lab app first.");
 if([action isEqual:@"list_objects"]) {
  NSString *error=nil;NSArray *objects=FFDiscoveryListObjects(boardID,&error);
  return objects?Success(@{@"boardId":boardID,@"objects":objects}):Failure(error?:@"discovery_failed",@"Could not enumerate this board.");
 }
 if(![action isEqual:@"move_object"])return Failure(@"unsupported_action",@"This action is not available.");
 NSString *objectID=request[@"objectId"];
 id item=FFDiscoveryItem(boardID,objectID);
 if(!item)return Failure(@"object_not_found",@"The object is not present on the specified board.");
 SEL parent=sel_registerName("parentBoard"),boardSel=sel_registerName("board");
 if(!ABI(item,parent,"@16@0:8")||!ABI(controller,boardSel,"@16@0:8"))return Failure(@"board_abi_mismatch",@"Board identity cannot be verified.");
 id board=Get(controller,boardSel);
 if(!board || Get(item,parent)!=board)return Failure(@"board_identity_mismatch",@"The live object and controller do not belong to the same board.");
 SEL group=sel_registerName("isGroupOpen");
 if(!ABI(controller,group,"B16@0:8"))return Failure(@"transaction_abi_mismatch",@"Cannot establish whether the editor is idle.");
 if(((BOOL(*)(id,SEL))objc_msgSend)(controller,group))return Failure(@"editor_busy",@"An edit group is open. Finish the current edit and inspect again.");
 SEL locked=sel_registerName("locked");
 if(ABI(item,locked,"B16@0:8") && ((BOOL(*)(id,SEL))objc_msgSend)(item,locked))return Failure(@"object_locked",@"The object is locked.");
 if(!Number(request[@"x"],100000)||!Number(request[@"y"],100000))return Failure(@"invalid_position",@"Position must be finite and within 100000 points.");
 NSDictionary *before=Geometry(item);
 if(!before)return Failure(@"unsupported_geometry",@"The object's geometry cannot be read with the supported ABI.");
 if(!SameGeometry(before,request[@"expectedGeometry"]))return Failure(@"stale_geometry",@"The object changed since it was read. List objects again before editing.");
 CGPoint target=CGPointMake([request[@"x"] doubleValue],[request[@"y"] doubleValue]);
 if(fabs(target.x-[before[@"x"] doubleValue])<1e-6 && fabs(target.y-[before[@"y"] doubleValue])<1e-6)return Success(@{@"boardId":boardID,@"objectId":objectID,@"before":before,@"after":before,@"changed":@NO});
 id geometry=[Get(item,sel_registerName("geometry")) mutableCopy];
 SEL setPosition=sel_registerName("setPosition:"),init=sel_registerName("initWithBoardItem:geometry:"),enqueue=sel_registerName("enqueueCommand:");
 Class cls=objc_getClass("Freeform.CRLCommandSetInfoGeometry");Method constructor=cls?class_getInstanceMethod(cls,init):NULL;
 if(!ABI(geometry,setPosition,"v32@0:8{CGPoint=dd}16")||!constructor||strcmp(method_getTypeEncoding(constructor),"@32@0:8@16@24")||!ABI(controller,enqueue,"v24@0:8@16"))return Failure(@"command_abi_mismatch",@"Native geometry command is unavailable.");
 ((void(*)(id,SEL,CGPoint))objc_msgSend)(geometry,setPosition,target);
 id command=((InitIMP)objc_msgSend)([cls alloc],init,item,geometry);
 if(!command)return Failure(@"command_initialization_failed",@"No command was created.");
 Log(@{@"event":@"native_command_submit",@"id":request[@"id"],@"boardId":boardID,@"objectId":objectID,@"before":before,@"target":@{@"x":@(target.x),@"y":@(target.y)}});
 ((void(*)(id,SEL,id))objc_msgSend)(controller,enqueue,command);
 NSDictionary *after=Geometry(item);
 if(!after || fabs([after[@"x"] doubleValue]-target.x)>1e-6 || fabs([after[@"y"] doubleValue]-target.y)>1e-6)return Failure(@"verification_failed",@"The native command returned but position verification failed. Outcome may have changed; do not retry automatically.");
 return Success(@{@"boardId":boardID,@"objectId":objectID,@"before":before,@"after":after,@"changed":@YES});
}
static BOOL SaveJSON(NSDictionary *value,NSString *path) {
 NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];if(!data)return NO;
 NSString *temporary=[path stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
 int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return NO;
 const char *p=data.bytes;size_t remaining=data.length;BOOL okay=YES;
 while(remaining){ssize_t n=write(fd,p,remaining);if(n<=0){okay=NO;break;}p+=n;remaining-=n;}
 close(fd);if(okay)okay=rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)==0;
 if(!okay)unlink(temporary.fileSystemRepresentation);return okay;
}
static void Poll(void) {
 NSArray *files=[[[NSFileManager defaultManager] contentsOfDirectoryAtPath:RequestDirectory error:NULL] sortedArrayUsingSelector:@selector(compare:)];
 NSUInteger count=0;
 for(NSString *file in files) {
  if(![file.pathExtension isEqual:@"json"] || ++count>32)continue;
  NSString *identifier=file.stringByDeletingPathExtension;
  if(![[NSUUID alloc] initWithUUIDString:identifier])continue;
  NSString *path=[RequestDirectory stringByAppendingPathComponent:file];
  int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)continue;
  struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>16384){close(fd);unlink(path.fileSystemRepresentation);continue;}
  NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];ssize_t n=read(fd,data.mutableBytes,data.length);close(fd);
  if(n!=(ssize_t)data.length)continue;
  id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  // Claim once before execution. A crash after this point is an unknown outcome,
  // never a reason for this process or a later session to replay the request.
  if(unlink(path.fileSystemRepresentation)!=0)continue;
  if([ProcessedIDs containsObject:identifier])continue;
  [ProcessedIDs addObject:identifier];
  NSDictionary *response;
  if(![request isKindOfClass:NSDictionary.class]||![request[@"id"] isEqual:identifier])response=Failure(@"invalid_request",@"Request ID must match its filename.");
  else if(![request[@"sessionId"] isEqual:SessionID])response=Failure(@"session_mismatch",@"Request belongs to a different lab process.");
  else if(!Number(request[@"expiresAt"],1e15)||[request[@"expiresAt"] doubleValue]<NSDate.date.timeIntervalSince1970*1000)response=Failure(@"request_expired",@"The request expired before execution; no edit was attempted.");
  else { @try {response=Execute(request);} @catch(NSException *e){response=Failure(@"native_exception",e.reason?:@"Native exception; inspect state before retrying.");} }
  NSMutableDictionary *wire=[response mutableCopy];wire[@"id"]=identifier;wire[@"sessionId"]=SessionID;
  SaveJSON(wire,[ResponseDirectory stringByAppendingPathComponent:file]);
  Log(@{@"event":@"native_response",@"response":wire});
 }
}
void FFCommandStart(void) {
 static dispatch_source_t timer;
 FFDiscoveryStart();SessionID=NSUUID.UUID.UUIDString;ProcessedIDs=[NSMutableSet set];
 NSString *sessionRoot=[[TransportRoot stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:SessionID];
 RequestDirectory=[sessionRoot stringByAppendingPathComponent:@"requests"];ResponseDirectory=[sessionRoot stringByAppendingPathComponent:@"responses"];
 for(NSString *path in @[TransportRoot,sessionRoot,RequestDirectory,ResponseDirectory]) {
  NSError *error=nil;[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
  if(error){Log(@{@"event":@"transport_setup_failed",@"reason":error.localizedDescription});return;}
  chmod(path.fileSystemRepresentation,0700);
 }
 NSDictionary *manifest=@{@"protocolVersion":@1,@"sessionId":SessionID,@"pid":@(getpid()),@"labOnly":@YES,@"requestDirectory":RequestDirectory,@"responseDirectory":ResponseDirectory};
 if(!SaveJSON(manifest,[TransportRoot stringByAppendingPathComponent:@"session.json"])){Log(@{@"event":@"transport_setup_failed",@"reason":@"manifest_write_failed"});return;}
 timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
 dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),NSEC_PER_SEC/10,NSEC_PER_SEC/50);
 dispatch_source_set_event_handler(timer,^{Poll();});dispatch_resume(timer);
 Log(@{@"event":@"native_transport_started",@"manifest":[TransportRoot stringByAppendingPathComponent:@"session.json"],@"sessionId":SessionID});
}
