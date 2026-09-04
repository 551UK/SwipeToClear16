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
static char STCFullScreenPanKey;
static char STCFullScreenPanDelegateKey;
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

@interface STCFullScreenPanDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation STCFullScreenPanDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!STCPullFeatureEnabled()) return NO;
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (velocity.y <= 0.0) return NO;
    return fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

static void STCInstallFullScreenPan(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;

    // Install immediately on the controller view, even before it has joined a
    // UIWindow after SpringBoard starts. As soon as the Lock Screen window is
    // available, move the exact same recognizer onto that window so the proven
    // full-screen behavior from v1.0.9/v1.0.10 is preserved.
    UIView *host = controller.view.window ?: controller.view;
    if (!host) return;

    UIPanGestureRecognizer *existing = objc_getAssociatedObject(controller, &STCFullScreenPanKey);
    if (existing) {
        if (existing.view != host) {
            if (existing.view) [existing.view removeGestureRecognizer:existing];
            [host addGestureRecognizer:existing];
        }
        return;
    }

    STCFullScreenPanDelegate *delegate = [[STCFullScreenPanDelegate alloc] init];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller
                                                                         action:@selector(stc_fullScreenPullPan:)];
    pan.delegate = delegate;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;

    [host addGestureRecognizer:pan];
    objc_setAssociatedObject(controller, &STCFullScreenPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCFullScreenPanDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void STCRemoveFullScreenPan(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;

    UIPanGestureRecognizer *pan = objc_getAssociatedObject(controller, &STCFullScreenPanKey);
    if (pan.view) [pan.view removeGestureRecognizer:pan];

    objc_setAssociatedObject(controller, &STCFullScreenPanKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCFullScreenPanDelegateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCDidClearThisPullKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void STCForceHistoryRevealedIfNeeded(NCNotificationStructuredListViewController *controller) {
    if (!STCEnabled || !controller) return;

    NCNotificationMasterList *masterList = [controller masterList];
    if ([masterList respondsToSelector:@selector(setNotificationHistoryRevealed:)]) {
        [masterList setNotificationHistoryRevealed:YES];
    }
}

static void STCEnsureLockScreenReady(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;
    STCStructuredController = controller;
    STCInstallFullScreenPan(controller);
    STCForceHistoryRevealedIfNeeded(controller);
}

static void STCScheduleStartupInstall(NCNotificationStructuredListViewController *controller) {
    if (!controller) return;

    // These are now only quick migration checks so the recognizer moves from
    // the controller view to the Lock Screen window as soon as it exists. The
    // gesture itself is already installed synchronously in viewDidLoad.
    const NSTimeInterval delays[] = {0.0, 0.02, 0.05, 0.10, 0.20, 0.40, 0.80};
    const NSUInteger count = sizeof(delays) / sizeof(delays[0]);

    for (NSUInteger i = 0; i < count; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (STCStructuredController != controller) return;
            STCEnsureLockScreenReady(controller);
        });
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
        if (controller) STCEnsureLockScreenReady(controller);
    });
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;
    STCEnsureLockScreenReady(self);
    STCScheduleStartupInstall(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    STCEnsureLockScreenReady(self);
    STCScheduleStartupInstall(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCEnsureLockScreenReady(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    STCEnsureLockScreenReady(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    STCRemoveFullScreenPan(self);
    %orig;
}

%new
- (void)stc_fullScreenPullPan:(UIPanGestureRecognizer *)pan {
    if (!STCPullFeatureEnabled()) return;

    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(self, &STCDidClearThisPullKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(self, &STCDidClearThisPullKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (state != UIGestureRecognizerStateChanged) return;
    if ([objc_getAssociatedObject(self, &STCDidClearThisPullKey) boolValue]) return;

    UIView *host = pan.view ?: self.view;
    CGPoint translation = [pan translationInView:host];
    CGPoint velocity = [pan velocityInView:host];
    BOOL downward = translation.y > 0.0 && translation.y > fabs(translation.x) && velocity.y >= -50.0;
    if (!downward || translation.y < STCSwipeDistance) return;

    CGPoint currentLocation = [pan locationInView:host];
    CGFloat startY = currentLocation.y - translation.y;
    if (startY < 70.0) return;

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
