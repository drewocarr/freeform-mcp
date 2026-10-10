#import <Foundation/Foundation.h>
// Call before Freeform creates its board controllers. All query calls run on main.
void FFDiscoveryStart(void);
NSArray *FFDiscoveryListBoards(void);
NSArray *FFDiscoveryListObjects(NSString *boardID, NSString **error);
id FFDiscoveryController(NSString *boardID);
id FFDiscoveryItem(NSString *boardID, NSString *objectID);
