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
static CFTimeInterval STCLastClearTime = 0;
static char STCGestureInstalledKey;
static char STCGestureFiredKey;

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface CSCombinedListViewController : UIViewController
@end

@interface SBDashBoardCombinedListViewController : UIViewController
@end

@interface NCNotificationCombinedListViewController : UIViewController
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

static void STCClearAllNotifications(void) {
    if (!STCEnabled || !STCDeviceIsLocked()) return;

    CFTimeInterval now = CACurrentMediaTime();
    if ((now - STCLastClearTime) < 0.45) return;
    STCLastClearTime = now;

    id controller = STCNotificationListController;
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
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
    if (!STCEnabled) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(gesture, &STCGestureFiredKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if ([objc_getAssociatedObject(gesture, &STCGestureFiredKey) boolValue]) return;

        CGPoint translation = [gesture translationInView:gesture.view];
        if (translation.y >= 42.0 && translation.y > fabs(translation.x) * 1.15) {
            objc_setAssociatedObject(gesture, &STCGestureFiredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            STCClearAllNotifications();
        }
    }

    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(gesture, &STCGestureFiredKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
@end

static void STCInstallGestureOnView(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &STCGestureInstalledKey)) return;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[STCGestureHandler sharedInstance] action:@selector(handlePan:)];
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.delegate = [STCGestureDelegate sharedInstance];

    [view addGestureRecognizer:pan];
    objc_setAssociatedObject(view, &STCGestureInstalledKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

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
%end

%hook CSCombinedListViewController
- (void)viewDidLoad {
    %orig;
    STCInstallGestureOnView(self.view);
}
%end

%hook SBDashBoardCombinedListViewController
- (void)viewDidLoad {
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
