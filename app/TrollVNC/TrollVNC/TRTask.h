#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal ObjC replacement for the Swift TRTask used by TVNCServiceCoordinator.
/// Spawns a daemon process via posix_spawn (with optional uid/gid persona).
@interface TRTask : NSObject

@property(nonatomic, strong, nullable) NSURL *executableURL;
@property(nonatomic, assign) uid_t userIdentifier;   // default (uid_t)-1 = inherit
@property(nonatomic, assign) gid_t groupIdentifier;  // default (gid_t)-1 = inherit
@property(nonatomic, strong, nullable) NSArray<NSString *> *arguments;
@property(nonatomic, strong, nullable) NSDictionary<NSString *, NSString *> *environment;

@property(nonatomic, assign, readonly) pid_t processIdentifier;

- (BOOL)launchAndReturnError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
