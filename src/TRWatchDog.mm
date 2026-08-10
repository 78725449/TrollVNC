/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <grp.h>
#import <pwd.h>
#import <signal.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "Logging.h"
#import "TRWatchDog.h"
#import "trollvncmanager-Swift.h"

#define TAG "TRWatchDog"

// Error domain
NSString *const TRWatchDogErrorDomain = @"TRWatchDogErrorDomain";

@interface TRWatchDog ()

/// Internal state (not thread-safe, use queue)
@property(nonatomic, assign) TRWatchDogState internalState;

/// Serial queue for thread safety
@property(nonatomic, strong) dispatch_queue_t stateQueue;

/// Current task instance
@property(nonatomic, strong) TRTask *currentTask;

/// Throttle timer
@property(nonatomic, strong) dispatch_source_t throttleTimer;

/// Process start time tracking
@property(nonatomic, strong) NSDate *internalProcessStartTime;

/// Statistics tracking
@property(nonatomic, assign) NSUInteger internalRestartCount;
@property(nonatomic, strong) NSDate *internalLastExitTime;
@property(nonatomic, assign) int internalLastExitStatus;
@property(nonatomic, assign) int internalLastUncaughtSignal;
@property(nonatomic, assign) TRWatchDogTerminationReason internalLastTerminationReason;
@property(nonatomic, assign) NSTimeInterval internalTotalUptime;

/// Throttle timing
@property(nonatomic, strong) NSDate *throttleStartTime;

/// Restart pending flag
@property(nonatomic, assign) BOOL restartPending;

/// Task being terminated (to avoid killing wrong process)
@property(nonatomic, weak) TRTask *taskBeingTerminated;

@end

@implementation TRWatchDog

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize default values
        _label = nil;
        _programArguments = nil;
        _environmentVariables = nil;
        _workingDirectory = nil;
        _userName = nil;
        _groupName = nil;
        _processGroupIdentifier = -1; // Default to -1 (not set)
        _exitTimeOut = 3.0;           // Default exit timeout
        _throttleInterval = 30.0;     // Default throttle interval
        _keepAlive = @YES;            // Default keep alive (YES as NSNumber)

        // Initialize state machine
        _internalState = TRWatchDogStateStopped;
        _stateQueue = dispatch_queue_create("com.82flex.trollvnc.TRWatchDog.state", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
        _currentTask = nil;
        _throttleTimer = NULL;

        // Initialize statistics
        _internalProcessStartTime = nil;
        _internalRestartCount = 0;
        _internalLastExitTime = nil;
        _internalLastExitStatus = 0;
        _internalLastUncaughtSignal = 0;
        _internalLastTerminationReason = TRWatchDogTerminationReasonExit;
        _internalTotalUptime = 0.0;
        _throttleStartTime = nil;
        _restartPending = NO;
        _taskBeingTerminated = nil;
    }
    return self;
}

- (void)dealloc {
    // Ensure we properly clean up on dealloc
    if (self.stateQueue) {
        dispatch_sync(self.stateQueue, ^{
            [self _cancelThrottleTimer];
            [self _cleanupCurrentTask];
            self.restartPending = NO;
        });
    }
}

#pragma mark - Property Validation and Setters

- (void)setExitTimeOut:(NSTimeInterval)exitTimeOut {
    if (exitTimeOut < 0.0) {
        TVLog(@TAG "[%@] invalid exitTimeOut %.1f, using default 3.0", self.label ?: @"<nil>", exitTimeOut);
        _exitTimeOut = 3.0;
    } else {
        _exitTimeOut = exitTimeOut;
    }
}

- (void)setThrottleInterval:(NSTimeInterval)throttleInterval {
    if (throttleInterval < 0.0) {
        TVLog(@TAG "[%@] invalid throttleInterval %.1f, using default 30.0", self.label ?: @"<nil>", throttleInterval);
        _throttleInterval = 30.0;
    } else {
        _throttleInterval = throttleInterval;
    }
}

- (void)setKeepAlive:(id)keepAlive {
    if (keepAlive == nil) {
        _keepAlive = @NO; // Default to not keep alive if nil
    } else if ([keepAlive isKindOfClass:[NSNumber class]] || [keepAlive isKindOfClass:[NSDictionary class]]) {
        _keepAlive = keepAlive;
    } else {
        TVLog(@TAG "[%@] invalid keepAlive type %@, using default NO", self.label ?: @"<nil>", [keepAlive class]);
        _keepAlive = @NO;
    }
}

