#import "ObjCCatcher.h"

@implementation ObjCCatcher

+ (nullable NSString *)catchException:(void (NS_NOESCAPE ^)(void))tryBlock {
    @try {
        tryBlock();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

@end
