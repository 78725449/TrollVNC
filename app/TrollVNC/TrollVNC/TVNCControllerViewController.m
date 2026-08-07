/*
 This file is part of TrollVNC
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

#import "TVNCControllerViewController.h"

@interface TVNCControllerViewController ()

@property(nonatomic, strong) NSMutableArray<UIButton *> *chips;
@property(nonatomic, strong) UIButton *layoutBtn;
@property(nonatomic, strong) UILabel *emptyLabel;

@end

@implementation TVNCControllerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"控制端";

    // 顶部过滤：全部 / 直连 / 中继（圆角胶囊）
    UIStackView *filter = [[UIStackView alloc] init];
    filter.translatesAutoresizingMaskIntoConstraints = NO;
    filter.axis = UILayoutConstraintAxisHorizontal;
    filter.spacing = 8;
    self.chips = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"全部", @"直连", @"中继"];
    for (NSString *t in titles) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:t forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        b.layer.cornerRadius = 18;
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        b.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chips addObject:b];
        [filter addArrangedSubview:b];
    }
    [self.chips.firstObject setSelected:YES];
    [self updateChipAppearance];

    // 布局按钮（图标，点击弹布局选择）
    self.layoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.layoutBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *grid = [UIImage systemImageNamed:@"square.grid.2x2"];
    [self.layoutBtn setImage:grid forState:UIControlStateNormal];
    self.layoutBtn.tintColor = [UIColor labelColor];
    self.layoutBtn.layer.cornerRadius = 18;
    self.layoutBtn.layer.borderWidth = 1;
    self.layoutBtn.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.layoutBtn addTarget:self action:@selector(layoutTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 8;
    [topRow addArrangedSubview:filter];
    [topRow addArrangedSubview:self.layoutBtn];
    [self.view addSubview:topRow];

    // 空状态（U4 前占位）
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"暂无已连接设备
（控制端观看/控制能力在后续版本提供）";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [topRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [topRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.layoutBtn.widthAnchor constraintEqualToConstant:36],
        [self.layoutBtn.heightAnchor constraintEqualToConstant:36],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

#pragma mark - 过滤

- (void)chipTapped:(UIButton *)sender {
    for (UIButton *b in self.chips) {
        b.selected = (b == sender);
    }
    [self updateChipAppearance];
}

- (void)updateChipAppearance {
    for (UIButton *b in self.chips) {
        if (b.selected) {
            b.backgroundColor = [UIColor systemBlueColor];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        } else {
            b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            b.layer.borderColor = [UIColor separatorColor].CGColor;
        }
    }
}

#pragma mark - 布局

- (void)layoutTapped:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"布局"
                                                                   message:@"横屏 N / 竖屏 N（控制端卡片墙布局）"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *opts = @[@"竖屏1", @"竖屏2", @"竖屏3", @"竖屏4", @"竖屏5", @"竖屏6",
                                  @"横屏1", @"横屏2", @"横屏3", @"横屏4", @"横屏5", @"横屏6"];
    for (NSString *o in opts) {
        [sheet addAction:[UIAlertAction actionWithTitle:o style:UIAlertActionStyleDefault handler:nil]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
