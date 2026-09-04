#import "STCRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <spawn.h>
#import <unistd.h>
#import <dlfcn.h>

extern char **environ;

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static void STCLoadColorPicker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/var/jb/usr/lib/libcolorpicker.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (!handle) dlopen("/usr/lib/libcolorpicker.dylib", RTLD_LAZY | RTLD_GLOBAL);
    });
}

static BOOL STCSpawnTool(const char *tool, char * const argv[]) {
    if (!tool || access(tool, X_OK) != 0) return NO;
    pid_t pid = 0;
    return posix_spawn(&pid, tool, NULL, NULL, argv, environ) == 0;
}

@implementation STCRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    STCLoadColorPicker();

    UIImage *image = [UIImage systemImageNamed:@"bell.slash.fill"];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:image];
    iconView.tintColor = UIColor.labelColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"SwipeToClear16";
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.textColor = UIColor.labelColor;

    UIStackView *titleView = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel]];
    titleView.axis = UILayoutConstraintAxisHorizontal;
    titleView.alignment = UIStackViewAlignmentCenter;
    titleView.spacing = 6.0;

    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:19.0],
        [iconView.heightAnchor constraintEqualToConstant:19.0]
    ]];

    self.navigationItem.titleView = titleView;
}

- (PSSpecifier *)preferenceSpecifierNamed:(NSString *)name
                                      cell:(PSCellType)cell
                                       key:(NSString *)key
                              defaultValue:(id)defaultValue {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:nil
                                                              cell:cell
                                                              edit:nil];
    [specifier setProperty:STCPrefsDomain forKey:@"defaults"];
    [specifier setProperty:key forKey:@"key"];
    if (defaultValue) [specifier setProperty:defaultValue forKey:@"default"];
    [specifier setProperty:STCPrefsChanged forKey:@"PostNotification"];
    return specifier;
}

- (NSArray *)manualSpecifiers {
    STCLoadColorPicker();
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *mainGroup = [PSSpecifier groupSpecifierWithName:@"SwipeToClear16"];
    [mainGroup setProperty:@"KeepItSimple-style single notification list with a shorter pull to clear." forKey:@"footerText"];
    [specifiers addObject:mainGroup];

    [specifiers addObject:[self preferenceSpecifierNamed:@"Enabled"
                                                   cell:PSSwitchCell
                                                    key:@"Enabled"
                                           defaultValue:@YES]];

    PSSpecifier *pullGroup = [PSSpecifier groupSpecifierWithName:@"Pull to Clear Notifications"];
    [pullGroup setProperty:@"Indicator position matches KeepItSimple defaults. X moves it left/right and Y moves it up/down." forKey:@"footerText"];
    [specifiers addObject:pullGroup];

    [specifiers addObject:[self preferenceSpecifierNamed:@"Pull to Clear"
                                                   cell:PSSwitchCell
                                                    key:@"pullToClearEnabled"
                                           defaultValue:@YES]];

    PSSpecifier *color = [PSSpecifier preferenceSpecifierNamed:@"Indicator Color"
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSLinkCell
                                                          edit:nil];
    Class colorCellClass = NSClassFromString(@"PFSimpleLiteColorCell");
    [color setProperty:(colorCellClass ?: (id)@"PFSimpleLiteColorCell") forKey:@"cellClass"];
    [color setProperty:@{
        @"defaults": STCPrefsDomain,
        @"key": @"customColor",
        @"fallback": @"#FFFFFF",
        @"PostNotification": STCPrefsChanged
    } forKey:@"libcolorpicker"];
    [specifiers addObject:color];

    PSSpecifier *offsetX = [self preferenceSpecifierNamed:@"Indicator X"
                                                      cell:PSSliderCell
                                                       key:@"offsetX"
                                              defaultValue:@195.0];
    [offsetX setProperty:@10.0 forKey:@"min"];
    [offsetX setProperty:@400.0 forKey:@"max"];
    [offsetX setProperty:@YES forKey:@"showValue"];
    [specifiers addObject:offsetX];

    PSSpecifier *offsetY = [self preferenceSpecifierNamed:@"Indicator Y"
                                                      cell:PSSliderCell
                                                       key:@"offsetY"
                                              defaultValue:@115.0];
    [offsetY setProperty:@30.0 forKey:@"min"];
    [offsetY setProperty:@800.0 forKey:@"max"];
    [offsetY setProperty:@YES forKey:@"showValue"];
    [specifiers addObject:offsetY];

    PSSpecifier *distance = [self preferenceSpecifierNamed:@"Swipe Distance"
                                                       cell:PSSliderCell
                                                        key:@"swipeDistance"
                                               defaultValue:@30.0];
    [distance setProperty:@10.0 forKey:@"min"];
    [distance setProperty:@120.0 forKey:@"max"];
    [distance setProperty:@YES forKey:@"showValue"];
    [specifiers addObject:distance];

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"Actions"]];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"Respring"
                                                          target:self
                                                             set:nil
                                                             get:nil
                                                          detail:nil
                                                            cell:PSButtonCell
                                                            edit:nil];
    [respring setButtonAction:@selector(respring)];
    [respring setProperty:NSStringFromSelector(@selector(respring)) forKey:@"action"];
    [specifiers addObject:respring];

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"Links"]];

    PSSpecifier *repo = [PSSpecifier preferenceSpecifierNamed:@"GitHub Repo"
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:nil
                                                         cell:PSButtonCell
                                                         edit:nil];
    [repo setButtonAction:@selector(openRepo)];
    [repo setProperty:NSStringFromSelector(@selector(openRepo)) forKey:@"action"];
    [specifiers addObject:repo];

    return specifiers;
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [[self manualSpecifiers] copy];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"] ?: STCPrefsDomain;
    NSString *key = [specifier propertyForKey:@"key"];
    id defaultValue = [specifier propertyForKey:@"default"];
    if (!key) return defaultValue;

    CFPreferencesAppSynchronize((__bridge CFStringRef)defaults);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)defaults);
    return value ? CFBridgingRelease(value) : defaultValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"] ?: STCPrefsDomain;
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *notification = [specifier propertyForKey:@"PostNotification"];
    if (!key) return;

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)defaults);
    CFPreferencesAppSynchronize((__bridge CFStringRef)defaults);

    if (notification.length > 0) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)notification,
                                             NULL,
                                             NULL,
                                             true);
    }
}

- (void)openRepo {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/SwipeToClear16"];
    if (!url) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = UIApplication.sharedApplication;
        if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [application openURL:url options:@{} completionHandler:nil];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [application openURL:url];
#pragma clang diagnostic pop
        }
    });
}

- (void)openRepo:(id)sender { [self openRepo]; }

- (void)respring {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        const char *sbreload = "/var/jb/usr/bin/sbreload";
        if (access(sbreload, X_OK) == 0) {
            char *args[] = {(char *)sbreload, NULL};
            if (STCSpawnTool(sbreload, args)) return;
        }

        const char *rootlessKillall = "/var/jb/usr/bin/killall";
        if (access(rootlessKillall, X_OK) == 0) {
            char *args[] = {(char *)rootlessKillall, (char *)"-9", (char *)"SpringBoard", NULL};
            if (STCSpawnTool(rootlessKillall, args)) return;
        }

        const char *systemKillall = "/usr/bin/killall";
        char *args[] = {(char *)systemKillall, (char *)"-9", (char *)"SpringBoard", NULL};
        STCSpawnTool(systemKillall, args);
    });
}

- (void)respring:(id)sender { [self respring]; }

@end
