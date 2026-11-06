#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCCatcher : NSObject

+ (nullable NSString *)catchException:(void (NS_NOESCAPE ^)(void))tryBlock;

@end

NS_ASSUME_NONNULL_END