- (void)setProcessGroupIdentifier:(pid_t)processGroupIdentifier {
    // Allow -1 (not set), 0 (default group), or positive values (specific group)
    if (processGroupIdentifier < -1) {
        TVLog(@TAG "[%@] invalid processGroupIdentifier %d, using -1 (not set)", self.label ?: @"<nil>",
              processGroupIdentifier);
        _processGroupIdentifier = -1;
    } else {
        _processGroupIdentifier = processGroupIdentifier;
    }
}

#pragma mark - State Management

- (TRWatchDogState)state {
    __block TRWatchDogState currentState;
    dispatch_sync(self.stateQueue, ^{
        currentState = self.internalState;
    });
    return currentState;
}

- (void)_transitionToState:(TRWatchDogState)newState {
    dispatch_assert_queue(self.stateQueue);

    TRWatchDogState oldState = self.internalState;
    if (oldState == newState) {
        return; // No change
    }

    TVLog(@TAG "[%@] state transition: %@ -> %@", self.label ?: @"<nil>", [self _stringForState:oldState],
          [self _stringForState:newState]);

    self.internalState = newState;

    // Handle state-specific logic
    [self _handleStateTransitionFrom:oldState to:newState];
}

- (void)_handleStateTransitionFrom:(TRWatchDogState)oldState to:(TRWatchDogState)newState {
    dispatch_assert_queue(self.stateQueue);

    switch (newState) {
    case TRWatchDogStateStopped:
        [self _cleanupCurrentTask];
        [self _cancelThrottleTimer];
        // Clear restartPending only if we're not transitioning from stopping state
        // (stopping state may have pending restart)
        if (oldState != TRWatchDogStateStopping) {
            self.restartPending = NO;
        }
        break;

    case TRWatchDogStateStarting:
        // Will be handled in start method
        break;

    case TRWatchDogStateRunning:
        // Task is running successfully
        break;

    case TRWatchDogStateStopping:
        // Will be handled in stop method
        break;

    case TRWatchDogStateCrashed:
        [self _handleCrash];
        break;

    case TRWatchDogStateThrottled:
        [self _startThrottleTimer];
        break;
    }
}

- (NSString *)_stringForState:(TRWatchDogState)state {
    switch (state) {
    case TRWatchDogStateStopped:
        return @"Stopped";
    case TRWatchDogStateStarting:
        return @"Starting";
    case TRWatchDogStateRunning:
        return @"Running";
    case TRWatchDogStateStopping:
        return @"Stopping";
    case TRWatchDogStateCrashed:
        return @"Crashed";
    case TRWatchDogStateThrottled:
        return @"Throttled";
    default:
        return @"Unknown";
    }
}

#pragma mark - Private Helper Methods

- (BOOL)_shouldRestartForTerminationReason:(TRTaskTerminationReason)reason status:(int)status {
    dispatch_assert_queue(self.stateQueue);

    if ([self.keepAlive isKindOfClass:[NSNumber class]]) {
        // Simple boolean KeepAlive
        return [(NSNumber *)self.keepAlive boolValue];
    } else if ([self.keepAlive isKindOfClass:[NSDictionary class]]) {
        // Dictionary KeepAlive with conditions
        NSDictionary *keepAliveDict = (NSDictionary *)self.keepAlive;
        BOOL shouldRestart = NO;

        // Check Crashed condition
        NSNumber *crashedValue = keepAliveDict[@"Crashed"];
        if (crashedValue != nil && [crashedValue isKindOfClass:[NSNumber class]]) {
            BOOL crashedCondition = [crashedValue boolValue];
            BOOL wasCrashed = (reason == TRTaskTerminationReasonUncaughtSignal);

            if (crashedCondition && wasCrashed) {
                TVLog(@TAG "[%@] restarting due to Crashed=true condition", self.label);
                shouldRestart = YES;
            } else if (!crashedCondition && !wasCrashed) {
                TVLog(@TAG "[%@] restarting due to Crashed=false condition", self.label);
                shouldRestart = YES;
            }
        }

        // Check SuccessfulExit condition
        NSNumber *successfulExitValue = keepAliveDict[@"SuccessfulExit"];
        if (successfulExitValue != nil && [successfulExitValue isKindOfClass:[NSNumber class]]) {
            BOOL successfulExitCondition = [successfulExitValue boolValue];
            BOOL wasSuccessfulExit = (reason == TRTaskTerminationReasonExit && status == 0);

            if (successfulExitCondition && wasSuccessfulExit) {
                TVLog(@TAG "[%@] restarting due to SuccessfulExit=true condition", self.label);
                shouldRestart = YES;
            } else if (!successfulExitCondition && !wasSuccessfulExit && reason == TRTaskTerminationReasonExit) {
                TVLog(@TAG "[%@] restarting due to SuccessfulExit=false condition", self.label);
                shouldRestart = YES;
            }
        }

        return shouldRestart;
    } else {
        // Invalid keepAlive value, default to not restart
        TVLog(@TAG "[%@] invalid keepAlive value: %@", self.label, self.keepAlive);
        return NO;
    }
}

