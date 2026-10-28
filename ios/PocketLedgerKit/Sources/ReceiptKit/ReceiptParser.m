#import "ReceiptKit.h"

@interface PLReceipt ()
@property(nonatomic, copy, readwrite, nullable) NSString *merchant;
@property(nonatomic, copy, readwrite, nullable) NSString *dateString;
@property(nonatomic, strong, readwrite, nullable) NSNumber *totalCents;
@property(nonatomic, copy, readwrite) NSString *rawText;
@end

@implementation PLReceipt
@end

@implementation PLReceiptParser
+ (NSString *)validatedDate:(NSString *)text format:(NSString *)format {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = format;
    formatter.lenient = NO;
    NSDate *date = [formatter dateFromString:text];
    if (!date || ![[formatter stringFromDate:date] isEqualToString:text]) return nil;
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString *normalized = [formatter stringFromDate:date];
    NSInteger year = [[normalized substringToIndex:4] integerValue];
    return year >= 2000 && year <= 2100 ? normalized : nil;
}

+ (PLReceipt *)parseText:(NSString *)text {
    PLReceipt *receipt = [[PLReceipt alloc] init];
    receipt.rawText = text;
    NSRegularExpression *total = [NSRegularExpression regularExpressionWithPattern:
        @"^(?:grand\\s+total|total(?:\\s+due)?|amount\\s+due|balance\\s+due)\\s*[:=]?\\s*\\$?\\s*([0-9]+(?:,[0-9]{3})*\\.[0-9]{2})\\s*$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *isoDate = [NSRegularExpression regularExpressionWithPattern:
        @"(?<![0-9])([0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9])" options:0 error:nil];
    NSRegularExpression *usDate = [NSRegularExpression regularExpressionWithPattern:
        @"(?<![0-9])([0-9]{2}/[0-9]{2}/[0-9]{4})(?![0-9])" options:0 error:nil];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        NSRange range = NSMakeRange(0, line.length);
        NSTextCheckingResult *totalMatch = [total firstMatchInString:line options:0 range:range];
        if (totalMatch) {
            NSString *number = [[line substringWithRange:[totalMatch rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"," withString:@""];
            NSDecimalNumber *amount = [NSDecimalNumber decimalNumberWithString:number locale:@{NSLocaleDecimalSeparator:@"."}];
            NSDecimalNumber *cents = [amount decimalNumberByMultiplyingBy:[NSDecimalNumber decimalNumberWithString:@"100"]];
            if (![cents isEqualToNumber:NSDecimalNumber.notANumber] &&
                [cents compare:NSDecimalNumber.zero] == NSOrderedDescending &&
                [cents compare:[NSDecimalNumber decimalNumberWithString:@"100000000"]] != NSOrderedDescending) {
                receipt.totalCents = @([cents longLongValue]);
            }
        }
        if (!receipt.dateString) {
            NSTextCheckingResult *match = [isoDate firstMatchInString:line options:0 range:range];
            if (match) receipt.dateString = [self validatedDate:[line substringWithRange:[match rangeAtIndex:1]] format:@"yyyy-MM-dd"];
            if (!receipt.dateString) {
                match = [usDate firstMatchInString:line options:0 range:range];
                if (match) receipt.dateString = [self validatedDate:[line substringWithRange:[match rangeAtIndex:1]] format:@"MM/dd/yyyy"];
            }
        }
        if (!receipt.merchant && !totalMatch && line.length <= 80 &&
            [line rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) {
            receipt.merchant = line;
        }
    }
    return receipt;
}
@end
