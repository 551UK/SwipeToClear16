#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";

static BOOL STCEnabled = YES;
static BOOL STCDownwardDrag = NO;
static BOOL STCClearedThisDrag = NO;
static CGFloat STCTriggerDistance = 16.0;

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface NCNotificationMasterList : NSObject
- (id)delegate;
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

static unsigned long long STCNotificationCount(id masterList) {
    if (!masterList) return 0;

    SEL notificationCount = NSSelectorFromString(@"notificationCount");
    if ([masterList respondsToSelector:notificationCount]) {
        return ((unsigned long long (*)(id, SEL))objc_msgSend)(masterList, notificationCount);
    }

    SEL totalCount = NSSelectorFromString(@"totalNotificationCount");
    if ([masterList respondsToSelector:totalCount]) {
        return ((unsigned long long (*)(id, SEL))objc_msgSend)(masterList, totalCount);
    }

    SEL count = NSSelectorFromString(@"count");
    if ([masterList respondsToSelector:count]) {
        return ((unsigned long long (*)(id, SEL))objc_msgSend)(masterList, count);
    }

    // Do not block a supported iOS 16 point release just because its count selector differs.
    return 1;
}

static void STCClearMasterList(id masterList) {
    if (!masterList) return;

    // iOS 16's NCNotificationMasterListDelegate inherits the list-base clear-all callback.
    SEL delegateSel = NSSelectorFromString(@"delegate");
    id delegate = [masterList respondsToSelector:delegateSel]
        ? ((id (*)(id, SEL))objc_msgSend)(masterList, delegateSel)
        : nil;

    SEL requestsClearAll = NSSelectorFromString(@"notificationListBaseComponentRequestsClearingAll:");
    if (delegate && [delegate respondsToSelector:requestsClearAll]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, requestsClearAll, masterList);
        return;
    }

    // Fallbacks for neighbouring UserNotificationsUIKit implementations.
    SEL clearAll = NSSelectorFromString(@"clearAll");
    if ([masterList respondsToSelector:clearAll]) {
        ((void (*)(id, SEL))objc_msgSend)(masterList, clearAll);
        return;
    }

    SEL privateClear = NSSelectorFromString(@"_clearAllNotifications:supplementaryViewControllers:");
    if ([masterList respondsToSelector:privateClear]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(masterList, privateClear, YES, YES);
        return;
    }

    SEL oldClear = NSSelectorFromString(@"notificationListComponentRequestsClearingAllNotificationRequests:");
    if ([masterList respondsToSelector:oldClear]) {
        ((void (*)(id, SEL, id))objc_msgSend)(masterList, oldClear, masterList);
    }
}

static BOOL STCIsIntentionalDownwardPan(UIScrollView *scrollView) {
    UIPanGestureRecognizer *pan = scrollView.panGestureRecognizer;
    if (!pan) return NO;

    UIGestureRecognizerState state = pan.state;
    if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return NO;

    CGPoint translation = [pan translationInView:scrollView];
    CGPoint velocity = [pan velocityInView:scrollView];

    BOOL translationDown = translation.y > 0.0 && translation.y > fabs(translation.x);
    BOOL velocityDown = velocity.y > 0.0 && velocity.y > fabs(velocity.x);
    return translationDown || velocityDown;
}

%hook NCNotificationMasterList

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    STCDownwardDrag = NO;
    STCClearedThisDrag = NO;
    %orig;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!STCEnabled || !STCDeviceIsLocked() || STCNotificationCount(self) == 0) {
        %orig;
        return;
    }

    if (STCIsIntentionalDownwardPan(scrollView)) {
        STCDownwardDrag = YES;

        // Do not pass the downward Lock Screen drag into Apple's native list handler.
        // That handler is what collapses the notifications into the bottom count indicator.
        CGPoint translation = [scrollView.panGestureRecognizer translationInView:scrollView];
        if (!STCClearedThisDrag && translation.y >= STCTriggerDistance) {
            STCClearedThisDrag = YES;
            STCClearMasterList(self);
        }
        return;
    }

    %orig;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(CGPoint *)targetContentOffset {
    if (STCEnabled && STCDeviceIsLocked() && STCDownwardDrag) {
        // If the user released extremely quickly, still treat it as swipe-to-clear.
        if (!STCClearedThisDrag && STCNotificationCount(self) > 0) {
            STCClearedThisDrag = YES;
            STCClearMasterList(self);
        }

        // Never let the native end-of-drag path commit the tucked/count state.
        if (targetContentOffset) *targetContentOffset = scrollView.contentOffset;
        return;
    }

    %orig;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    STCDownwardDrag = NO;
    STCClearedThisDrag = NO;
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
