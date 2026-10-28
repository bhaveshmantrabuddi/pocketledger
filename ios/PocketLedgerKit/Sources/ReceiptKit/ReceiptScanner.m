#import "ReceiptKit.h"
#import <Vision/Vision.h>

@implementation PLReceiptScanner
+ (void)recognizeImage:(CGImageRef)image completion:(void (^)(PLReceipt *, NSError *))completion {
    CGImageRetain(image);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = YES;
            request.recognitionLanguages = @[@"en-US"];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
            NSError *error = nil;
            BOOL success = [handler performRequests:@[request] error:&error];
            CGImageRelease(image);
            if (!success) {
                completion(nil, error ?: [NSError errorWithDomain:@"PocketLedger.Receipt" code:1
                    userInfo:@{NSLocalizedDescriptionKey:@"Receipt recognition failed."}]);
                return;
            }
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            for (VNRecognizedTextObservation *observation in request.results) {
                VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
                if (candidate.string.length) [lines addObject:candidate.string];
            }
            completion([PLReceiptParser parseText:[lines componentsJoinedByString:@"\n"]], nil);
        }
    });
}
@end
