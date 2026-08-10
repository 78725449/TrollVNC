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

#import "DpkgVersion.h"

@implementation DpkgVersion

- (instancetype)initWithEpoch:(uint64_t)epoch version:(NSString *)version revision:(NSString *)revision {
    self = [super init];
    if (self) {
        _epoch = epoch;
        _version = [version copy];
        _revision = [revision copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithEpoch:self.epoch version:self.version revision:self.revision];
}

#pragma mark - Public

+ (nullable instancetype)parseFromString:(NSString *)string {
    if (!string) {
        return nil;
    }

    // Trim leading and trailing space
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    NSString *versionString = [string stringByTrimmingCharactersInSet:ws];
    if (versionString.length == 0) {
        return nil;
    }

    // Check for embedded spaces
    if ([versionString rangeOfCharacterFromSet:ws].location != NSNotFound) {
        return nil;
    }

    // Parse epoch
    uint64_t epoch = 0;
    NSRange colon = [versionString rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        NSString *epochStr = [versionString substringToIndex:colon.location];
        if (epochStr.length == 0) {
            return nil;
        }

        NSScanner *scanner = [NSScanner scannerWithString:epochStr];
        unsigned long long epochValue = 0; // use unsigned long long for NSScanner
        if (![scanner scanUnsignedLongLong:&epochValue] || !scanner.isAtEnd) {
            return nil;
        }
        epoch = (uint64_t)epochValue;

        NSUInteger nextIndex = colon.location + colon.length;
        if (nextIndex >= versionString.length) {
            return nil;
        }
        versionString = [versionString substringFromIndex:nextIndex];
    }

    // Parse version and revision
    NSString *version = versionString;
    NSString *revision = @"";

    NSRange hyphen = [versionString rangeOfString:@"-" options:NSBackwardsSearch];
    if (hyphen.location != NSNotFound) {
        version = [versionString substringToIndex:hyphen.location];
        NSUInteger revStart = hyphen.location + hyphen.length;
        if (revStart >= versionString.length) {
            return nil;
        }
        revision = [versionString substringFromIndex:revStart];
    }

    if (version.length == 0) {
        return nil;
    }

    unichar first = [version characterAtIndex:0];
    if (![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:first]) {
        return nil;
    }

    // Valid chars for version: 0-9 a-z A-Z . - + ~ :
    NSCharacterSet *validVersion = [NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+~:"];
    if ([[version stringByTrimmingCharactersInSet:validVersion] length] != 0) {
        // contains invalid characters
        return nil;
    }

    // Valid chars for revision: 0-9 a-z A-Z . + ~
    NSCharacterSet *validRevision = [NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+~"];
    if ([[revision stringByTrimmingCharactersInSet:validRevision] length] != 0) {
        return nil;
    }

    return [[DpkgVersion alloc] initWithEpoch:epoch version:version revision:revision];
}

+ (BOOL)isValid:(NSString *)versionString {
    return [self parseFromString:versionString] != nil;
}

+ (NSInteger)compareVersionString:(NSString *)lhs to:(NSString *)rhs {
    DpkgVersion *a = [self parseFromString:lhs];
    DpkgVersion *b = [self parseFromString:rhs];
    if (!a || !b) {
        // Silent fallback consistent with Swift which prints error and returns 0.
        return 0;
    }
    return [self compare:a to:b];
}

+ (NSInteger)compare:(DpkgVersion *)a to:(DpkgVersion *)b {
    // Compare epoch
    if (a.epoch > b.epoch) {
        return 1;
    }
    if (a.epoch < b.epoch) {
        return -1;
    }

    // Compare version
    NSInteger vr = [self verrevcmp:a.version :b.version];
    if (vr != 0) {
        return vr;
    }

    // Compare revision
    return [self verrevcmp:a.revision :b.revision];
}

#pragma mark - verrevcmp helpers

+ (NSInteger)orderChar:(unichar)c {
    // ~ sorts before everything, even the empty string
    if (c == '~')
        return -1;

    // digits sort as 0 weight in non-numeric sections
    if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c])
        return 0;

    // ASCII letters sort by ASCII value
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
        return (NSInteger)c;
    }

    // non-ASCII treated as 0 (same as Swift logic)
    if (c > 127)
        return 0;

    // everything else: ASCII value + 256
    return (NSInteger)c + 256;
}

+ (NSInteger)verrevcmp:(NSString *)a :(NSString *)b {
    NSUInteger ia = 0, ib = 0;
    NSUInteger na = a.length, nb = b.length;

    while (ia < na || ib < nb) {
        NSInteger firstDiff = 0;

        // Handle non-number segments
        while ((ia < na && ![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[a characterAtIndex:ia]]) ||
               (ib < nb && ![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[b characterAtIndex:ib]])) {
            NSInteger ac = (ia < na) ? [self orderChar:[a characterAtIndex:ia]] : 0;
            NSInteger bc = (ib < nb) ? [self orderChar:[b characterAtIndex:ib]] : 0;
            if (ac != bc) {
                return ac - bc;
            }
            if (ia < na)
                ia++;
            if (ib < nb)
                ib++;
        }

        // Skip leading zeros
        while (ia < na && [a characterAtIndex:ia] == '0')
            ia++;
        while (ib < nb && [b characterAtIndex:ib] == '0')
            ib++;

        // Compare digit sequences
        while (ia < na && ib < nb) {
            unichar ca = [a characterAtIndex:ia];
            unichar cb = [b characterAtIndex:ib];
            BOOL da = [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:ca];
            BOOL db = [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:cb];
            if (!(da && db))
                break;

            if (firstDiff == 0) {
                NSInteger ad = (NSInteger)(ca - '0');
                NSInteger bd = (NSInteger)(cb - '0');
                firstDiff = ad - bd;
            }
            ia++;
            ib++;
        }

        if (ia < na && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[a characterAtIndex:ia]]) {
            return 1; // a has longer number
        }
        if (ib < nb && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[b characterAtIndex:ib]]) {
            return -1; // b has longer number
        }

        if (firstDiff != 0) {
            return firstDiff;
        }
    }

    return 0;
}

@end
