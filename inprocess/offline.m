#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CloudKit/CloudKit.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

static void Record(NSDictionary *record) {
 const char *path=getenv("FF_PROBE_LOG"); if (!path) return;
 NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
 int fd=open(path,O_WRONLY|O_APPEND|O_NOFOLLOW); if(fd<0)return;
 NSMutableData *line=[data mutableCopy]; [line appendBytes:"\n" length:1];
 write(fd,line.bytes,line.length); close(fd);
}
static void Inventory(const char *name) {
 Class cls=objc_getClass(name); unsigned count=0;
 Method *methods=class_copyMethodList(cls,&count);
 for(unsigned i=0;i<count;i++) Record(@{@"event":@"offline_method",@"class":@(name),@"selector":@(sel_getName(method_getName(methods[i]))),@"encoding":@(method_getTypeEncoding(methods[i]))});
 free(methods);
}
static void Exception(NSException *exception) {
 Record(@{@"event":@"uncaught_exception",@"name":exception.name?:@"",@"reason":exception.reason?:@""});
}
// Deliberate offline test dependency. Unsupported calls stop the experiment;
// they are never forwarded to Apple's live CloudKit implementation.
@interface FFOfflineDatabase : NSObject
@property(nonatomic) CKDatabaseScope databaseScope;
@property(nonatomic,weak) id container;
@end
@implementation FFOfflineDatabase
- (CKDatabaseScope)scope { return self.databaseScope; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
 return [super methodSignatureForSelector:selector] ?: [CKDatabase instanceMethodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
 Record(@{@"event":@"offline_database_unsupported",@"selector":NSStringFromSelector(invocation.selector)}); _exit(78);
}
@end
@interface FFOfflineContainer : NSObject
@property(nonatomic,strong) id containerID;
@property(nonatomic,strong) id options;
@property(nonatomic,strong) FFOfflineDatabase *offlineDatabase;
@property(nonatomic,strong) FFOfflineDatabase *offlineSharedDatabase;
@end
@implementation FFOfflineContainer
- (id)privateCloudDatabase {
 if(!self.offlineDatabase) { self.offlineDatabase=[FFOfflineDatabase new]; self.offlineDatabase.databaseScope=CKDatabaseScopePrivate; self.offlineDatabase.container=self; }
 Record(@{@"event":@"offline_private_database"}); return self.offlineDatabase;
}
- (id)sharedCloudDatabase {
 if(!self.offlineSharedDatabase) { self.offlineSharedDatabase=[FFOfflineDatabase new]; self.offlineSharedDatabase.databaseScope=CKDatabaseScopeShared; self.offlineSharedDatabase.container=self; }
 Record(@{@"event":@"offline_shared_database"}); return self.offlineSharedDatabase;
}
- (void)pushEnvironmentWithCompletionHandler:(void (^)(NSString *,NSError *))completion {
 Record(@{@"event":@"offline_push_environment",@"status":@"not_authenticated"});
 dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,[NSError errorWithDomain:CKErrorDomain code:CKErrorNotAuthenticated userInfo:nil]); });
}
- (void)registerSystemSharingUIObserver:(id)observer {
 (void)observer; Record(@{@"event":@"offline_sharing_observer_ignored"});
}
- (id)deviceContext { Record(@{@"event":@"offline_device_context_unavailable"}); return nil; }
- (NSString *)containerIdentifier { return @"local.freeform.bridge.lab.offline"; }
- (void)accountStatusWithCompletionHandler:(void (^)(CKAccountStatus,NSError *))completion {
 Record(@{@"event":@"offline_account_status",@"status":@"no_account"});
 dispatch_async(dispatch_get_main_queue(), ^{ completion(CKAccountStatusNoAccount,nil); });
}
- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(CKRecordID *,NSError *))completion {
 Record(@{@"event":@"offline_user_record",@"status":@"not_authenticated"});
 dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,[NSError errorWithDomain:CKErrorDomain code:CKErrorNotAuthenticated userInfo:nil]); });
}
- (void)accountInfoWithCompletionHandler:(void (^)(id,NSError *))completion {
 Record(@{@"event":@"offline_account_info",@"status":@"not_authenticated"});
 dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,[NSError errorWithDomain:CKErrorDomain code:CKErrorNotAuthenticated userInfo:nil]); });
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
 return [super methodSignatureForSelector:selector] ?: [objc_getClass("CKContainer") instanceMethodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
 Record(@{@"event":@"offline_unsupported_call",@"selector":NSStringFromSelector(invocation.selector)});
 _exit(78);
}
@end
static id OfflineInit(id receiver __attribute__((ns_consumed)), SEL selector, id identifier, id options) __attribute__((ns_returns_retained));
static id OfflineInit(id receiver __attribute__((ns_consumed)), SEL selector, id identifier, id options) {
 (void)receiver; (void)selector;
 FFOfflineContainer *container=[FFOfflineContainer new]; container.containerID=identifier; container.options=options;
 Record(@{@"event":@"offline_container_created"});
 return container;
}
static id OfflineDefault(id receiver, SEL selector) {
 (void)receiver; (void)selector;
 static FFOfflineContainer *container; static dispatch_once_t once;
 dispatch_once(&once,^{ container=[FFOfflineContainer new]; });
 Record(@{@"event":@"offline_default_container"}); return container;
}
static void InstallOfflineContainer(void) {
 Method method=class_getInstanceMethod(objc_getClass("CKContainer"),sel_registerName("initWithContainerID:options:"));
 if (!method || strcmp(method_getTypeEncoding(method),"@32@0:8@16@24")) {Record(@{@"event":@"offline_abi_rejected"});_exit(79);}
 method_setImplementation(method,(IMP)OfflineInit);
 Method defaultMethod=class_getClassMethod(objc_getClass("CKContainer"),sel_registerName("defaultContainer"));
 if (!defaultMethod || strcmp(method_getTypeEncoding(defaultMethod),"@16@0:8")) _exit(79);
 method_setImplementation(defaultMethod,(IMP)OfflineDefault);
 Record(@{@"event":@"offline_container_hook_installed"});
}
static NSString *const LabRoot=@"/Users/drewcarr/freeform-bridge-research/inprocess/lab/data";
static NSURL *GroupURL(id receiver, SEL selector, NSString *identifier) {
 (void)receiver;(void)selector;
 NSString *safe=[[identifier componentsSeparatedByCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet]] componentsJoinedByString:@"_"];
 NSURL *url=[NSURL fileURLWithPath:[[LabRoot stringByAppendingPathComponent:@"groups"] stringByAppendingPathComponent:safe] isDirectory:YES];
 NSError *error=nil; [[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&error];
 Record(@{@"event":@"offline_group_url",@"group":identifier?:@"",@"path":url.path,@"created":@(error==nil)});
 return error?nil:url;
}
static void InstallStorage(void) {
 Method method=class_getInstanceMethod([NSFileManager class],@selector(containerURLForSecurityApplicationGroupIdentifier:));
 if(!method || strcmp(method_getTypeEncoding(method),"@24@0:8@16"))_exit(79);
 method_setImplementation(method,(IMP)GroupURL);
 Record(@{@"event":@"offline_storage_hook_installed",@"root":LabRoot});
}
extern void FFMovementStart(void);
extern void FFCommandStart(void);
void FFOfflineStart(void) {
 const char *mode=getenv("FF_OFFLINE_MODE"); if(!mode)return;
 if(![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"local.freeform.bridge.lab"]) { Record(@{@"event":@"offline_wrong_host"}); _exit(79); }
 Record(@{@"event":@"offline_start",@"mode":@(mode)});
 NSSetUncaughtExceptionHandler(Exception);
 [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"CRLDisableCloudKitSync":@YES}];
 Inventory("CKDatabase"); Inventory("CKContainer"); Inventory("CKContainerOptions");
 Inventory("Freeform.CRLiCloudStatusObserver");
 if(strcmp(mode,"stub")==0) { InstallStorage(); InstallOfflineContainer(); FFMovementStart(); FFCommandStart(); }
}
