// Runs a block and turns an Objective-C exception into an NSError Swift can catch.
//
// AVAudioEngine reports some failures (installTapOnBus with a stale input format, starting a
// graph left half torn down by a route change) by raising an NSException. Swift cannot catch
// one, so it aborts the process: the 2026-11-10 crash in AudioCaptureEngine.arm, after 3.5
// hours of uptime, was AVAudioEngineGraph::InstallTapOnNode raising. Every engine call that can
// raise goes through this shim instead.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The NSError domain for a caught exception. `userInfo` holds the exception's name under
/// `ZoneExceptionNameKey` and its reason under `NSLocalizedFailureReasonErrorKey`.
extern NSErrorDomain const ZoneExceptionErrorDomain;
extern NSString *const ZoneExceptionNameKey;

@interface ZoneExceptionCatcher : NSObject

/// Runs `block`. Returns NO and fills `error` when it raised an Objective-C exception.
+ (BOOL)catchExceptionIn:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
