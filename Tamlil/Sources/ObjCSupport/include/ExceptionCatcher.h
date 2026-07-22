// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C exceptions into Swift error handling. `AVAudioEngine`'s
/// `installTap` raises an *uncatchable* `NSException` (e.g. "Failed to create
/// tap due to format mismatch") when the input device is mid-transition — a
/// Swift `do/catch` cannot intercept it, so it terminates the process. Running
/// the call inside `catching:` converts that exception into a thrown Swift
/// error the recorder's bounded-retry recovery can handle.
@interface ExceptionCatcher : NSObject

/// Runs `block`; if it raises an `NSException`, returns `NO` and populates
/// `error` (imported into Swift as a throwing call). Returns `YES` otherwise.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block
           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