- (void)_cleanupCurrentTask {
    dispatch_assert_queue(self.stateQueue);

    if (self.currentTask) {
        TVLog(@TAG "[%@] cleaning up current task", self.label ?: @"<nil>");
        self.currentTask = nil;
    }

    // Clear task being terminated flag as well
    self.taskBeingTerminated = nil;

    // Note: We don't reset restartPending here anymore since it should be managed
    // explicitly by the caller when appropriate
}

- (void)_cancelThrottleTimer {
    dispatch_assert_queue(self.stateQueue);

    if (self.throttleTimer) {
        // Make sure timer is properly cancelled and released
        dispatch_source_t timer = self.throttleTimer;
        self.throttleTimer = NULL;
        dispatch_source_cancel(timer);
    }

    self.throttleStartTime = nil;
}

- (void)_handleCrash {
    dispatch_assert_queue(self.stateQueue);

    TVLog(@TAG "[%@] handling restart request", self.label ?: @"<nil>");

    [self _cleanupCurrentTask];

    // Increment restart count
    self.internalRestartCount++;

    // Calculate time since last start to determine throttle delay
    NSTimeInterval timeSinceLastStart = 0.0;
    if (self.internalProcessStartTime) {
        timeSinceLastStart = [[NSDate date] timeIntervalSinceDate:self.internalProcessStartTime];
    }

    // If enough time has passed since last start, we can restart immediately
    if (timeSinceLastStart >= self.throttleInterval) {
        TVLog(@TAG "[%@] sufficient time since last start (%.1fs >= %.1fs), restarting immediately",
              self.label ?: @"<nil>", timeSinceLastStart, self.throttleInterval);
        [self _transitionToState:TRWatchDogStateStopped];
        [self _startInternal];
    } else {
        // Need to wait for the remaining time
        TVLog(@TAG "[%@] throttling restart, need to wait %.1fs more (%.1fs since last start)", self.label ?: @"<nil>",
              self.throttleInterval - timeSinceLastStart, timeSinceLastStart);
        [self _transitionToState:TRWatchDogStateThrottled];
    }
}

#pragma mark - Standard Streams Configuration

