#import "TextProxyIdentity.h"

@implementation ZoneTextProxyIdentity

+ (nullable NSUUID *)documentIdentifierOf:(id<UITextDocumentProxy>)proxy {
    if (proxy == nil) {
        return nil;
    }
    if (![proxy respondsToSelector:@selector(documentIdentifier)]) {
        return nil;
    }
    // iOS 27 raises an Objective-C exception from the system proxy's documentIdentifier when the
    // keyboard appears before its input session exists (MetricKit crash reports of 2026-11-03,
    // 20:22 and 23:17: KeyboardViewController.viewWillAppear > refreshTraits > here). A Swift
    // caller cannot catch that; this shim exists so it can be caught here. No session means no
    // identity, which every caller already handles.
    @try {
        return proxy.documentIdentifier;
    } @catch (NSException *exception) {
        return nil;
    }
}

@end
