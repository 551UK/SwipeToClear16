#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static BOOL STCEnabled = YES;
static BOOL STCPullToClearEnabled = YES;
static NSString *STCCustomColor = @"#FFFFFF";
static CGFloat STCIndicatorOffsetX = 195.0;
static CGFloat STCIndicatorOffsetY = 115.0;
static CGFloat STCRefreshControlScale = 0.8;
static CGFloat STCSwipeDistance = 30.0;

static __weak id STCStructuredController = nil;
static char STCRefreshControlKey;
static char STCLeftConstraintKey;
static char STCTopConstraintKey;
static char STCPanTargetInstalledKey;
static char STCDidClearThisPullKey;

@interface NCNotificationStructuredSectionList : NSObject
- (unsigned long long)sectionType;
- (void)clearAll;
- (void)clearAllNotificationRequests;
@end

@interface NCNotificationMasterList : NSObject
- (NCNotificationStructuredSectionList *)incomingSectionList;
@end

@interface NCNotificationStructuredListViewController : UIViewController
- (NCNotificationMasterList *)masterList;
- (UIScrollView *)masterListView;
@end

static UIColor *STCColorFromString(NSString *value) {
    NSString *string = [value isKindOfClass:[NSString class]] ? value : @"#FFFFFF";
    CGFloat alpha = 1.0;

    NSArray<NSString *> *parts = [string componentsSeparatedByString:@":"];
    NSString *hex = parts.firstObject ?: @"#FFFFFF";
    if (parts.count > 1) {
        alpha = MAX(0.0, MIN(1.0, parts[1].doubleValue));
    }

    hex = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (hex.length != 6 && hex.length != 8) hex = @"FFFFFF";

    unsigned long long raw = 0;
    [[NSScanner scannerWithString:hex] scanHexLongLong:&raw];

    CGFloat red = 1.0, green = 1.0, blue = 1.0;
    if (hex.length == 8) {
        red = ((raw >> 24) & 0xFF) / 255.0;
        green = ((raw >> 16) & 0xFF) / 255.0;
        blue = ((raw >> 8) & 0xFF) / 255.0;
        alpha = (raw & 0xFF) / 255.0;
    } else {
        red = ((raw >> 16) & 0xFF) / 255.0;
        green = ((raw >> 8) & 0xFF) / 255.0;
        blue = (raw & 0xFF) / 255.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

static id STCCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)STCPrefsDomain);
    return value ? CFBridgingRelease(value) : nil;
}

static void STCLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)STCPrefsDomain);

    id enabled = STCCopyPreference(@"Enabled");
    id pull = STCCopyPreference(@"pullToClearEnabled");
    id color = STCCopyPreference(@"customColor");
    id offsetX = STCCopyPreference(@"offsetX");
    id offsetY = STCCopyPreference(@"offsetY");
    id swipeDistance = STCCopyPreference(@"swipeDistance");

    STCEnabled = enabled ? [enabled boolValue] : YES;
    STCPullToClearEnabled = pull ? [pull boolValue] : YES;
    STCCustomColor = [color isKindOfClass:[NSString class]] ? [color copy] : @"#FFFFFF";
    STCIndicatorOffsetX = offsetX ? [offsetX doubleValue] : 195.0;
    STCIndicatorOffsetY = offsetY ? [offsetY doubleValue] : 115.0;
    STCSwipeDistance = swipeDistance ? [swipeDistance doubleValue] : 30.0;

    if (STCSwipeDistance < 10.0) STCSwipeDistance = 10.0;
    if (STCSwipeDistance > 120.0) STCSwipeDistance = 120.0;
}

static BOOL STCPullFeatureEnabled(void) {
    return STCEnabled && STCPullToClearEnabled;
}

static void STCPlayClearHaptic(void) {
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback prepare];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

static BOOL STCClearNotificationsFromController(NCNotificationStructuredListViewController *controller) {
    if (!controller) return NO;

    NCNotificationMasterList *masterList = [controller masterList];
    if (!masterList) return NO;

    NCNotificationStructuredSectionList *incoming = [masterList incomingSectionList];
    if (!incoming) return NO;

    if (@available(iOS 16.0, *)) {
        if ([incoming respondsToSelector:@selector(clearAll)]) {
            [incoming clearAll];
            return YES;
        }
    }

    if ([incoming respondsToSelector:@selector(clearAllNotificationRequests)]) {
        [incoming clearAllNotificationRequests];
        return YES;
    }

    return NO;
}