- (void)_configureStandardStreamsForTask:(TRTask *)task {
    dispatch_assert_queue(self.stateQueue);

    NSFileManager *fm = [NSFileManager defaultManager];

    // Determine desired ownership if userName/groupName are provided
    BOOL hasUser = (self.userName && self.userName.length > 0);
    BOOL hasGroup = (self.groupName && self.groupName.length > 0);

    uid_t desiredUID = hasUser ? (uid_t)task.userIdentifier : (uid_t)getuid();
    gid_t desiredGID = hasGroup ? (gid_t)task.groupIdentifier : (gid_t)getgid();

    // Helper block to ensure a file exists (create empty if missing)
    BOOL (^ensureFileExists)(NSString *) = ^BOOL(NSString *path) {
        if (!path || path.length == 0) {
            return NO;
        }
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];
        if (exists && isDir) {
            TVLog(@TAG "[%@] path is a directory, expected file: %@", self.label ?: @"<nil>", path);
            return NO;
        }
        if (!exists) {
            // Try create empty file
            NSString *parent = [path stringByDeletingLastPathComponent];
            if (parent.length > 0) {
                BOOL parentIsDir = NO;
                if (![fm fileExistsAtPath:parent isDirectory:&parentIsDir] || !parentIsDir) {
                    // Parent dir not present, don't attempt to create directories implicitly
                    TVLog(@TAG "[%@] parent directory missing for path: %@", self.label ?: @"<nil>", path);
                    // Still attempt createFileAtPath (will fail if parent missing)
                }
            }
            if (![fm createFileAtPath:path contents:nil attributes:nil]) {
                TVLog(@TAG "[%@] failed to create file at path: %@", self.label ?: @"<nil>", path);
                return NO;
            }
            // Adjust ownership if requested
            if (hasUser || hasGroup) {
                if (chown([path fileSystemRepresentation], desiredUID, desiredGID) != 0) {
                    TVLog(@TAG "[%@] failed to chown %@ to uid:%u gid:%u, errno=%d (%s)", self.label ?: @"<nil>", path,
                          (unsigned)desiredUID, (unsigned)desiredGID, errno, strerror(errno));
                } else {
                    TVLog(@TAG "[%@] set ownership for %@ to uid:%u gid:%u", self.label ?: @"<nil>", path,
                          (unsigned)desiredUID, (unsigned)desiredGID);
                }
            }
        }
        return YES;
    };

    // standardInput: ensure file and open for reading
    if (self.standardInputPath && self.standardInputPath.length > 0) {
        if (ensureFileExists(self.standardInputPath)) {
            NSFileHandle *inHandle = [NSFileHandle fileHandleForReadingAtPath:self.standardInputPath];
            if (inHandle) {
                task.standardInput = inHandle;
                TVLog(@TAG "[%@] configured standardInput: %@", self.label ?: @"<nil>", self.standardInputPath);
            } else {
                TVLog(@TAG "[%@] failed to open standardInput for reading: %@", self.label ?: @"<nil>",
                      self.standardInputPath);
            }
        }
    }

    // Helper to open a file for append writing using low-level open()
    NSFileHandle * (^openAppendHandle)(NSString *) = ^NSFileHandle *(NSString *path) {
        int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, (mode_t)0644);
        if (fd == -1) {
            TVLog(@TAG "[%@] failed to open for append: %@, errno=%d (%s)", self.label ?: @"<nil>", path, errno,
                  strerror(errno));
            return (NSFileHandle *)nil;
        }
        return [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    };

    // standardOutput: ensure file and open append
    if (self.standardOutputPath && self.standardOutputPath.length > 0) {
        if (ensureFileExists(self.standardOutputPath)) {
            NSFileHandle *outHandle = openAppendHandle(self.standardOutputPath);
            if (outHandle) {
                task.standardOutput = outHandle;
                TVLog(@TAG "[%@] configured standardOutput (append): %@", self.label ?: @"<nil>",
                      self.standardOutputPath);
            }
        }
    }

    // standardError: ensure file and open append
    if (self.standardErrorPath && self.standardErrorPath.length > 0) {
        if (ensureFileExists(self.standardErrorPath)) {
            NSFileHandle *errHandle = openAppendHandle(self.standardErrorPath);
            if (errHandle) {
                task.standardError = errHandle;
                TVLog(@TAG "[%@] configured standardError (append): %@", self.label ?: @"<nil>",
                      self.standardErrorPath);
            }
        }
    }
}

- (void)_startThrottleTimer {
    dispatch_assert_queue(self.stateQueue);

    [self _cancelThrottleTimer]; // Cancel any existing timer

    // Calculate remaining time needed since last start
    NSTimeInterval remainingTime = self.throttleInterval;
    if (self.internalProcessStartTime) {
        NSTimeInterval timeSinceLastStart = [[NSDate date] timeIntervalSinceDate:self.internalProcessStartTime];
        remainingTime = MAX(0.0, self.throttleInterval - timeSinceLastStart);
    }

    TVLog(@TAG "[%@] starting throttle timer for %.1f seconds (remaining time since last start)",
          self.label ?: @"<nil>", remainingTime);

    self.throttleStartTime = [NSDate date];

    self.throttleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    dispatch_source_set_timer(self.throttleTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remainingTime * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, (int64_t)(0.1 * NSEC_PER_SEC));

    __weak TRWatchDog *weakSelf = self;
    dispatch_source_set_event_handler(self.throttleTimer, ^{
        TRWatchDog *strongSelf = weakSelf;
        if (strongSelf) {
            TVLog(@TAG "[%@] throttle timer expired, attempting restart", strongSelf.label ?: @"<nil>");
            // Transition from throttled to stopped state before attempting restart
            [strongSelf _transitionToState:TRWatchDogStateStopped];
            [strongSelf _startInternal];
        }
    });

    dispatch_resume(self.throttleTimer);
}

