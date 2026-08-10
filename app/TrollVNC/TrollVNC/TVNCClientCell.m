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

#import "TVNCClientCell.h"

@implementation TVNCClientCell {
    UILabel *_idLabel;
    UILabel *_hostLabel;
    UILabel *_subtitleLabel;
    UIImageView *_badgeView;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self)
        return nil;

    // Monospaced bold for ID
    _idLabel = [UILabel new];
    _idLabel.font = [UIFont monospacedSystemFontOfSize:[UIFont labelFontSize] weight:UIFontWeightBold];
    _idLabel.textColor = [UIColor labelColor];

    _hostLabel = [UILabel new];
    _hostLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _hostLabel.textColor = [UIColor labelColor];
    [_hostLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];

    _badgeView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hand.raised.slash.fill"]];
    _badgeView.tintColor = [UIColor systemOrangeColor];
    _badgeView.contentMode = UIViewContentModeScaleAspectFit;
    _badgeView.accessibilityLabel = NSLocalizedStringFromTableInBundle(@"View-Only", @"Localizable", self.bundle, nil);

    for (UIView *v in @[ _idLabel, _hostLabel, _subtitleLabel, _badgeView ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:v];
    }

    // Layout
    UILayoutGuide *g = self.contentView.layoutMarginsGuide;

    // Row 1: [ID][space][Host][spacer][Badge]
    [NSLayoutConstraint activateConstraints:@[
        [_idLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_idLabel.topAnchor constraintEqualToAnchor:g.topAnchor],

        [_hostLabel.leadingAnchor constraintEqualToAnchor:_idLabel.trailingAnchor constant:8],
        [_hostLabel.centerYAnchor constraintEqualToAnchor:_idLabel.centerYAnchor],
        [_hostLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeView.leadingAnchor constant:-8],

        [_badgeView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_badgeView.centerYAnchor constraintEqualToAnchor:_idLabel.centerYAnchor],
        [_badgeView.widthAnchor constraintEqualToConstant:18],
        [_badgeView.heightAnchor constraintEqualToConstant:18],

        // Row 2: subtitle leading aligned to host leading
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_hostLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_idLabel.bottomAnchor constant:4],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];

    return self;
}

- (UILabel *)idLabel {
    return _idLabel;
}
- (UILabel *)hostLabel {
    return _hostLabel;
}
- (UILabel *)subtitleLabel {
    return _subtitleLabel;
}
- (UIImageView *)badgeView {
    return _badgeView;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _idLabel.text = @"";
    _hostLabel.text = @"";
    _subtitleLabel.text = @"";
    _badgeView.hidden = YES;
}

- (void)configureWithId:(NSString *)cid
                   host:(NSString *)host
               viewOnly:(BOOL)viewOnly
               subtitle:(NSString *)subtitle
           primaryColor:(UIColor *)primaryColor {
    _idLabel.text = cid ?: @"";
    _hostLabel.text = host ?: @"";
    _subtitleLabel.text = subtitle ?: @"";
    _badgeView.hidden = !viewOnly;
    if (primaryColor) {
        _idLabel.textColor = primaryColor;
    }
}

@end
