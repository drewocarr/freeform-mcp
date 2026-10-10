#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

// This probe emits runtime metadata only. It never reads boards or documents.
static void FFWrite(NSDictionary *record) {
    const char *path = getenv("FF_PROBE_LOG");
    if (!path || path[0] != '/') return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    const char *bytes = line.bytes;
    size_t remaining = line.length;
    while (remaining) {
        ssize_t n = write(fd, bytes, remaining);
        if (n <= 0) break;
        bytes += n;
        remaining -= (size_t)n;
    }
    close(fd);
}

static BOOL FFEnabled(const char *name) {
    const char *value = getenv(name);
    return value && strcmp(value, "1") == 0;
}

static void (*FFOriginalFinishLaunching)(id, SEL);
static void FFFinishLaunching(id receiver, SEL selector) {
    @autoreleasepool {
        FFWrite(@{@"event": @"hook_called", @"class": @"NSApplication",
                  @"selector": @"finishLaunching", @"pid": @(getpid())});
    }
    FFOriginalFinishLaunching(receiver, selector);
    @autoreleasepool {
        FFWrite(@{@"event": @"hook_return", @"class": @"NSApplication",
                  @"selector": @"finishLaunching", @"pid": @(getpid())});
    }
}

// init consumes its receiver and returns a retained object under ARC. Preserve
// that ownership convention as well as the Objective-C runtime ABI.
typedef id __attribute__((ns_returns_retained)) (*FFInitIMP)(id __attribute__((ns_consumed)), SEL);
static FFInitIMP FFOriginalPasteboardInit;
static id FFPasteboardInit(id receiver __attribute__((ns_consumed)), SEL selector)
    __attribute__((ns_returns_retained));
static id FFPasteboardInit(id receiver __attribute__((ns_consumed)), SEL selector) {
    @autoreleasepool {
        FFWrite(@{@"event": @"hook_called", @"class": @"CRLPasteboardController",
                  @"selector": @"init", @"pid": @(getpid())});
    }
    id result = FFOriginalPasteboardInit(receiver, selector);
    @autoreleasepool {
        FFWrite(@{@"event": @"hook_return", @"class": @"CRLPasteboardController",
                  @"selector": @"init", @"pid": @(getpid())});
    }
    return result;
}

static void FFInstallFreeformHook(void) {
    Class cls = objc_getClass("CRLPasteboardController");
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName("init")) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    // This exact signature was observed in the cloned Freeform runtime.
    if (!encoding || strcmp(encoding, "@16@0:8") != 0) {
        FFWrite(@{@"event": @"hook_rejected", @"class": @"CRLPasteboardController",
                  @"selector": @"init", @"reason": @"missing_or_unexpected_abi",
                  @"encoding": encoding ? @(encoding) : @""});
        return;
    }
    if (method_getImplementation(method) == (IMP)FFPasteboardInit) return;
    FFOriginalPasteboardInit = (FFInitIMP)method_getImplementation(method);
    method_setImplementation(method, (IMP)FFPasteboardInit);
    FFWrite(@{@"event": @"hook_installed", @"class": @"CRLPasteboardController",
              @"selector": @"init", @"encoding": @(encoding)});
}

static id (*FFOriginalDelegate)(id, SEL);
static unsigned FFDelegateHookCalls;
static unsigned FFDelegateOriginalCalls;
static id FFDelegateGetter(id receiver, SEL selector) {
    FFDelegateHookCalls++;
    FFWrite(@{@"event": @"hook_called", @"class": @"CRLPasteboardController",
              @"selector": @"delegate", @"synthetic_instance": @YES});
    FFDelegateOriginalCalls++;
    id result = FFOriginalDelegate(receiver, selector);
    FFWrite(@{@"event": @"hook_return", @"class": @"CRLPasteboardController",
              @"selector": @"delegate", @"synthetic_instance": @YES});
    return result;
}