- (NSString *)description {
    return
        [NSString stringWithFormat:@"<" TAG ": %p, label: %@, state: %@, programArguments: %@, workingDirectory: %@, "
                                   @"userName: %@, groupName: %@, processGroupIdentifier: %d, exitTimeOut: %.1f, "
                                   @"throttleInterval: %.1f, keepAlive: %@>",
                                   self, self.label, [self _stringForState:self.state], self.programArguments,
                                   self.workingDirectory, self.userName, self.groupName, self.processGroupIdentifier,
                                   self.exitTimeOut, self.throttleInterval, self.keepAlive];
}

#pragma mark - Public Properties

- (BOOL)isThrottled {
    return self.state == TRWatchDogStateThrottled;
}

- (pid_t)processIdentifier {
    __block pid_t pid = 0;
    dispatch_sync(self.stateQueue, ^{
        if (self.currentTask && self.currentTask.isRunning) {
            pid = self.currentTask.processIdentifier;
        }
    });
    return pid;
}

- (NSDate *)processStartTime {
    __block NSDate *startTime = nil;
    dispatch_sync(self.stateQueue, ^{
        startTime = self.internalProcessStartTime;
    });
    return startTime;
}

- (NSUInteger)restartCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.stateQueue, ^{
        count = self.internalRestartCount;
    });
    return count;
}

- (NSDate *)lastExitTime {
    __block NSDate *exitTime = nil;
    dispatch_sync(self.stateQueue, ^{
        exitTime = self.internalLastExitTime;
    });
    return exitTime;
}

- (int)lastExitStatus {
    __block int status = 0;
    dispatch_sync(self.stateQueue, ^{
        status = self.internalLastExitStatus;
    });
    return status;
}

- (int)lastUncaughtSignal {
    __block int signal = 0;
    dispatch_sync(self.stateQueue, ^{
        signal = self.internalLastUncaughtSignal;
    });
    return signal;
}

- (TRWatchDogTerminationReason)lastTerminationReason {
    __block TRWatchDogTerminationReason reason = TRWatchDogTerminationReasonExit;
    dispatch_sync(self.stateQueue, ^{
        reason = self.internalLastTerminationReason;
    });
    return reason;
}

- (NSTimeInterval)timeUntilNextRestart {
    __block NSTimeInterval timeRemaining = 0.0;
    dispatch_sync(self.stateQueue, ^{
        if (self.internalState == TRWatchDogStateThrottled && self.internalProcessStartTime) {
            NSTimeInterval timeSinceLastStart = [[NSDate date] timeIntervalSinceDate:self.internalProcessStartTime];
            timeRemaining = MAX(0.0, self.throttleInterval - timeSinceLastStart);
        }
    });
    return timeRemaining;
}

- (NSTimeInterval)totalUptime {
    __block NSTimeInterval uptime = 0.0;
    dispatch_sync(self.stateQueue, ^{
        uptime = self.internalTotalUptime;

        // Add current session uptime if running
        if (self.internalState == TRWatchDogStateRunning && self.internalProcessStartTime) {
            uptime += [[NSDate date] timeIntervalSinceDate:self.internalProcessStartTime];
        }
    });
    return uptime;
}

#pragma mark - Public Methods

- (BOOL)start {
    __block BOOL result = NO;
    dispatch_sync(self.stateQueue, ^{
        result = [self _startInternal];
    });
    return result;
}

- (BOOL)stop {
    __block BOOL result = NO;
    dispatch_sync(self.stateQueue, ^{
        result = [self _stopInternalClearRestartPending:YES];
    });
    return result;
}

- (BOOL)restart {
    __block BOOL result = NO;
    dispatch_sync(self.stateQueue, ^{
        // Check current state - only allow restart if running or stopped
        if (self.internalState == TRWatchDogStateRunning) {
            // Mark restart as pending and stop the current task (don't clear restartPending)
            self.restartPending = YES;
            result = [self _stopInternalClearRestartPending:NO];
            TVLog(@TAG "[%@] restart initiated, stopping current task", self.label);
        } else if (self.internalState == TRWatchDogStateStopped) {
            // If already stopped, just start
            result = [self _startInternal];
        } else {
            TVLog(@TAG "[%@] cannot restart from state: %@", self.label ?: @"<nil>",
                  [self _stringForState:self.internalState]);
        }
    });
    return result;
}

