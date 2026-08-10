#import <UIKit/UIKit.h>
#import "PSSpecifier.h"

@interface PSTableCell : UITableViewCell

@property(nonatomic, retain) PSSpecifier *specifier;

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier;
- (void)setSpecifier:(PSSpecifier *)specifier;
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;

@end
