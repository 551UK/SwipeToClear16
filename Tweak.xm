#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <objc/runtime.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static BOOL STCEnabled = YES;
static BOOL STCPullToClearEnabled = YES;
static CGFloat STCSwipeDistance = 30.0;
static CGFloat STCClearAreaPercent = 80.0;
static double STCHapticDurationMS = 100.0;

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
@end

@interface CSCoverSheetViewController : UIViewController
@end

static __weak NCNotificationStructuredListViewController *STCStructuredController = nil;
static char STCCoverSheetPanKey;
static char STCCoverSheetPanDelegateKey;
static char STCDidClearThisPullKey;

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
    id hapticDuration = STCCopyPreference(@"hapticDurationMS");
    id clearArea = STCCopyPreference(@"clearAreaPercent");

    double percent = [clearArea respondsToSelector:@selector(doubleValue)] ? [clearArea doubleValue] : 80.0;
    STCClearAreaPercent = isfinite(percent) && percent >= 10.0 && percent <= 100.0 ? percent : 80.0;

    STCEnabled = enabled ? [enabled boolValue] : YES;
    STCPullToClearEnabled = pull ? [pull boolValue] : YES;
    STCSwipeDistance = swipeDistance ? [swipeDistance doubleValue] : 30.0;

    if (STCSwipeDistance < 10.0) STCSwipeDistance = 10.0;
    if (STCSwipeDistance > 120.0) STCSwipeDistance = 120.0;
    double milliseconds = [hapticDuration respondsToSelector:@selector(doubleValue)] ? [hapticDuration doubleValue] : 100.0;
    STCHapticDurationMS = isfinite(milliseconds) && milliseconds >= 1.0 && milliseconds <= 1000.0 ? milliseconds : 100.0;
}

static BOOL STCPullFeatureEnabled(void) {
    return STCEnabled && STCPullToClearEnabled;
}

static void STCPlayFallbackHaptic(void) {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    [feedback prepare];
    [feedback impactOccurredWithIntensity:1.0];
}

static void STCPlayClearHaptic(void) {
    const NSTimeInterval duration = STCHapticDurationMS / 1000.0;
    // Keep engine startup off SpringBoard's UI thread. One continuous pulse
    // gives the clear gesture more weight than the already-maximal UIKit tap.
    static dispatch_queue_t hapticQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hapticQueue = dispatch_queue_create("com.551.swipetoclear16.haptics", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(hapticQueue, ^{
        static CHHapticEngine *engine;
        static id<CHHapticPatternPlayer> player;
        NSError *error = nil;

        if ([CHHapticEngine capabilitiesForHardware].supportsHaptics) {
            if (!engine) {
                engine = [[CHHapticEngine alloc] initAndReturnError:&error];
                engine.playsHapticsOnly = YES;
                engine.autoShutdownEnabled = YES;
            }

            // Restart after idle shutdown or interruption, and create a fresh
            // player so a haptic-server reset cannot leave a stale player.
            if (engine && [engine startAndReturnError:&error]) {
                CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc]
                    initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0];
                CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc]
                    initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5];
                CHHapticEvent *pulse = [[CHHapticEvent alloc]
                    initWithEventType:CHHapticEventTypeHapticContinuous
                    parameters:@[intensity, sharpness] relativeTime:0.0 duration:duration];
                CHHapticPattern *pattern = [[CHHapticPattern alloc]
                    initWithEvents:@[pulse] parameters:@[] error:&error];
                player = pattern ? [engine createPlayerWithPattern:pattern error:&error] : nil;
                if (player && [player startAtTime:CHHapticTimeImmediate error:&error]) return;
            }
        }

        // Preserve feedback if Core Haptics is unavailable; retry next swipe.
        player = nil;
        engine = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            STCPlayFallbackHaptic();
        });
    });
}

static BOOL STCClearNotificationsFromController(NCNotificationStructuredListViewController *controller) {
    NCNotificationStructuredSectionList *incoming = [[controller masterList] incomingSectionList];
    if (!incoming) return NO;

    if ([incoming respondsToSelector:@selector(clearAll)]) {
        [incoming clearAll];
        return YES;
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

    return STCFindStructuredController(root.presentedViewController);
}

@interface STCFullScreenPanDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation STCFullScreenPanDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (!STCPullFeatureEnabled()) return NO;

    // Decide at touch-down, before the pan begins. A scroll starting on the
    // right must never become a clear gesture when the finger drifts left.
    UIView *coordinateView = gestureRecognizer.view.window ?: gestureRecognizer.view;
    if (!coordinateView || CGRectGetWidth(coordinateView.bounds) <= 0.0) return NO;
    CGPoint start = [touch locationInView:coordinateView];
    CGFloat left = CGRectGetMinX(coordinateView.bounds);
    CGFloat boundary = left + CGRectGetWidth(coordinateView.bounds) * STCClearAreaPercent / 100.0;
    return start.x >= left && start.x < boundary;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!STCPullFeatureEnabled()) return NO;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    return velocity.y > 0.0 && fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

static void STCInstallCoverSheetPan(CSCoverSheetViewController *controller) {
    if (!controller || objc_getAssociatedObject(controller, &STCCoverSheetPanKey)) return;

    STCFullScreenPanDelegate *delegate = [[STCFullScreenPanDelegate alloc] init];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:controller
                                                                         action:@selector(stc_coverSheetPullPan:)];
    pan.delegate = delegate;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;

    [controller.view addGestureRecognizer:pan];
    objc_setAssociatedObject(controller, &STCCoverSheetPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &STCCoverSheetPanDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void STCPrefsChangedCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        STCLoadPrefs();
        STCForceHistoryRevealedIfNeeded(STCStructuredController);
    });
}

%hook CSCoverSheetViewController

- (void)viewDidLoad {
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

    if (state != UIGestureRecognizerStateChanged ||
        [objc_getAssociatedObject(self, &STCDidClearThisPullKey) boolValue]) {
        return;
    }

    UIView *host = pan.view ?: self.view;
    CGPoint translation = [pan translationInView:host];
    CGPoint velocity = [pan velocityInView:host];

    if (translation.y <= 0.0 ||
        translation.y <= fabs(translation.x) ||
        velocity.y < -50.0 ||
        translation.y < STCSwipeDistance) {
        return;
    }

    CGFloat startY = [pan locationInView:host].y - translation.y;
    if (startY < 70.0) return;

    objc_setAssociatedObject(self, &STCDidClearThisPullKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NCNotificationStructuredListViewController *target = STCFindStructuredController(self) ?: STCStructuredController;
    if (!target) return;

    STCStructuredController = target;
    STCForceHistoryRevealedIfNeeded(target);

    if (STCClearNotificationsFromController(target)) {
        STCPlayClearHaptic();
    }
}

%end

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
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
    if (STCEnabled) return sectionList.sectionType == 2;
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
