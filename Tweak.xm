#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static BOOL STCEnabled = YES;
static BOOL STCPullToClearEnabled = YES;
static CGFloat STCSwipeDistance = 30.0;

static __weak id STCStructuredController = nil;
static char STCPanTargetInstalledKey;
static char STCDidClearThisPullKey;

@interface NCNotificationStructuredSectionList : NSObject
- (unsigned long long)sectionType;
- (void)clearAll;
- (void)clearAllNotificationRequests;
@end

@interface NCNotificationMasterList : NSObject
- (NCNotificationStructuredSectionList *)incomingSectionList;
- (void)setNotificationHistoryRevealed:(BOOL)revealed;
- (BOOL)isNotificationHistoryRevealed;
@end

@interface NCNotificationStructuredListViewController : UIViewController
- (NCNotificationMasterList *)masterList;
- (UIScrollView *)masterListView;
@end

static id STCCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)STCPrefsDomain);
    return value ? CFBridgingRelease(value) : nil;
}

static void STCLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)STCPrefsDomain);

    id enabled = STCCopyPreference(@"Enabled");
    id pull = STCCopyPreference(@"pullToClearEnabled");
    id swipeDistance = STCCopyPreference(@"swipeDistance");

    STCEnabled = enabled ? [enabled boolValue] : YES;
    STCPullToClearEnabled = pull ? [pull boolValue] : YES;
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

static void STCInstallPanTarget(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;
    if (objc_getAssociatedObject(controller, &STCPanTargetInstalledKey)) return;

    UIScrollView *listView = [controller masterListView];
    UIPanGestureRecognizer *pan = listView.panGestureRecognizer;
    if (!pan) return;

    [pan addTarget:controller action:@selector(stc_shortPullPan:)];
    objc_setAssociatedObject(controller, &STCPanTargetInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void STCForceHistoryRevealedIfNeeded(NCNotificationStructuredListViewController *controller) {
    if (!STCEnabled || !controller) return;

    NCNotificationMasterList *masterList = [controller masterList];
    if ([masterList respondsToSelector:@selector(setNotificationHistoryRevealed:)]) {
        [masterList setNotificationHistoryRevealed:YES];
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
        if (controller) STCForceHistoryRevealedIfNeeded(controller);
    });
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;
    STCStructuredController = self;
    STCInstallPanTarget(self);
    STCForceHistoryRevealedIfNeeded(self);
}

%new
- (void)stc_shortPullPan:(UIPanGestureRecognizer *)pan {
    if (!STCPullFeatureEnabled()) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(self, &STCDidClearThisPullKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(self, &STCDidClearThisPullKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (pan.state != UIGestureRecognizerStateChanged) return;
    if ([objc_getAssociatedObject(self, &STCDidClearThisPullKey) boolValue]) return;

    UIScrollView *listView = [pan.view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)pan.view : [self masterListView];
    if (!listView) return;

    CGPoint translation = [pan translationInView:listView];
    CGPoint velocity = [pan velocityInView:listView];
    BOOL downward = translation.y > 0.0 && translation.y > fabs(translation.x) && velocity.y >= -50.0;
    if (!downward) return;

    // With notification history forced revealed, the old exact-at-top test is
    // unreliable. Measure the real rubber-band pull instead: once the list is
    // physically dragged beyond its resting top by the configured distance,
    // clear immediately.
    CGFloat restingTop = -listView.adjustedContentInset.top;
    CGFloat overscroll = MAX(0.0, restingTop - listView.contentOffset.y);

    if (overscroll < STCSwipeDistance) return;

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

- (void)setNotificationHistoryRevealed:(BOOL)revealed {
    if (STCEnabled) {
        %orig(YES);
        return;
    }
    %orig;
}

- (BOOL)isNotificationHistoryRevealed {
    if (STCEnabled) return YES;
    return %orig;
}

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
