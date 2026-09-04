#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static BOOL STCEnabled = YES;
static BOOL STCClearedThisPan = NO;
static const CGFloat STCTriggerDistance = 26.0;
static const CGFloat STCSpinnerStartDistance = 4.0;

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface NCNotificationStructuredListViewController : UIViewController
- (id)masterList;
- (UIScrollView *)masterListView;
@end

static void STCLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)STCPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)STCPrefsDomain);
    STCEnabled = value ? CFBooleanGetValue((CFBooleanRef)value) : YES;
    if (value) CFRelease(value);
}

static void STCPrefsChangedCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    STCLoadPrefs();
}

static BOOL STCDeviceIsLocked(void) {
    Class cls = objc_getClass("SBLockScreenManager");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) return NO;

    id manager = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(sharedInstance));
    if (!manager || ![manager respondsToSelector:@selector(isUILocked)]) return NO;

    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, @selector(isUILocked));
}

static BOOL STCShouldOverrideNotificationHistory(void) {
    return STCEnabled && STCDeviceIsLocked();
}

static void STCPlayClearHaptic(void) {
    // Matches KeepItSimple 1.2.5: notification feedback, prepared before firing success.
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback prepare];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

static BOOL STCClearSectionList(id sectionList) {
    if (!sectionList) return NO;

    SEL clearAllSel = NSSelectorFromString(@"clearAll");
    if ([sectionList respondsToSelector:clearAllSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sectionList, clearAllSel);
        return YES;
    }

    SEL clearRequestsSel = NSSelectorFromString(@"clearAllNotificationRequests");
    if ([sectionList respondsToSelector:clearRequestsSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sectionList, clearRequestsSel);
        return YES;
    }

    return NO;
}

static BOOL STCClearNotificationsFromController(id controller) {
    if (!controller) return NO;

    SEL masterListSel = NSSelectorFromString(@"masterList");
    if (![controller respondsToSelector:masterListSel]) return NO;

    id masterList = ((id (*)(id, SEL))objc_msgSend)(controller, masterListSel);
    if (!masterList) return NO;

    BOOL cleared = NO;
    NSArray<NSString *> *sectionSelectors = @[
        @"incomingSectionList",
        @"historySectionList",
        @"missedSectionList"
    ];

    for (NSString *selectorName in sectionSelectors) {
        SEL sectionSel = NSSelectorFromString(selectorName);
        if (![masterList respondsToSelector:sectionSel]) continue;

        id sectionList = ((id (*)(id, SEL))objc_msgSend)(masterList, sectionSel);
        cleared = STCClearSectionList(sectionList) || cleared;
    }

    if (!cleared) {
        SEL controllerClearSel = NSSelectorFromString(@"_clearAllNotificationRequests");
        if ([controller respondsToSelector:controllerClearSel]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, controllerClearSel);
            cleared = YES;
        }
    }

    return cleared;
}

static void STCForceHistoryVisibleOnObject(id object) {
    if (!object || !STCShouldOverrideNotificationHistory()) return;

    SEL forceSel = NSSelectorFromString(@"forceNotificationHistoryRevealed:animated:");
    if ([object respondsToSelector:forceSel]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(object, forceSel, YES, NO);
        return;
    }

    SEL revealSel = NSSelectorFromString(@"revealNotificationHistory:animated:");
    if ([object respondsToSelector:revealSel]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(object, revealSel, YES, NO);
    }
}

static void STCForceVisibleFromStructuredController(id controller) {
    if (!controller || !STCShouldOverrideNotificationHistory()) return;

    STCForceHistoryVisibleOnObject(controller);

    SEL delegateSel = NSSelectorFromString(@"delegate");
    if ([controller respondsToSelector:delegateSel]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)(controller, delegateSel);
        STCForceHistoryVisibleOnObject(delegate);
    }
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;

    UIScrollView *listView = nil;
    if ([self respondsToSelector:@selector(masterListView)]) {
        listView = [self masterListView];
    }

    if (!listView) return;

    UIRefreshControl *refresh = listView.refreshControl;
    if (!refresh) {
        refresh = [[UIRefreshControl alloc] init];
        refresh.tintColor = [UIColor whiteColor];
        refresh.transform = CGAffineTransformMakeScale(0.78, 0.78);
        listView.refreshControl = refresh;
    }

    [refresh addTarget:self action:@selector(stc_refreshTriggered:) forControlEvents:UIControlEventValueChanged];

    UIPanGestureRecognizer *pan = listView.panGestureRecognizer;
    if (pan) {
        [pan addTarget:self action:@selector(stc_handleNotificationPan:)];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCForceVisibleFromStructuredController(self);
}

- (void)revealNotificationHistory:(BOOL)revealed animated:(BOOL)animated {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(YES, NO);
        return;
    }
    %orig;
}