static void STCRemoveRefreshControl(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;

    UIRefreshControl *refresh = objc_getAssociatedObject(controller, &STCRefreshControlKey);
    NSLayoutConstraint *left = objc_getAssociatedObject(controller, &STCLeftConstraintKey);
    NSLayoutConstraint *top = objc_getAssociatedObject(controller, &STCTopConstraintKey);
    UIScrollView *listView = [controller masterListView];

    if (left) left.active = NO;
    if (top) top.active = NO;
    if (refresh && listView.refreshControl == refresh) {
        listView.refreshControl = nil;
    }

    objc_setAssociatedObject(controller, &STCRefreshControlKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCLeftConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCTopConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void STCConfigureRefreshControl(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;

    UIScrollView *listView = [controller masterListView];
    if (!listView) return;

    if (!STCPullFeatureEnabled()) {
        STCRemoveRefreshControl(controller);
        return;
    }

    UIRefreshControl *refresh = objc_getAssociatedObject(controller, &STCRefreshControlKey);
    if (!refresh) {
        if (listView.refreshControl) return;

        refresh = [[UIRefreshControl alloc] init];
        refresh.transform = CGAffineTransformMakeScale(STCRefreshControlScale, STCRefreshControlScale);
        [refresh addTarget:controller
                    action:@selector(stc_clearNotifications:)
          forControlEvents:UIControlEventValueChanged];

        listView.refreshControl = refresh;
        refresh.translatesAutoresizingMaskIntoConstraints = NO;

        NSLayoutConstraint *left = [NSLayoutConstraint constraintWithItem:refresh
                                                                attribute:NSLayoutAttributeLeft
                                                                relatedBy:NSLayoutRelationEqual
                                                                   toItem:controller.view
                                                                attribute:NSLayoutAttributeLeft
                                                               multiplier:1.0
                                                                 constant:STCIndicatorOffsetX];
        NSLayoutConstraint *top = [NSLayoutConstraint constraintWithItem:refresh
                                                               attribute:NSLayoutAttributeTop
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:controller.view
                                                               attribute:NSLayoutAttributeTop
                                                              multiplier:1.0
                                                                constant:STCIndicatorOffsetY];
        [controller.view addConstraint:left];
        [controller.view addConstraint:top];

        objc_setAssociatedObject(controller, &STCRefreshControlKey, refresh, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &STCLeftConstraintKey, left, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &STCTopConstraintKey, top, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    refresh.tintColor = STCColorFromString(STCCustomColor);
    refresh.transform = CGAffineTransformMakeScale(STCRefreshControlScale, STCRefreshControlScale);

    NSLayoutConstraint *left = objc_getAssociatedObject(controller, &STCLeftConstraintKey);
    NSLayoutConstraint *top = objc_getAssociatedObject(controller, &STCTopConstraintKey);
    if (left) left.constant = STCIndicatorOffsetX;
    if (top) top.constant = STCIndicatorOffsetY;

    if (!objc_getAssociatedObject(controller, &STCPanTargetInstalledKey)) {
        UIPanGestureRecognizer *pan = listView.panGestureRecognizer;
        if (pan) {
            [pan addTarget:controller action:@selector(stc_shortPullPan:)];
            objc_setAssociatedObject(controller, &STCPanTargetInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void STCPrefsChangedCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    STCLoadPrefs();

    dispatch_async(dispatch_get_main_queue(), ^{
        NCNotificationStructuredListViewController *controller = STCStructuredController;
        if (controller) STCConfigureRefreshControl(controller);
    });
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;
    STCStructuredController = self;
    STCConfigureRefreshControl(self);
}

%new
- (void)stc_shortPullPan:(UIPanGestureRecognizer *)pan {
    if (!STCPullFeatureEnabled()) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(self, &STCDidClearThisPullKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (pan.state != UIGestureRecognizerStateChanged) return;
    if ([objc_getAssociatedObject(self, &STCDidClearThisPullKey) boolValue]) return;

    UIScrollView *listView = [pan.view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)pan.view : [self masterListView];
    UIRefreshControl *refresh = objc_getAssociatedObject(self, &STCRefreshControlKey);
    if (!listView || !refresh) return;

    CGPoint translation = [pan translationInView:listView];
    CGPoint velocity = [pan velocityInView:listView];
    CGFloat topOffset = -listView.adjustedContentInset.top;
    BOOL atTop = listView.contentOffset.y <= (topOffset + 1.0);
    BOOL downward = translation.y > 0.0 && translation.y > fabs(translation.x) && velocity.y >= -50.0;

    if (!atTop || !downward || translation.y < STCSwipeDistance) return;

    [refresh beginRefreshing];
    [refresh sendActionsForControlEvents:UIControlEventValueChanged];
}

%new
- (void)stc_clearNotifications:(UIRefreshControl *)refresh {
    [refresh endRefreshing];

    if (!STCPullFeatureEnabled()) return;
    if ([objc_getAssociatedObject(self, &STCDidClearThisPullKey) boolValue]) return;

    objc_setAssociatedObject(self, &STCDidClearThisPullKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (STCClearNotificationsFromController(self)) {
        STCPlayClearHaptic();
    }
}

%end

%hook SBMainDisplayPolicyAggregator

- (BOOL)_allowsCapabilityCoverSheetSpotlightWithExplanation:(id)explanation {
    if (STCPullFeatureEnabled()) return NO;
    return %orig;
}

%end

%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    if (STCEnabled) return;
    %orig;
}

%end

%hook NCNotificationMasterList

- (BOOL)_isNotificationRequest:(id)request forSectionList:(NCNotificationStructuredSectionList *)sectionList {
    if (STCEnabled) {
        return sectionList.sectionType == 2;
    }
    return %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(NCNotificationStructuredSectionList *)toList
                          passingTest:(id)passingTest
            filterRequestsPassingTest:(id)filterRequestsPassingTest
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests
                 filterForDestination:(BOOL)filterForDestination
                       animateRemoval:(BOOL)animateRemoval
           reorderGroupNotifications:(BOOL)reorderGroupNotifications {
    if (STCEnabled && toList.sectionType == 0) return;
    %orig;
}

- (void)migrateNotifications {
    if (STCEnabled) return;
    %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)passingTest
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests {
    if (STCEnabled) return;
    %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)passingTest
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests
             filterPersistentRequests:(BOOL)filterPersistentRequests {
    if (STCEnabled) return;
    %orig;
}

- (BOOL)_isNotificationRequestForIncomingSection:(id)request {
    if (STCEnabled) return YES;
    return %orig;
}

- (BOOL)_isNotificationRequestForHistorySection:(id)request {
    if (STCEnabled) return NO;
    return %orig;
}

%end

%ctor {
    STCLoadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    STCPrefsChangedCallback,
                                    (__bridge CFStringRef)STCPrefsChanged,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
