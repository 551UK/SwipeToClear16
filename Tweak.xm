#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const STCPrefsDomain = @"com.551.swipetoclear16";
static NSString * const STCPrefsChanged = @"com.551.swipetoclear16/preferences.changed";
static BOOL STCEnabled = YES;
static __weak id STCNotificationListController = nil;
static __weak id STCNotificationDispatcher = nil;
static CFTimeInterval STCLastClearTime = 0;
static char STCGestureInstalledKey;
static char STCGestureFiredKey;

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface SBNCNotificationDispatcher : NSObject
@property (nonatomic, retain) id dispatcher;
@end

@interface CSCombinedListViewController : UIViewController
@end

@interface SBDashBoardCombinedListViewController : UIViewController
@end

@interface NCNotificationCombinedListViewController : UIViewController
- (id)allNotificationRequests;
- (void)_clearAllNotificationRequests;
- (void)_clearAllPriorityListNotificationRequests;
- (void)forceNotificationHistoryRevealed:(BOOL)revealed animated:(BOOL)animated;
@end

static void STCLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)STCPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)STCPrefsDomain);
    STCEnabled = value ? CFBooleanGetValue((CFBooleanRef)value) : YES;
    if (value) CFRelease(value);
}

static void STCPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    STCLoadPrefs();
}

static BOOL STCDeviceIsLocked(void) {
    Class cls = objc_getClass("SBLockScreenManager");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) return NO;

    id manager = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(sharedInstance));
    if (!manager || ![manager respondsToSelector:@selector(isUILocked)]) return NO;

    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, @selector(isUILocked));
}

static id STCAllNotificationRequests(void) {
    id controller = STCNotificationListController;
    if (!controller) return nil;

    SEL allRequestsSel = NSSelectorFromString(@"allNotificationRequests");
    if ([controller respondsToSelector:allRequestsSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(controller, allRequestsSel);
    }
    return nil;
}

static BOOL STCHasNotifications(void) {
    id requests = STCAllNotificationRequests();
    if ([requests respondsToSelector:@selector(count)]) {
        return [requests count] > 0;
    }
    return STCNotificationListController != nil;
}

static void STCClearAllNotifications(void) {
    if (!STCEnabled || !STCDeviceIsLocked()) return;

    CFTimeInterval now = CACurrentMediaTime();
    if ((now - STCLastClearTime) < 0.35) return;
    STCLastClearTime = now;

    id controller = STCNotificationListController;
    id requests = STCAllNotificationRequests();
    id dispatcher = STCNotificationDispatcher;

    SEL dispatcherClear = NSSelectorFromString(@"destination:requestsClearingNotificationRequests:");
    if (dispatcher && requests && [dispatcher respondsToSelector:dispatcherClear]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(dispatcher, dispatcherClear, nil, requests);
        return;
    }

    if (!controller) return;

    SEL clearAll = NSSelectorFromString(@"_clearAllNotificationRequests");
    if ([controller respondsToSelector:clearAll]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, clearAll);
        return;
    }

    SEL clearPriority = NSSelectorFromString(@"_clearAllPriorityListNotificationRequests");
    if ([controller respondsToSelector:clearPriority]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, clearPriority);
    }
}

@interface STCGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedInstance;
@end

@implementation STCGestureDelegate
+ (instancetype)sharedInstance {
    static STCGestureDelegate *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [STCGestureDelegate new]; });
    return shared;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!STCEnabled || !STCDeviceIsLocked() || !STCHasNotifications()) return NO;
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (velocity.y <= 0.0) return NO;
    if (fabs(velocity.y) <= fabs(velocity.x)) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}
@end

@interface STCGestureHandler : NSObject
+ (instancetype)sharedInstance;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
@end

@implementation STCGestureHandler
+ (instancetype)sharedInstance {
    static STCGestureHandler *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [STCGestureHandler new]; });
    return shared;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!STCEnabled || !STCDeviceIsLocked()) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(gesture, &STCGestureFiredKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if ([objc_getAssociatedObject(gesture, &STCGestureFiredKey) boolValue]) return;

        CGPoint translation = [gesture translationInView:gesture.view];
        if (translation.y >= 30.0 && translation.y > fabs(translation.x)) {
            objc_setAssociatedObject(gesture, &STCGestureFiredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            STCClearAllNotifications();
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(gesture, &STCGestureFiredKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
@end

static void STCMakeNativePansWait(UIView *view, UIPanGestureRecognizer *ourPan) {
    if (!view || !ourPan) return;

    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (gesture != ourPan && [gesture isKindOfClass:[UIPanGestureRecognizer class]]) {
            [(UIPanGestureRecognizer *)gesture requireGestureRecognizerToFail:ourPan];
        }
    }

    for (UIView *subview in view.subviews) {
        STCMakeNativePansWait(subview, ourPan);
    }
}

static void STCInstallGestureOnView(UIView *view) {
    if (!view) return;

    UIPanGestureRecognizer *pan = objc_getAssociatedObject(view, &STCGestureInstalledKey);
    if (!pan) {
        pan = [[UIPanGestureRecognizer alloc] initWithTarget:[STCGestureHandler sharedInstance] action:@selector(handlePan:)];
        pan.minimumNumberOfTouches = 1;
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = YES;
        pan.delaysTouchesBegan = NO;
        pan.delaysTouchesEnded = NO;
        pan.delegate = [STCGestureDelegate sharedInstance];
        [view addGestureRecognizer:pan];
        objc_setAssociatedObject(view, &STCGestureInstalledKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    STCMakeNativePansWait(view, pan);
}

%hook SBNCNotificationDispatcher
- (id)init {
    id result = %orig;
    if ([result respondsToSelector:@selector(dispatcher)]) {
        STCNotificationDispatcher = ((id (*)(id, SEL))objc_msgSend)(result, @selector(dispatcher));
    }
    return result;
}

- (void)setDispatcher:(id)dispatcher {
    %orig;
    STCNotificationDispatcher = dispatcher;
}
%end

%hook NCNotificationCombinedListViewController
- (id)init {
    id result = %orig;
    STCNotificationListController = result;
    return result;
}

- (void)viewDidLoad {
    %orig;
    STCNotificationListController = self;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCNotificationListController = self;
}

- (void)forceNotificationHistoryRevealed:(BOOL)revealed animated:(BOOL)animated {
    if (STCEnabled && STCDeviceIsLocked() && !revealed) {
        %orig(YES, NO);
        return;
    }
    %orig;
}
%end

%hook CSCombinedListViewController
- (void)viewDidLoad {
    %orig;
    STCInstallGestureOnView(self.view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCInstallGestureOnView(self.view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    STCInstallGestureOnView(self.view);
}
%end

%hook SBDashBoardCombinedListViewController
- (void)viewDidLoad {
    %orig;
    STCInstallGestureOnView(self.view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    STCInstallGestureOnView(self.view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    STCInstallGestureOnView(self.view);
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
