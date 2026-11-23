#import "ZoneExceptionCatcher.h"

NSErrorDomain const ZoneExceptionErrorDomain = @"wtf.zayd.zone.exception";
NSString *const ZoneExceptionNameKey = @"ZoneExceptionName";

@implementation ZoneExceptionCatcher

+ (BOOL)catchExceptionIn:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:ZoneExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         ZoneExceptionNameKey: exception.name ?: @"unknown",
                                         NSLocalizedFailureReasonErrorKey: exception.reason ?: @"",
                                     }];
        }
        return NO;
    }
}

@end
