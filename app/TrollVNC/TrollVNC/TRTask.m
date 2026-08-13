#import "TRTask.h"

#import <spawn.h>
#import <sys/stat.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>

// Private posix_spawn persona API
extern int posix_spawnattr_set_persona_np(posix_spawnattr_t *, int, unsigned int);
extern int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t *, gid_t);

static const unsigned int kTRPersonaFlagsOverride = 1u;
static const int kTRPersonaID = 99;

@implementation TRTask {
    pid_t _processIdentifier;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _userIdentifier = (uid_t)-1;
        _groupIdentifier = (gid_t)-1;
    }
    return self;
}

- (pid_t)processIdentifier {
    return _processIdentifier;
}

- (BOOL)launchAndReturnError:(NSError **)error {
    NSString *launchPath = self.executableURL.path;
    if (!launchPath.length) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey : @"No executable URL set."}];
        }
        return NO;
    }

    // Pre-checks: regular executable file
    const char *pathC = launchPath.UTF8String;
    struct stat st;
    if (stat(pathC, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG || access(pathC, X_OK) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Cannot execute %@", launchPath]}];
        }
        return NO;
    }

    // argv: launchPath + arguments
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:launchPath];
    [args addObjectsFromArray:self.arguments ?: @[]];
    NSUInteger argc = args.count;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    if (!argv) return NO;
    for (NSUInteger i = 0; i < argc; i++) {
        argv[i] = strdup(args[i].UTF8String);
    }
    argv[argc] = NULL;

    // envp: self.environment or inherited
    NSDictionary *env = self.environment ?: [[NSProcessInfo processInfo] environment];
    NSMutableArray<NSString *> *envStrs = [NSMutableArray array];
    [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [envStrs addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
    }];
    NSUInteger nenv = envStrs.count;
    char **envp = (char **)calloc(nenv + 1, sizeof(char *));
    if (!envp) {
        for (NSUInteger i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        return NO;
    }
    for (NSUInteger i = 0; i < nenv; i++) {
        envp[i] = strdup(envStrs[i].UTF8String);
    }
    envp[nenv] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t noSignals, mostSignals;
    sigemptyset(&noSignals);
    sigfillset(&mostSignals);
    sigdelset(&mostSignals, SIGKILL);
    sigdelset(&mostSignals, SIGSTOP);
    posix_spawnattr_setsigmask(&attr, &noSignals);
    posix_spawnattr_setsigdefault(&attr, &mostSignals);
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    posix_spawnattr_setflags(&attr, flags);

    if (self.userIdentifier != (uid_t)-1 || self.groupIdentifier != (gid_t)-1) {
        posix_spawnattr_set_persona_np(&attr, kTRPersonaID, kTRPersonaFlagsOverride);
        posix_spawnattr_set_persona_uid_np(&attr, self.userIdentifier);
        posix_spawnattr_set_persona_gid_np(&attr, self.groupIdentifier);
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, pathC, NULL, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);

    for (NSUInteger i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    for (NSUInteger i = 0; i < nenv; i++) free(envp[i]);
    free(envp);

    if (rc != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:rc
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"posix_spawn failed (%d)", rc]}];
        }
        return NO;
    }
    _processIdentifier = pid;
    return YES;
}

@end
