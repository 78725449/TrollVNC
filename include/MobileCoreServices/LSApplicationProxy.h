#import <Foundation/Foundation.h>

@interface LSApplicationProxy : NSObject

+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (BOOL)isInstalled;

@end