- (BOOL)sendSignal:(int)signal {
    __block BOOL result = NO;
    dispatch_sync(self.stateQueue, ^{
        if (self.currentTask && self.currentTask.isRunning && self.internalState == TRWatchDogStateRunning) {
            pid_t pid = self.currentTask.processIdentifier;
            if (pid > 0) {
                if (kill(pid, signal) == 0) {
                    TVLog(@TAG "[%@] sent signal %d to task PID: %d", self.label, signal, pid);
                    result = YES;
                } else {
                    TVLog(@TAG "[%@] failed to send signal %d to task PID: %d, error: %s", self.label, signal, pid,
                          strerror(errno));
                }
            }
        } else {
            TVLog(@TAG "[%@] cannot send signal %d: no running task", self.label, signal);
        }
    });
    return result;
}

- (BOOL)isActive {
    TRWatchDogState currentState = self.state;
    return (currentState == TRWatchDogStateStarting || currentState == TRWatchDogStateRunning ||
            currentState == TRWatchDogStateStopping);
}

- (BOOL)isRunning {
    return self.state == TRWatchDogStateRunning;
}

- (BOOL)validateConfigurationWithError:(NSError **)error {
    // Check label
    if (!self.label || self.label.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TRWatchDogErrorDomain
                                         code:TRWatchDogErrorCodeMissingLabel
                                     userInfo:@{NSLocalizedDescriptionKey : @"Service label is required"}];
        }
        return NO;
    }

    // Check program arguments
    if (!self.programArguments || self.programArguments.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TRWatchDogErrorDomain
                                         code:TRWatchDogErrorCodeMissingProgram
                                     userInfo:@{NSLocalizedDescriptionKey : @"Program arguments are required"}];
        }
        return NO;
    }

    // Check executable path (first argument)
    NSString *executablePath = self.programArguments.firstObject;
    if (!executablePath || executablePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TRWatchDogErrorDomain
                                         code:TRWatchDogErrorCodeInvalidExecutable
                                     userInfo:@{NSLocalizedDescriptionKey : @"Executable path cannot be empty"}];
        }
        return NO;
    }

    // Check if executable exists
    BOOL isDirectory;
    if (![[NSFileManager defaultManager] fileExistsAtPath:executablePath isDirectory:&isDirectory] || isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:TRWatchDogErrorDomain
                                         code:TRWatchDogErrorCodeInvalidExecutable
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : [NSString
                                             stringWithFormat:@"Executable not found at path: %@", executablePath]
                                     }];
        }
        return NO;
    }

    // Check if executable has execute permission
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:executablePath]) {
        if (error) {
            *error = [NSError
                errorWithDomain:TRWatchDogErrorDomain
                           code:TRWatchDogErrorCodeInvalidExecutable
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               [NSString stringWithFormat:@"Executable at path is not executable: %@", executablePath]
                       }];
        }
        return NO;
    }

    // Check working directory if specified
    if (self.workingDirectory && self.workingDirectory.length > 0) {
        BOOL isWorkingDirectoryExist;
        BOOL workingDirectoryExists = [[NSFileManager defaultManager] fileExistsAtPath:self.workingDirectory
                                                                           isDirectory:&isWorkingDirectoryExist];
        if (!workingDirectoryExists || !isWorkingDirectoryExist) {
            if (error) {
                *error = [NSError
                    errorWithDomain:TRWatchDogErrorDomain
                               code:TRWatchDogErrorCodeInvalidWorkingDirectory
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"Working directory not found or is not a directory: %@",
                                                              self.workingDirectory]
                           }];
            }
            return NO;
        }
    }

    return YES;
}

#pragma mark - Private Implementation Methods

