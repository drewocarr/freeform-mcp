#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <dlfcn.h>

static int calls;
static void FixtureFinishLaunching(id receiver, SEL selector) {
    (void)receiver; (void)selector;
    calls++;
}

int main(void) {
    @autoreleasepool {
        Method method = class_getInstanceMethod([NSApplication class], @selector(finishLaunching));
        method_setImplementation(method, (IMP)FixtureFinishLaunching);
        void (*install)(void) = dlsym(RTLD_DEFAULT, "FFProbeInstallHook");
        if (!install) return 2;
        install();
        // Invoke directly with a nil receiver; the inert fixture IMP reads no state.
        IMP implementation = class_getMethodImplementation([NSApplication class], @selector(finishLaunching));
        ((void (*)(id, SEL))implementation)(nil, @selector(finishLaunching));
        printf("fixture_original_calls=%d\n", calls);
        return calls == 1 ? 0 : 1;
    }
}
