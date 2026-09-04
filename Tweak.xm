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

static void STCClearNotificationsFromController(id controller) {
    if (!controller) return;

    SEL masterListSel = NSSelectorFromString(@"masterList");
    if (![controller respondsToSelector:masterListSel]) return;

    id masterList = ((id (*)(id, SEL))objc_msgSend)(controller, masterListSel);
    if (!masterList) return;

    SEL incomingSel = NSSelectorFromString(@"incomingSectionList");
    id incomingList = [masterList respondsToSelector:incomingSel]
        ? ((id (*)(id, SEL))objc_msgSend)(masterList, incomingSel)
        : nil;

    // This is the exact iOS 16 path used by KeepItSimple 1.2.5.
    SEL clearAllSel = NSSelectorFromString(@"clearAll");
    if (incomingList && [incomingList respondsToSelector:clearAllSel]) {
        ((void (*)(id, SEL))objc_msgSend)(incomingList, clearAllSel);
        return;
    }

    // Fallback retained for neighbouring UserNotificationsUIKit builds.
    SEL clearRequestsSel = NSSelectorFromString(@"clearAllNotificationRequests");
    if (incomingList && [incomingList respondsToSelector:clearRequestsSel]) {
        ((void (*)(id, SEL))objc_msgSend)(incomingList, clearRequestsSel);
    }
}

%hook NCNotificationStructuredListViewController

- (void)viewDidLoad {
    %orig;

    UIScrollView *listView = nil;
    if ([self respondsToSelector:@selector(masterListView)]) {
        listView = [self masterListView];
    }

    UIPanGestureRecognizer *pan = listView.panGestureRecognizer;
    if (pan) {
        [pan addTarget:self action:@selector(stc_handleNotificationPan:)];
    }
}

%new
- (void)stc_handleNotificationPan:(UIPanGestureRecognizer *)pan {
    if (!STCShouldOverrideNotificationHistory()) {
        STCClearedThisPan = NO;
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
        STCClearedThisPan = NO;
        return;
    }

    if (state != UIGestureRecognizerStateChanged || STCClearedThisPan) return;

    UIView *view = pan.view;
    CGPoint translation = [pan translationInView:view];
    CGPoint velocity = [pan velocityInView:view];

    BOOL downward = translation.y > 0.0 &&
                    translation.y > fabs(translation.x) &&
                    velocity.y >= -50.0;

    if (!downward || translation.y < STCTriggerDistance) return;

    STCClearedThisPan = YES;
    STCClearNotificationsFromController(self);

    // End Apple's list pan immediately so it cannot finish the native tuck/count transition.
    pan.enabled = NO;
    pan.enabled = YES;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
}

%end

%hook NCNotificationMasterList

// KeepItSimple makes the incoming list the single active notification list.
// Doing the same only while the device is locked removes iOS 16's tuck/history move.
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
    if (STCShouldOverrideNotificationHistory()) return;
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