- (BOOL)_startInternal {
    dispatch_assert_queue(self.stateQueue);

    // Check current state
    if (self.internalState != TRWatchDogStateStopped && self.internalState != TRWatchDogStateCrashed) {
        TVLog(@TAG "[%@] cannot start from state: %@", self.label ?: @"<nil>",
              [self _stringForState:self.internalState]);
        return NO;
    }

    // Validate configuration
    NSError *configError;
    if (![self validateConfigurationWithError:&configError]) {
        TVLog(@TAG "[%@] configuration validation failed: %@", self.label ?: @"<nil>",
              configError.localizedDescription);
        return NO;
    }

    TVLog(@TAG "[%@] starting service", self.label);

    [self _transitionToState:TRWatchDogStateStarting];

    // Create and configure task
    TRTask *task = [[TRTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.programArguments.firstObject];
    if (self.programArguments.count > 1) {
        task.arguments = [self.programArguments subarrayWithRange:NSMakeRange(1, self.programArguments.count - 1)];
    }

    if (self.environmentVariables) {
        task.environment = self.environmentVariables;
    }

    if (self.workingDirectory) {
        task.currentDirectoryURL = [NSURL fileURLWithPath:self.workingDirectory];
    }

    // Set user identifier if userName is specified
    if (self.userName && self.userName.length > 0) {
        struct passwd *pwd = getpwnam([self.userName UTF8String]);
        if (pwd) {
            task.userIdentifier = pwd->pw_uid;
            TVLog(@TAG "[%@] setting user identifier: %u (%@)", self.label, (unsigned int)pwd->pw_uid, self.userName);
        } else {
            TVLog(@TAG "[%@] warning: user '%@' not found", self.label, self.userName);
        }
    }

    // Set group identifier if groupName is specified
    if (self.groupName && self.groupName.length > 0) {
        struct group *grp = getgrnam([self.groupName UTF8String]);
        if (grp) {
            task.groupIdentifier = grp->gr_gid;
            TVLog(@TAG "[%@] setting group identifier: %u (%@)", self.label, (unsigned int)grp->gr_gid, self.groupName);
        } else {
            TVLog(@TAG "[%@] warning: group '%@' not found", self.label, self.groupName);
        }
    }

    // Set process group identifier if specified (-1 means not set)
    if (self.processGroupIdentifier != -1) {
        task.processGroupIdentifier = self.processGroupIdentifier;
        TVLog(@TAG "[%@] setting process group identifier: %d", self.label, self.processGroupIdentifier);
    }

    // Configure standard IO if paths are provided
    [self _configureStandardStreamsForTask:task];

    // Set task termination handler
    __weak TRWatchDog *weakSelf = self;
    task.terminationHandler = ^(TRTask *terminatedTask) {
        TRWatchDog *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(strongSelf.stateQueue, ^{
                [strongSelf _handleTaskTermination:terminatedTask];
            });
        }
    };

    // Launch task
    NSError *launchError;
    BOOL launched = [task launchAndReturnError:&launchError];
    if (!launched) {
        TVLog(@TAG "[%@] failed to launch task: %@", self.label, launchError.localizedDescription);
        [self _transitionToState:TRWatchDogStateStopped];
        return NO;
    }

    self.currentTask = task;
    self.internalProcessStartTime = [NSDate date];

    TVLog(@TAG "[%@] task launched successfully, PID: %d", self.label, task.processIdentifier);
    [self _transitionToState:TRWatchDogStateRunning];
    return YES;
}

- (BOOL)_stopInternalClearRestartPending:(BOOL)clearRestartPending {
    dispatch_assert_queue(self.stateQueue);

    // Check current state
    if (self.internalState == TRWatchDogStateStopped || self.internalState == TRWatchDogStateStopping) {
        return YES; // Already stopped or stopping
    }

    TVLog(@TAG "[%@] stopping service", self.label);

    // Clear restart pending flag when explicitly stopping (if requested)
    if (clearRestartPending) {
        self.restartPending = NO;
    }

    [self _transitionToState:TRWatchDogStateStopping];

    // Cancel throttle timer if active
    [self _cancelThrottleTimer];

    // Terminate current task if running
    if (self.currentTask && self.currentTask.isRunning) {
        TRTask *taskToTerminate = self.currentTask;
        pid_t pidToTerminate = taskToTerminate.processIdentifier;

        // Mark this task as being terminated
        self.taskBeingTerminated = taskToTerminate;

        TVLog(@TAG "[%@] terminating task PID: %d", self.label, pidToTerminate);

        [taskToTerminate terminate];

        // Wait for termination with timeout
        // Use the tracked task to ensure we don't kill wrong process
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.exitTimeOut * NSEC_PER_SEC)), self.stateQueue, ^{
            // Only kill if:
            // 1. The task being terminated still exists and is running
            // 2. The PID matches (to ensure it's the same process)
            // 3. The task is still marked as being terminated (not cleared by successful termination)
            if (self.taskBeingTerminated && self.taskBeingTerminated == taskToTerminate && taskToTerminate.isRunning &&
                taskToTerminate.processIdentifier == pidToTerminate) {

                TVLog(@TAG "[%@] force killing task PID: %d after timeout", self.label, pidToTerminate);
                // Send SIGKILL signal directly to the process
                kill(pidToTerminate, SIGKILL);
            } else {
                TVLog(@TAG "[%@] skipping force kill - task PID: %d already terminated or replaced", self.label,
                      pidToTerminate);
            }
        });
    } else {
        // No running task, transition directly to stopped
        [self _transitionToState:TRWatchDogStateStopped];
    }

    return YES;
}

