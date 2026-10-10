#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Observe moves in the isolated lab process. The hook always forwards to the
// original implementation and neither schedules nor performs an additional move.
typedef void (*FFMoveIMP)(id, SEL, id, CGPoint, CGSize);
static FFMoveIMP FFOriginalMove;
static __weak id FFObservedItem;
static __weak id FFObservedBoard;
static CGPoint FFObservedPosition;
static CGSize FFObservedSize;
static atomic_bool FFLoggedFirstMove = false;
static atomic_ulong FFMoveSequence = 0;

static void FFMovementLog(NSDictionary *record) {
    const char *path = getenv("FF_PROBE_LOG");
    if (!path || path[0] != '/') return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    // One append syscall keeps each record together with other probe writers.
    (void)write(fd, line.bytes, line.length);
    close(fd);
}

static NSDictionary *FFMoveImplementationLocation(IMP implementation) {
    void *address = (void *)implementation;
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    Dl_info info = {0};
    if (!dladdr(address, &info)) return @{};
    NSMutableDictionary *result = [@{
        @"image": info.dli_fname ? @(info.dli_fname) : @"",
        @"image_offset": @((uintptr_t)address - (uintptr_t)info.dli_fbase),
        @"symbol": info.dli_sname ? @(info.dli_sname) : @""
    } mutableCopy];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (_dyld_get_image_header(i) == info.dli_fbase) {
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            result[@"slide"] = @(slide);
            result[@"unslid_address"] = @((uintptr_t)address - slide);
            break;
        }
    }
    return result;
}

static void FFObserveMove(id receiver, SEL selector, id board, CGPoint position, CGSize size) {
    unsigned long sequence = atomic_fetch_add(&FFMoveSequence, 1) + 1;
    @autoreleasepool {
        BOOL main = [NSThread isMainThread];
        // Weak references avoid extending the board or item's lifetime. No
        // off-main reference is promoted into the main-thread observation state.
        if (main) {
            FFObservedItem = receiver;
            FFObservedBoard = board;
            FFObservedPosition = position;
            FFObservedSize = size;
        }
        NSMutableDictionary *event = [@{
            @"event": @"movement_call", @"sequence": @(sequence),
            @"main_thread": @(main),
            @"item_class": receiver ? @(object_getClassName(receiver)) : @"",
            @"board_class": board ? @(object_getClassName(board)) : @"",
            @"position": @{@"x": @(position.x), @"y": @(position.y)},
            @"size": @{@"width": @(size.width), @"height": @(size.height)}
        } mutableCopy];
        if (!atomic_exchange(&FFLoggedFirstMove, true)) {
            event[@"call_stack"] = [NSThread callStackSymbols];
        }
        FFMovementLog(event);
    }
    FFOriginalMove(receiver, selector, board, position, size);
    FFMovementLog(@{@"event": @"movement_return", @"sequence": @(sequence)});
}

