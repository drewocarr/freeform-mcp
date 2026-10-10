#import "discovery.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <string.h>

static NSHashTable *Controllers;
typedef id __attribute__((ns_returns_retained)) (*InitIMP)(id __attribute__((ns_consumed)), SEL, id, id, id);
static InitIMP OriginalInit;
static void Log(NSDictionary *record) {
 const char *path=getenv("FF_PROBE_LOG"); if(!path)return;
 NSData *json=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];if(!json)return;
 NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];
 int fd=open(path,O_WRONLY|O_APPEND|O_NOFOLLOW);if(fd<0)return;write(fd,line.bytes,line.length);close(fd);
}
static BOOL ABI(id object, const char *name, const char *encoding) {
 Method m=object?class_getInstanceMethod(object_getClass(object),sel_registerName(name)):NULL;
 return m && !strcmp(method_getTypeEncoding(m),encoding);
}
static id Get(id object, const char *name) {
 if(!ABI(object,name,"@16@0:8"))return nil;
 return ((id(*)(id,SEL))objc_msgSend)(object,sel_registerName(name));
}
static NSString *Identifier(id object) {
 id value=Get(object,"id");
 return [value isKindOfClass:NSUUID.class]?[value UUIDString]:nil;
}
static void Register(id controller) {
 NSCAssert(NSThread.isMainThread,@"Discovery requires main thread");
 if(controller) { [Controllers addObject:controller]; Log(@{@"event":@"discovery_controller_captured",@"controller_class":@(object_getClassName(controller))}); }
}
static id ObserveInit(id receiver __attribute__((ns_consumed)),SEL selector,id board,id notifier,id dispatcher) __attribute__((ns_returns_retained));
static id ObserveInit(id receiver __attribute__((ns_consumed)),SEL selector,id board,id notifier,id dispatcher) {
 id result=OriginalInit(receiver,selector,board,notifier,dispatcher);
 if(NSThread.isMainThread)Register(result);
 else { __weak id weakResult=result; dispatch_async(dispatch_get_main_queue(),^{Register(weakResult);}); }
 return result;
}
void FFDiscoveryStart(void) {
 static dispatch_once_t once;dispatch_once(&once,^{
  Controllers=[NSHashTable weakObjectsHashTable];
  Class cls=objc_getClass("CRLCommandController");SEL selector=sel_registerName("initWithBoard:changeNotifier:selectionDispatcher:");
  Method m=cls?class_getInstanceMethod(cls,selector):NULL;
  if(!m || strcmp(method_getTypeEncoding(m),"@40@0:8@16@24@32")) {
   Log(@{@"event":@"discovery_hook_rejected",@"encoding":m?@(method_getTypeEncoding(m)):@"missing"});return;
  }
  OriginalInit=(InitIMP)method_getImplementation(m);method_setImplementation(m,(IMP)ObserveInit);
  Log(@{@"event":@"discovery_hook_installed"});
 });
}
id FFDiscoveryController(NSString *boardID) {
 NSCAssert(NSThread.isMainThread,@"Discovery requires main thread");
 if(![boardID isKindOfClass:NSString.class])return nil;
 for(id c in Controllers.allObjects)if([Identifier(Get(c,"board")) isEqual:boardID])return c;
 return nil;
}
NSArray *FFDiscoveryListBoards(void) {
 NSCAssert(NSThread.isMainThread,@"Discovery requires main thread");
 NSMutableDictionary *unique=[NSMutableDictionary dictionary];
 for(id c in Controllers.allObjects) {
  id board=Get(c,"board");NSString *identifier=Identifier(board);if(!identifier)continue;
  id title=Get(board,"title");id items=Get(board,"items");
  NSMutableDictionary *entry=[@{@"id":identifier,@"title":[title isKindOfClass:NSString.class]?title:@"",@"scope":@"open_board"} mutableCopy];
  if([items isKindOfClass:NSDictionary.class])entry[@"objectCount"]=@([items count]);
  unique[identifier]=entry;
 }
 return [[unique allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"id"] compare:b[@"id"]];}];
}
static NSDictionary *Items(NSString *boardID, NSString **error) {
 id controller=FFDiscoveryController(boardID);if(!controller){if(error)*error=@"board_not_open";return nil;}
 id value=Get(Get(controller,"board"),"items");
 if(![value isKindOfClass:NSDictionary.class]){if(error)*error=@"board_items_unavailable";return nil;}
 return value;
}
id FFDiscoveryItem(NSString *boardID, NSString *objectID) {
 NSCAssert(NSThread.isMainThread,@"Discovery requires main thread");
 if(![objectID isKindOfClass:NSString.class])return nil;
 id board=Get(FFDiscoveryController(boardID),"board");
 for(id item in Items(boardID,NULL).allValues)if([Identifier(item) isEqual:objectID] && Get(item,"parentBoard")==board)return item;
 return nil;
}
NSArray *FFDiscoveryListObjects(NSString *boardID, NSString **error) {
 NSCAssert(NSThread.isMainThread,@"Discovery requires main thread");
 NSDictionary *items=Items(boardID,error);if(!items)return nil;
 NSMutableArray *result=[NSMutableArray array];
 for(id item in items.allValues) {
  NSString *identifier=Identifier(item);if(!identifier)continue;
  NSMutableDictionary *entry=[@{@"id":identifier,@"boardId":boardID,@"className":@(object_getClassName(item))} mutableCopy];
  id geometry=Get(item,"geometry");
  if(ABI(geometry,"position","{CGPoint=dd}16@0:8") && ABI(geometry,"size","{CGSize=dd}16@0:8")) {
   CGPoint p=((CGPoint(*)(id,SEL))objc_msgSend)(geometry,sel_registerName("position"));
   CGSize s=((CGSize(*)(id,SEL))objc_msgSend)(geometry,sel_registerName("size"));
   if(isfinite(p.x)&&isfinite(p.y)&&isfinite(s.width)&&isfinite(s.height))entry[@"geometry"]=@{@"x":@(p.x),@"y":@(p.y),@"width":@(s.width),@"height":@(s.height)};
  }
  if(ABI(item,"locked","B16@0:8"))entry[@"locked"]=@(((BOOL(*)(id,SEL))objc_msgSend)(item,sel_registerName("locked")));
  id controller=FFDiscoveryController(boardID);
  BOOL member=Get(item,"parentBoard")==Get(controller,"board");
  entry[@"writable"]=@(member && entry[@"geometry"] && ABI(controller,"enqueueCommand:","v24@0:8@16") && ![entry[@"locked"] boolValue]);
  [result addObject:entry];
 }
 return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"id"] compare:b[@"id"]];}];
}