- (void)_handleTaskTermination:(TRTask *)task {
    dispatch_assert_queue(self.stateQueue);

    // Defensive check - ensure we have a valid task
    if (!task || task != self.currentTask) {
        TVLog(@TAG "[%@] ignoring termination of unknown task", self.label ?: @"<nil>");
        return;
    }

    TRTaskTerminationReason terminationReason = task.terminationReason;
    int32_t terminationStatus = task.terminationStatus;

    if (terminationReason == TRTaskTerminationReasonExit) {
        // Normal exit with exit code
        TVLog(@TAG "[%@] task %d exited with code: %d", self.label, task.processIdentifier, terminationStatus);
    } else if (terminationReason == TRTaskTerminationReasonUncaughtSignal) {
        // Terminated by signal
        TVLog(@TAG "[%@] task %d terminated by signal: %d", self.label, task.processIdentifier, terminationStatus);
    } else {
        // Unknown termination reason
        TVLog(@TAG "[%@] task %d terminated with unknown reason: %ld, status: %d", self.label, task.processIdentifier,
              (long)terminationReason, terminationStatus);
    }

    // Record termination statistics
    self.internalLastExitTime = [NSDate date];

    // Convert TRTask termination reason to our enum
    if (terminationReason == TRTaskTerminationReasonExit) {
        self.internalLastTerminationReason = TRWatchDogTerminationReasonExit;
        // Normal exit - record exit status
        self.internalLastExitStatus = terminationStatus;
        self.internalLastUncaughtSignal = 0;
    } else if (terminationReason == TRTaskTerminationReasonUncaughtSignal) {
        self.internalLastTerminationReason = TRWatchDogTerminationReasonUncaughtSignal;
        // Signal termination - record signal number
        self.internalLastExitStatus = 0;
        self.internalLastUncaughtSignal = terminationStatus;
    } else {
        // Unknown termination reason, default to exit
        self.internalLastTerminationReason = TRWatchDogTerminationReasonExit;
        self.internalLastExitStatus = terminationStatus;
        self.internalLastUncaughtSignal = 0;
    }

    // Update total uptime
    if (self.internalProcessStartTime) {
        NSTimeInterval sessionUptime = [self.internalLastExitTime timeIntervalSinceDate:self.internalProcessStartTime];
        self.internalTotalUptime += sessionUptime;
        // Note: Keep internalProcessStartTime for throttle interval calculation,
        // it will be updated when next process starts
    }

    self.currentTask = nil;

    // Clear the task being terminated flag since the task has now terminated
    if (self.taskBeingTerminated == task) {
        self.taskBeingTerminated = nil;
    }

    if (self.internalState == TRWatchDogStateStopping) {
        // Expected termination (user requested stop)
        [self _transitionToState:TRWatchDogStateStopped];

        // Check if restart is pending
        if (self.restartPending) {
            self.restartPending = NO;
            TVLog(@TAG "[%@] previous task stopped, starting new task for restart", self.label);
            [self _startInternal];
        }
    } else if (self.internalState == TRWatchDogStateRunning) {
        // Unexpected termination - check keepAlive conditions
        BOOL shouldRestart = [self _shouldRestartForTerminationReason:terminationReason status:terminationStatus];

        if (shouldRestart) {
            TVLog(@TAG "[%@] process exited, will restart due to keepAlive conditions", self.label);
            [self _transitionToState:TRWatchDogStateCrashed]; // Use crashed state to trigger restart logic
        } else {
            TVLog(@TAG "[%@] process exited, will not restart", self.label);
            [self _transitionToState:TRWatchDogStateStopped];
        }
    }
}

@end
