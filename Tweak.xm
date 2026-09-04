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
static char STCCoverSheetPanKey;
static char STCCoverSheetPanDelegateKey;
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

@interface CSCoverSheetViewController : UIViewController
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

static void STCForceHistoryRevealedIfNeeded(NCNotificationStructuredListViewController *controller) {
    if (!STCEnabled || !controller) return;

    NCNotificationMasterList *masterList = [controller masterList];
    if ([masterList respondsToSelector:@selector(setNotificationHistoryRevealed:)]) {
        [masterList setNotificationHistoryRevealed:YES];
    }
}

static NCNotificationStructuredListViewController *STCFindStructuredController(UIViewController *root) {
    if (!root) return nil;

    Class structuredClass = NSClassFromString(@"NCNotificationStructuredListViewController");
    if (structuredClass && [root isKindOfClass:structuredClass]) {
        return (NCNotificationStructuredListViewController *)root;
    }

    for (UIViewController *child in root.childViewControllers) {
        NCNotificationStructuredListViewController *found = STCFindStructuredController(child);
        if (found) return found;
    }

    UIViewController *presented = root.presentedViewController;
    if (presented) {
        NCNotificationStructuredListViewController *found = STCFindStructuredController(presented);
        if (found) return found;
    }

    return nil;
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

static void STCInstallCoverSheetPan(CSCoverSheetViewController *controller) {
    if (!controller) return;

    UIPanGestureRecognizer *existing = objc_getAssociatedObject(controller, &STCCoverSheetPanKey);
    if (existing && existing.view) return;

    UIView *host = controller.view;
    if (!host) return;

    STCFullScreenPanDelegate *delegate = [[STCFullScreenPanDelegate alloc] init];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller
                                                                         action:@selector(stc_coverSheetPullPan:)];
    pan.delegate = delegate;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;

    [host addGestureRecognizer:pan];
    objc_setAssociatedObject(controller, &STCCoverSheetPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCCoverSheetPanDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    STCInstallCoverSheetPan(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    STCInstallCoverSheetPan(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    STCInstallCoverSheetPan(self);
}

%new
- (void)stc_coverSheetPullPan:(UIPanGestureRecognizer *)pan {
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

    NCNotificationStructuredListViewController *target = STCFindStructuredController(self);
    if (!target) target = STCStructuredController;

    if (target) {
        STCStructuredController = target;
        STCForceHistoryRevealedIfNeeded(target);
        if (STCClearNotificationsFromController(target)) {
            STCPlayClearHaptic();
        }
    }
}

%end

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;
    STCStructuredController = self;
    STCForceHistoryRevealedIfNeeded(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    STCStructuredController = self;
    STCForceHistoryRevealedIfNeeded(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    STCStructuredController = self;
    STCForceHistoryRevealedIfNeeded(self);
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
