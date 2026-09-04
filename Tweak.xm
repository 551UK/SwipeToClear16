#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";
static NSString * const STCInteractiveDisplayStyleReason = @"NCNotificationListDisplayStyleReasonInteractiveTransition";

static BOOL STCEnabled = YES;
static BOOL STCClearedThisPan = NO;
static const CGFloat STCTriggerDistance = 26.0;
static const CGFloat STCSpinnerStartDistance = 5.0;

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

static BOOL STCActiveOnLockScreen(void) {
    return STCEnabled && STCDeviceIsLocked();
}

static BOOL STCIsInteractiveDisplayStyleReason(id reason) {
    return [reason isKindOfClass:[NSString class]] && [(NSString *)reason isEqualToString:STCInteractiveDisplayStyleReason];
}

static void STCPlayClearHaptic(void) {
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback prepare];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

static BOOL STCClearNotificationsFromController(id controller) {
    if (!controller) return NO;

    SEL masterListSel = NSSelectorFromString(@"masterList");
    if (![controller respondsToSelector:masterListSel]) return NO;

    id masterList = ((id (*)(id, SEL))objc_msgSend)(controller, masterListSel);
    if (!masterList) return NO;

    SEL incomingSel = NSSelectorFromString(@"incomingSectionList");
    id incomingList = [masterList respondsToSelector:incomingSel]
        ? ((id (*)(id, SEL))objc_msgSend)(masterList, incomingSel)
        : nil;

    // KeepItSimple 1.2.5's iOS 16 clear path.
    SEL clearAllSel = NSSelectorFromString(@"clearAll");
    if (incomingList && [incomingList respondsToSelector:clearAllSel]) {
        ((void (*)(id, SEL))objc_msgSend)(incomingList, clearAllSel);
        return YES;
    }

    SEL clearRequestsSel = NSSelectorFromString(@"clearAllNotificationRequests");
    if (incomingList && [incomingList respondsToSelector:clearRequestsSel]) {
        ((void (*)(id, SEL))objc_msgSend)(incomingList, clearRequestsSel);
        return YES;
    }

    return NO;
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;

    UIScrollView *listView = nil;
    if ([self respondsToSelector:@selector(masterListView)]) {
        listView = [self masterListView];
    }
    if (!listView) return;

    // Same pull-to-refresh style visual used by KeepItSimple, but our clear
    // threshold stays short.
    UIRefreshControl *refresh = listView.refreshControl;
    if (!refresh) {
        refresh = [[UIRefreshControl alloc] init];
        refresh.tintColor = [UIColor whiteColor];
        refresh.transform = CGAffineTransformMakeScale(0.78, 0.78);
        listView.refreshControl = refresh;
    }

    UIPanGestureRecognizer *pan = listView.panGestureRecognizer;
    if (pan) {
        [pan addTarget:self action:@selector(stc_handleNotificationPan:)];
    }
}

%new
- (void)stc_handleNotificationPan:(UIPanGestureRecognizer *)pan {
    UIScrollView *listView = [pan.view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)pan.view : nil;
    UIRefreshControl *refresh = listView.refreshControl;

    if (!STCActiveOnLockScreen()) {
        STCClearedThisPan = NO;
        if (refresh.refreshing) [refresh endRefreshing];
        return;
    }

    UIGestureRecognizerState state = pan.state;

    if (state == UIGestureRecognizerStateBegan) {
        STCClearedThisPan = NO;
        return;
    }

    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        if (refresh.refreshing) [refresh endRefreshing];
        STCClearedThisPan = NO;
        return;
    }

    if (state != UIGestureRecognizerStateChanged) return;

    CGPoint translation = [pan translationInView:pan.view];
    CGPoint velocity = [pan velocityInView:pan.view];

    BOOL downward = translation.y > 0.0 &&
                    translation.y > fabs(translation.x) &&
                    velocity.y >= -50.0;

    if (!downward) {
        if (refresh.refreshing) [refresh endRefreshing];
        return;
    }

    if (refresh && translation.y >= STCSpinnerStartDistance && !refresh.refreshing) {
        [refresh beginRefreshing];
    }

    if (STCClearedThisPan || translation.y < STCTriggerDistance) return;

    STCClearedThisPan = YES;
    BOOL cleared = STCClearNotificationsFromController(self);

    if (refresh.refreshing) [refresh endRefreshing];

    if (cleared) {
        STCPlayClearHaptic();
    }

    // Stop the current stock pan once our clear has fired.
    pan.enabled = NO;
    pan.enabled = YES;
}

%end

%hook NCNotificationMasterList

// iOS 16 uses this reason specifically when a downward drag temporarily
// changes List/Stack into Count view. Ignore only that interactive override.
- (void)setOverrideNotificationListDisplayStyleSetting:(unsigned long long)setting
                                             forReason:(id)reason
                                 hideNotificationCount:(BOOL)hideNotificationCount {
    if (STCActiveOnLockScreen() && STCIsInteractiveDisplayStyleReason(reason)) {
        return;
    }
    %orig;
}

// Keep notifications in the incoming list while locked, matching the stable
// v1.0.3/KeepItSimple-derived behaviour.
- (void)migrateNotifications {
    if (STCActiveOnLockScreen()) return;
    %orig;
}

- (BOOL)_isNotificationRequestForIncomingSection:(id)request {
    if (STCActiveOnLockScreen()) return YES;
    return %orig;
}

- (BOOL)_isNotificationRequestForHistorySection:(id)request {
    if (STCActiveOnLockScreen()) return NO;
    return %orig;
}

- (BOOL)_isNotificationRequest:(id)request forSectionList:(id)sectionList {
    if (STCActiveOnLockScreen()) {
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
    if (STCActiveOnLockScreen()) return;
    %orig;
}

- (void)_migrateNotificationsFromList:(id)fromList
                               toList:(id)toList
                          passingTest:(id)test
                           hideToList:(BOOL)hideToList
                        clearRequests:(BOOL)clearRequests
             filterPersistentRequests:(BOOL)filterPersistentRequests {
    if (STCActiveOnLockScreen()) return;
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
    if (STCActiveOnLockScreen()) return;
    %orig;
}

%end

%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    if (STCActiveOnLockScreen()) return;
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
