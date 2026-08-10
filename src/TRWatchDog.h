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

#ifndef TRWatchDog_h
#define TRWatchDog_h

#import <Foundation/Foundation.h>

// Error domain
FOUNDATION_EXPORT NSString *const TRWatchDogErrorDomain;

// Error codes
typedef NS_ENUM(NSInteger, TRWatchDogErrorCode) {
    // Configuration errors (1000-1099)
    TRWatchDogErrorCodeMissingLabel = 1001,
    TRWatchDogErrorCodeMissingProgram = 1002,
    TRWatchDogErrorCodeInvalidExecutable = 1003,
    TRWatchDogErrorCodeInvalidWorkingDirectory = 1004,

    // Runtime errors (1100-1199)
    TRWatchDogErrorCodeTaskLaunchFailed = 1101,
    TRWatchDogErrorCodeInvalidState = 1102
};

typedef NS_ENUM(NSInteger, TRWatchDogTerminationReason) {
    TRWatchDogTerminationReasonExit = 0,          // Process exited normally
    TRWatchDogTerminationReasonUncaughtSignal = 1 // Process terminated by signal
};

typedef NS_ENUM(NSInteger, TRWatchDogState) {
    TRWatchDogStateStopped = 0, // Initial state
    TRWatchDogStateStarting,    // Starting up
    TRWatchDogStateRunning,     // Running normally
    TRWatchDogStateStopping,    // Shutting down
    TRWatchDogStateCrashed,     // Process crashed
    TRWatchDogStateThrottled    // Throttled, waiting to restart
};

@interface TRWatchDog : NSObject

/// Service label identifier
@property(nonatomic, copy) NSString *label;

/// Program arguments (executable path and arguments)
@property(nonatomic, strong) NSArray<NSString *> *programArguments;

/// Environment variables
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *environmentVariables;

/// Working directory
@property(nonatomic, copy) NSString *workingDirectory;

/// Standard input file path
@property(nonatomic, copy) NSString *standardInputPath;

/// Standard output file path
@property(nonatomic, copy) NSString *standardOutputPath;

/// Standard error file path
@property(nonatomic, copy) NSString *standardErrorPath;

/// User name
@property(nonatomic, copy) NSString *userName;

/// Group name
@property(nonatomic, copy) NSString *groupName;

/// Process group identifier (-1 = not set, 0 = use default process group, >0 = specific group)
@property(nonatomic, assign) pid_t processGroupIdentifier;

/// Exit timeout in seconds
@property(nonatomic, assign) NSTimeInterval exitTimeOut;

/// Throttle interval in seconds (minimum time between successive starts)
@property(nonatomic, assign) NSTimeInterval throttleInterval;

/// Keep alive configuration (can be BOOL or NSDictionary)
@property(nonatomic, strong) id keepAlive;

/// Current state (thread-safe)
@property(nonatomic, assign, readonly) TRWatchDogState state;

#pragma mark - Public Methods

/// Start the watchdog service
/// @return YES if start initiated successfully, NO if already starting/running or configuration invalid
- (BOOL)start;

/// Stop the watchdog service
/// @return YES if stop initiated successfully, NO if already stopping/stopped
- (BOOL)stop;

/// Restart the watchdog service
/// @return YES if restart initiated successfully, NO if configuration invalid
- (BOOL)restart;

/// Send a signal to the current running task
/// @param signal The signal number to send (e.g., SIGTERM, SIGUSR1, etc.)
/// @return YES if signal was sent successfully, NO if no task is running or signal failed
- (BOOL)sendSignal:(int)signal;

/// Check if the watchdog is currently active (starting, running, or stopping)
@property(nonatomic, assign, readonly) BOOL isActive;

/// Check if the watchdog is currently running
@property(nonatomic, assign, readonly) BOOL isRunning;

/// Check if the watchdog is currently throttled (waiting to restart)
@property(nonatomic, assign, readonly) BOOL isThrottled;

/// Current process identifier (0 if not running)
@property(nonatomic, assign, readonly) pid_t processIdentifier;

/// Start time of current process (nil if not running)
@property(nonatomic, strong, readonly) NSDate *processStartTime;

/// Total number of restarts since watchdog creation
@property(nonatomic, assign, readonly) NSUInteger restartCount;

/// Time when the last process exit occurred (nil if never exited)
@property(nonatomic, strong, readonly) NSDate *lastExitTime;

/// Last exit status (valid only if lastExitTime is not nil)
@property(nonatomic, assign, readonly) int lastExitStatus;

/// Last uncaught signal (valid only if lastTerminationReason indicates signal termination)
@property(nonatomic, assign, readonly) int lastUncaughtSignal;

/// Last termination reason (valid only if lastExitTime is not nil)
@property(nonatomic, assign, readonly) TRWatchDogTerminationReason lastTerminationReason;

/// Time remaining until next restart attempt (0 if not throttled)
@property(nonatomic, assign, readonly) NSTimeInterval timeUntilNextRestart;

/// Total uptime of all processes managed by this watchdog
@property(nonatomic, assign, readonly) NSTimeInterval totalUptime;

/// Validate the current configuration
/// @param error Error details if validation fails
/// @return YES if configuration is valid, NO otherwise
- (BOOL)validateConfigurationWithError:(NSError **)error;

@end

#endif /* TRWatchDog_h */
