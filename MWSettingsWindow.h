#import "MWHeaders.h"

@interface MWSettingsWindow : NSObject

+ (void)setupIfNeeded;
+ (void)presentSettings;
+ (void)attachToWindow:(UIWindow *)window;
+ (BOOL)isAttached;

@end