static void FFRunSelftest(void) {
    Class cls = objc_getClass("CRLPasteboardController");
    SEL selector = sel_registerName("delegate");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    Ivar ivar = cls ? class_getInstanceVariable(cls, "_delegate") : NULL;
    objc_property_t property = cls ? class_getProperty(cls, "delegate") : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    const char *attributes = property ? property_getAttributes(property) : NULL;
    // The observed getter only loads a weak pointer at +64 and autoreleases it.
    // Refuse layouts/signatures that differ from the binary inspected offline.
    if (!cls || class_getSuperclass(cls) != objc_getClass("NSObject") ||
        !encoding || strcmp(encoding, "@16@0:8") || !ivar ||
        ivar_getOffset(ivar) != 64 || !attributes || !strstr(attributes, ",W,") ||
        !strstr(attributes, "V_delegate")) {
        FFWrite(@{@"event": @"selftest_rejected", @"reason": @"unexpected_getter_layout"});
        _exit(72);
    }
    IMP original = method_getImplementation(method);
    Dl_info location = {0};
    dladdr((const void *)original, &location);
    FFOriginalDelegate = (id (*)(id, SEL))original;
    method_setImplementation(method, (IMP)FFDelegateGetter);
    FFWrite(@{@"event": @"hook_installed", @"class": @"CRLPasteboardController",
              @"selector": @"delegate", @"encoding": @(encoding),
              @"original_image": location.dli_fname ? @(location.dli_fname) : @"",
              @"synthetic_instance": @YES});
    // Allocate zeroed instance storage without running Freeform's initializer.
    // Keep it alive until _exit; no app/document/cloud startup or destructor runs.
    static id synthetic;
    synthetic = class_createInstance(cls, 0);
    if (!synthetic) {
        method_setImplementation(method, original);
        FFWrite(@{@"event": @"selftest_rejected", @"reason": @"allocation_failed"});
        _exit(73);
    }
    id (*dispatch)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id result = dispatch(synthetic, selector);
    method_setImplementation(method, original);
    BOOL restored = method_getImplementation(method) == original;
    BOOL passed = result == nil && FFDelegateHookCalls == 1 &&
                  FFDelegateOriginalCalls == 1 && restored;
    FFWrite(@{@"event": @"selftest_result", @"passed": @(passed),
              @"synthetic_instance": @YES, @"result_was_nil": @(result == nil),
              @"hook_calls": @(FFDelegateHookCalls),
              @"original_calls": @(FFDelegateOriginalCalls), @"restored": @(restored)});
    _exit(passed ? 0 : 74);
}

void FFProbeInstallHook(void) {
    Method method = class_getInstanceMethod(objc_getClass("NSApplication"),
                                            sel_registerName("finishLaunching"));
    if (!method) {
        FFWrite(@{@"event": @"hook_rejected", @"reason": @"method_missing"});
        return;
    }
    char *returnType = method_copyReturnType(method);
    char *selfType = method_copyArgumentType(method, 0);
    char *cmdType = method_copyArgumentType(method, 1);
    BOOL matches = method_getNumberOfArguments(method) == 2 &&
        returnType && strcmp(returnType, "v") == 0 &&
        selfType && strcmp(selfType, "@") == 0 &&
        cmdType && strcmp(cmdType, ":") == 0;
    free(returnType); free(selfType); free(cmdType);
    const char *encoding = method_getTypeEncoding(method);
    if (!matches) {
        FFWrite(@{@"event": @"hook_rejected", @"reason": @"unexpected_abi",
                  @"encoding": encoding ? @(encoding) : @""});
        return;
    }
    if (method_getImplementation(method) == (IMP)FFFinishLaunching) {
        FFWrite(@{@"event": @"hook_already_installed"});
        return;
    }
    FFOriginalFinishLaunching = (void (*)(id, SEL))method_getImplementation(method);
    method_setImplementation(method, (IMP)FFFinishLaunching);
    FFWrite(@{@"event": @"hook_installed", @"class": @"NSApplication",
              @"selector": @"finishLaunching", @"encoding": @(encoding)});
}

static void FFInventoryClass(const char *name) {
    Class cls = objc_getClass(name);
    FFWrite(@{@"event": @"class", @"name": @(name), @"present": @(cls != Nil)});
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *selector = sel_getName(method_getName(methods[i]));
        const char *encoding = method_getTypeEncoding(methods[i]);
        FFWrite(@{@"event": @"method", @"class": @(name),
                  @"selector": selector ? @(selector) : @"",
                  @"encoding": encoding ? @(encoding) : @""});
    }
    free(methods);
}

extern void FFOfflineStart(void);

__attribute__((constructor)) static void FFProbeStart(void) {
    @autoreleasepool {
        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);
        char *path = calloc(size, 1);
        if (path) _NSGetExecutablePath(path, &size);
        FFWrite(@{@"event": @"loaded", @"pid": @(getpid()),
                  @"executable": path ? @(path) : @""});
        free(path);
        FFInventoryClass("CRLPasteboardController");
        FFInventoryClass("CRLBoardItem");
        FFInventoryClass("Freeform.CRLBoardItem");
        FFInventoryClass("_TtC8Freeform12CRLBoardItem");
        if (FFEnabled("FF_PROBE_HOOK")) FFProbeInstallHook();
        if (FFEnabled("FF_PROBE_FREEFORM_HOOK")) FFInstallFreeformHook();
        if (FFEnabled("FF_PROBE_SELFTEST")) FFRunSelftest();
        FFOfflineStart();
        if (FFEnabled("FF_PROBE_EXIT")) _exit(0);
    }
}