static __weak id FFObservedController;
id FFMovementObservedItem(void) { NSCAssert([NSThread isMainThread], @"main thread"); return FFObservedItem; }
id FFMovementObservedController(void) { NSCAssert([NSThread isMainThread], @"main thread"); return FFObservedController; }
static void (*OriginalGeometry)(id,SEL,id);
static void ObserveGeometry(id receiver,SEL selector,id geometry) {
 if([NSThread isMainThread])FFObservedItem=receiver;
 FFMovementLog(@{@"event":@"geometry_set",@"item_class":@(object_getClassName(receiver)),@"geometry_class":@(object_getClassName(geometry))});
 OriginalGeometry(receiver,selector,geometry);
}
static void (*OriginalEnqueue)(id,SEL,id);
static void (*OriginalEnqueueSelection)(id,SEL,id,id);
static void ObserveEnqueue(id receiver,SEL selector,id command) {
 if([NSThread isMainThread])FFObservedController=receiver;
 FFMovementLog(@{@"event":@"command_enqueue",@"command_class":@(object_getClassName(command))});
 OriginalEnqueue(receiver,selector,command);
}
static void ObserveEnqueueSelection(id receiver,SEL selector,id command,id selection) {
 if([NSThread isMainThread])FFObservedController=receiver;
 FFMovementLog(@{@"event":@"command_enqueue_selection",@"command_class":@(object_getClassName(command))});
 OriginalEnqueueSelection(receiver,selector,command,selection);
}
typedef id __attribute__((ns_returns_retained)) (*CommandInitIMP)(id __attribute__((ns_consumed)),SEL,id,id);
static CommandInitIMP OriginalCommandInit;
static id ObserveCommandInit(id receiver __attribute__((ns_consumed)),SEL selector,id item,id geometry) __attribute__((ns_returns_retained));
static id ObserveCommandInit(id receiver __attribute__((ns_consumed)),SEL selector,id item,id geometry) {
 if([NSThread isMainThread])FFObservedItem=item;
 FFMovementLog(@{@"event":@"geometry_command_created",@"item_class":@(object_getClassName(item)),@"geometry_class":@(object_getClassName(geometry))});
 return OriginalCommandInit(receiver,selector,item,geometry);
}
static IMP Hook(const char *className,const char *selectorName,const char *encoding,IMP replacement) {
 Class cls=objc_getClass(className); SEL selector=sel_registerName(selectorName);
 Method m=cls?class_getInstanceMethod(cls,selector):NULL;
 if(!m || strcmp(method_getTypeEncoding(m),encoding)) {FFMovementLog(@{@"event":@"capture_hook_rejected",@"class":@(className),@"selector":@(selectorName),@"encoding":m?@(method_getTypeEncoding(m)):@""});return NULL;}
 IMP original=method_getImplementation(m);method_setImplementation(m,replacement);
 FFMovementLog(@{@"event":@"capture_hook_installed",@"class":@(className),@"selector":@(selectorName)});return original;
}
static void Inventory(const char *className) {
 Class cls=objc_getClass(className);unsigned count=0; Method *methods=class_copyMethodList(cls,&count);
 FFMovementLog(@{@"event":@"capture_class",@"class":@(className),@"present":@(cls!=Nil)});
 for(unsigned i=0;i<count;i++) FFMovementLog(@{@"event":@"capture_method",@"class":@(className),@"selector":@(sel_getName(method_getName(methods[i]))),@"encoding":@(method_getTypeEncoding(methods[i]))});
 free(methods);
}
// Parent calls this once after installing offline startup isolation.
void FFMovementStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Inventory("CRLCommandController"); Inventory("Freeform.CRLCommandSetInfoGeometry"); Inventory("CRLCanvasInfoGeometry"); Inventory("CRLMutableCanvasInfoGeometry");
        OriginalGeometry=(void(*)(id,SEL,id))Hook("Freeform.CRLBoardItemBase","setGeometry:","v24@0:8@16",(IMP)ObserveGeometry);
        OriginalEnqueue=(void(*)(id,SEL,id))Hook("CRLCommandController","enqueueCommand:","v24@0:8@16",(IMP)ObserveEnqueue);
        OriginalEnqueueSelection=(void(*)(id,SEL,id,id))Hook("CRLCommandController","enqueueCommand:withSelectionBehavior:","v32@0:8@16@24",(IMP)ObserveEnqueueSelection);
        OriginalCommandInit=(CommandInitIMP)Hook("Freeform.CRLCommandSetInfoGeometry","initWithBoardItem:geometry:","@32@0:8@16@24",(IMP)ObserveCommandInit);
        Class cls = objc_getClass("Freeform.CRLBoardItem");
        if (!cls) cls = objc_getClass("_TtC8Freeform12CRLBoardItem");
        SEL selector = sel_registerName("crl_onBoard:moveItemToPosition:size:");
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || strcmp(encoding, "v56@0:8@16{CGPoint=dd}24{CGSize=dd}40")) {
            FFMovementLog(@{@"event": @"movement_hook_rejected",
                @"reason": @"missing_or_unexpected_abi",
                @"encoding": encoding ? @(encoding) : @""});
            return;
        }
        IMP original = method_getImplementation(method);
        FFOriginalMove = (FFMoveIMP)original;
        method_setImplementation(method, (IMP)FFObserveMove);
        FFMovementLog(@{@"event": @"movement_hook_installed",
            @"class": @(class_getName(cls)), @"selector": NSStringFromSelector(selector),
            @"encoding": @(encoding), @"original": FFMoveImplementationLocation(original)});
    });
}
