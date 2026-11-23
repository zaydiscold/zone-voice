// Reads UITextDocumentProxy.documentIdentifier without trapping.
//
// UIKit declares the property as a non-nullable `NSUUID *` with no nullability
// annotation, so Swift imports it as a non-optional `UUID`, yet the host returns nil
// before an input session exists. Reading it from Swift crashes the extension; reading
// it from Objective-C, where nil is a value, does not.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZoneTextProxyIdentity : NSObject

/// The identifier of the input session `proxy` is editing, or nil when there is none yet.
+ (nullable NSUUID *)documentIdentifierOf:(id<UITextDocumentProxy>)proxy;

@end

NS_ASSUME_NONNULL_END
