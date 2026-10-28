#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A suggestion, never an automatically recorded expense. User confirmation is required.
@interface PLReceipt : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *merchant;
@property(nonatomic, copy, readonly, nullable) NSString *dateString;
@property(nonatomic, strong, readonly, nullable) NSNumber *totalCents;
@property(nonatomic, copy, readonly) NSString *rawText;
@end

@interface PLReceiptParser : NSObject
+ (PLReceipt *)parseText:(NSString *)text NS_SWIFT_NAME(parse(_:));
@end

@interface PLReceiptScanner : NSObject
/// Uses Apple's on-device Vision recognizer. Completion is called off the main thread.
+ (void)recognizeImage:(CGImageRef)image
           completion:(void (^)(PLReceipt * _Nullable receipt, NSError * _Nullable error))completion
    NS_SWIFT_NAME(recognize(_:completion:));
@end

NS_ASSUME_NONNULL_END