%new
- (void)stc_refreshTriggered:(UIRefreshControl *)refresh {
    if (!STCShouldOverrideNotificationHistory()) {
        [refresh endRefreshing];
        return;
    }

    if (!STCClearedThisPan) {
        STCClearedThisPan = YES;
        if (STCClearNotificationsFromController(self)) {
            STCPlayClearHaptic();
        }
    }

    [refresh endRefreshing];
    STCForceVisibleFromStructuredController(self);
}

%new
- (void)stc_handleNotificationPan:(UIPanGestureRecognizer *)pan {
    UIScrollView *listView = (UIScrollView *)pan.view;
    UIRefreshControl *refresh = [listView isKindOfClass:[UIScrollView class]] ? listView.refreshControl : nil;

    if (!STCShouldOverrideNotificationHistory()) {
        STCClearedThisPan = NO;
        if (refresh.refreshing) [refresh endRefreshing];
        return;
    }

    UIGestureRecognizerState state = pan.state;

    if (state == UIGestureRecognizerStateBegan) {
        STCClearedThisPan = NO;
        STCForceVisibleFromStructuredController(self);
        return;
    }

    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        if (refresh.refreshing) [refresh endRefreshing];
        STCClearedThisPan = NO;
        STCForceVisibleFromStructuredController(self);
        return;
    }

    if (state != UIGestureRecognizerStateChanged) return;

    UIView *view = pan.view;
    CGPoint translation = [pan translationInView:view];
    CGPoint velocity = [pan velocityInView:view];

    BOOL downward = translation.y > 0.0 &&
                    translation.y > fabs(translation.x) &&
                    velocity.y >= -50.0;

    if (!downward) {
        if (refresh.refreshing) [refresh endRefreshing];
        return;
    }

    // Keep the notification controller in the permanently-revealed state throughout the pull.
    STCForceVisibleFromStructuredController(self);

    if (translation.y >= STCSpinnerStartDistance && refresh && !refresh.refreshing) {
        [refresh beginRefreshing];
    }

    if (STCClearedThisPan || translation.y < STCTriggerDistance) return;

    STCClearedThisPan = YES;
    BOOL cleared = STCClearNotificationsFromController(self);

    if (refresh.refreshing) [refresh endRefreshing];

    if (cleared) {
        STCPlayClearHaptic();
    }

    // Stop the stock drag at the clear point. Combined with the forced-history hooks below,
    // this prevents iOS from completing the bottom "X Notifications" tuck transition.
    pan.enabled = NO;
    pan.enabled = YES;

    STCForceVisibleFromStructuredController(self);
}

%end

%hook CSCombinedListViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCForceHistoryVisibleOnObject(self);
}

- (void)forceNotificationHistoryRevealed:(BOOL)revealed animated:(BOOL)animated {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(YES, NO);
        return;
    }
    %orig;
}

%end

%hook NCNotificationCombinedListViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCForceHistoryVisibleOnObject(self);
}

- (void)forceNotificationHistoryRevealed:(BOOL)revealed animated:(BOOL)animated {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(YES, NO);
        return;
    }
    %orig;
}

%end

%hook NCNotificationMasterList

// Keep notifications in the incoming/visible list while locked.
- (void)migrateNotifications {
    if (STCShouldOverrideNotificationHistory()) return;
    %orig;
}

- (BOOL)_isNotificationRequestForIncomingSection:(id)request {
    if (STCShouldOverrideNotificationHistory()) return YES;
    return %orig;
}

- (BOOL)_isNotificationRequestForHistorySection:(id)request {
    if (STCShouldOverrideNotificationHistory()) return NO;
    return %orig;
}

- (BOOL)_isNotificationRequest:(id)request forSectionList:(id)sectionList {
    if (STCShouldOverrideNotificationHistory()) {
        SEL sectionTypeSel = NSSelectorFromString(@"sectionType");
        if ([sectionList respondsToSelector:sectionTypeSel]) {
            unsigned long long sectionType = ((unsigned long long (*)(id, SEL))objc_msgSend)(sectionList, sectionTypeSel);
            return sectionType == 2;
        }
        return NO;
    }
    return %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)test
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests {
    if (STCShouldOverrideNotificationHistory()) return;
    %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)test
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests
             filterPersistentRequests:(BOOL)filterPersistentRequests {
    if (STCShouldOverrideNotificationHistory()) return;
    %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)passingTest
            filterRequestsPassingTest:(id)filterRequestsPassingTest
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests
                 filterForDestination:(BOOL)filterForDestination
                       animateRemoval:(BOOL)animateRemoval
           reorderGroupNotifications:(BOOL)reorderGroupNotifications {
    if (STCShouldOverrideNotificationHistory()) return;
    %orig;
}

%end

%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    %orig;
    if (STCShouldOverrideNotificationHistory()) {
        self.hidden = YES;
    }
}

- (void)setRevealPercentage:(double)percentage {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(0.0);
        return;
    }
    %orig;
}

- (void)setForceRevealed:(BOOL)revealed {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)setHintingAlpha:(double)alpha {
    if (STCShouldOverrideNotificationHistory()) {
        %orig(0.0);
        return;
    }
    %orig;
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
