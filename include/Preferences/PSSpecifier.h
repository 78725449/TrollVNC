#import <Foundation/Foundation.h>

@interface PSSpecifier : NSObject

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)performGetter;
- (void)performSetterWithValue:(id)value;

@end
