#import <UIKit/UIKit.h>
#import "PSViewController.h"
#import "PSSpecifier.h"

@interface PSListController : PSViewController {
    NSMutableArray *_specifiers;
}

@property(nonatomic, retain) NSArray *specifiers;

- (NSArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)reloadSpecifiers;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (id)cachedCellForSpecifier:(PSSpecifier *)specifier;

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section;

@end
