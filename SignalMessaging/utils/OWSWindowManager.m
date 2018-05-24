//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSWindowManager.h"
#import "UIColor+OWS.h"
#import "UIFont+OWS.h"
#import "UIView+OWS.h"
#import <SignalMessaging/SignalMessaging-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const OWSWindowManagerCallDidChangeNotification = @"OWSWindowManagerCallDidChangeNotification";


const CGFloat OWSWindowManagerCallScreenHeight(void)
{
    if ([UIDevice currentDevice].isIPhoneX) {
        // On an iPhoneX, the system return-to-call banner has been replaced by a much subtler green
        // circle behind the system clock. Instead, we mimic the old system call banner as on older devices,
        // but it has to be taller to fit beneath the notch.
        // IOS_DEVICE_CONSTANT, we'll want to revisit this when new device dimensions are introduced.
        return 64;
    } else {

        return CurrentAppContext().statusBarHeight + 20;
    }
}

// Behind everything, especially the root window.
const UIWindowLevel UIWindowLevel_Background = -1.f;

const UIWindowLevel UIWindowLevel_ReturnToCall(void);
const UIWindowLevel UIWindowLevel_ReturnToCall(void)
{
    return UIWindowLevelStatusBar - 1;
}

// In front of the root window, behind the screen blocking window.
const UIWindowLevel UIWindowLevel_CallView(void);
const UIWindowLevel UIWindowLevel_CallView(void)
{
    return UIWindowLevelNormal + 1.f;
}

// In front of everything, including the status bar.
const UIWindowLevel UIWindowLevel_ScreenBlocking(void);
const UIWindowLevel UIWindowLevel_ScreenBlocking(void)
{
    return UIWindowLevelStatusBar + 2.f;
}

@implementation OWSWindowRootViewController

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

@end

#pragma mark -

@interface OWSWindowManager () <ReturnToCallViewControllerDelegate>

// UIWindowLevelNormal
@property (nonatomic) UIWindow *rootWindow;

// UIWindowLevel_ReturnToCall
@property (nonatomic) UIWindow *returnToCallWindow;
@property (nonatomic) ReturnToCallViewController *returnToCallViewController;

// UIWindowLevel_CallView
@property (nonatomic) UIWindow *callViewWindow;
@property (nonatomic) UINavigationController *callNavigationController;

// UIWindowLevel_Background if inactive,
// UIWindowLevel_ScreenBlocking() if active.
@property (nonatomic) UIWindow *screenBlockingWindow;

@property (nonatomic) BOOL isScreenBlockActive;

@property (nonatomic) BOOL shouldShowCallView;

@property (nonatomic, nullable) UIViewController *callViewController;

@end

#pragma mark -

@implementation OWSWindowManager

+ (instancetype)sharedManager
{
    static OWSWindowManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initDefault];
    });
    return instance;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssertIsOnMainThread();
    OWSSingletonAssert();

    return self;
}

- (void)setupWithRootWindow:(UIWindow *)rootWindow screenBlockingWindow:(UIWindow *)screenBlockingWindow
{
    OWSAssertIsOnMainThread();
    OWSAssert(rootWindow);
    OWSAssert(!self.rootWindow);
    OWSAssert(screenBlockingWindow);
    OWSAssert(!self.screenBlockingWindow);

    self.rootWindow = rootWindow;
    self.screenBlockingWindow = screenBlockingWindow;

    self.returnToCallWindow = [self createReturnToCallWindow:rootWindow];
    self.callViewWindow = [self createCallViewWindow:rootWindow];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didChangeStatusBarFrame:)
                                                 name:UIApplicationDidChangeStatusBarFrameNotification
                                               object:nil];

    [self ensureWindowState];
}

- (void)didChangeStatusBarFrame:(NSNotification *)notification
{
    CGRect newFrame = self.returnToCallWindow.frame;
    newFrame.size.height = OWSWindowManagerCallScreenHeight();

    DDLogDebug(@"%@ StatusBar changed frames - updating returnToCallWindowFrame: %@",
        self.logTag,
        NSStringFromCGRect(newFrame));
    self.returnToCallWindow.frame = newFrame;
}

- (UIWindow *)createReturnToCallWindow:(UIWindow *)rootWindow
{
    OWSAssertIsOnMainThread();
    OWSAssert(rootWindow);

    // "Return to call" should remain at the top of the screen.
    CGRect windowFrame = UIScreen.mainScreen.bounds;
    windowFrame.size.height = OWSWindowManagerCallScreenHeight();
    UIWindow *window = [[UIWindow alloc] initWithFrame:windowFrame];
    window.hidden = YES;
    window.windowLevel = UIWindowLevel_ReturnToCall();
    window.opaque = YES;

    ReturnToCallViewController *viewController = [ReturnToCallViewController new];
    self.returnToCallViewController = viewController;
    viewController.delegate = self;

    window.rootViewController = viewController;

    return window;
}

- (UIWindow *)createCallViewWindow:(UIWindow *)rootWindow
{
    OWSAssertIsOnMainThread();
    OWSAssert(rootWindow);

    UIWindow *window = [[UIWindow alloc] initWithFrame:rootWindow.bounds];
    window.hidden = YES;
    window.windowLevel = UIWindowLevel_CallView();
    window.opaque = YES;
    // TODO: What's the right color to use here?
    window.backgroundColor = [UIColor ows_materialBlueColor];

    UIViewController *viewController = [OWSWindowRootViewController new];
    viewController.view.backgroundColor = [UIColor ows_materialBlueColor];

    // NOTE: Do not use OWSNavigationController for call window.
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:viewController];
    navigationController.navigationBarHidden = YES;
    OWSAssert(!self.callNavigationController);
    self.callNavigationController = navigationController;

    window.rootViewController = navigationController;

    return window;
}

- (void)setIsScreenBlockActive:(BOOL)isScreenBlockActive
{
    OWSAssertIsOnMainThread();

    _isScreenBlockActive = isScreenBlockActive;

    [self ensureWindowState];
}

#pragma mark - Calls

- (void)setCallViewController:(nullable UIViewController *)callViewController
{
    OWSAssertIsOnMainThread();

    if (callViewController == _callViewController) {
        return;
    }

    _callViewController = callViewController;

    [NSNotificationCenter.defaultCenter postNotificationName:OWSWindowManagerCallDidChangeNotification object:nil];
}

- (void)startCall:(UIViewController *)callViewController
{
    OWSAssertIsOnMainThread();
    OWSAssert(callViewController);
    OWSAssert(!self.callViewController);

    self.callViewController = callViewController;

    // Attach callViewController to window.
    [self.callNavigationController popToRootViewControllerAnimated:NO];
    [self.callNavigationController pushViewController:callViewController animated:NO];
    self.shouldShowCallView = YES;

    [self ensureWindowState];
}

- (void)endCall:(UIViewController *)callViewController
{
    OWSAssertIsOnMainThread();
    OWSAssert(callViewController);
    OWSAssert(self.callViewController);

    if (self.callViewController != callViewController) {
        DDLogWarn(@"%@ Ignoring end call request from obsolete call view controller.", self.logTag);
        return;
    }

    // Dettach callViewController from window.
    [self.callNavigationController popToRootViewControllerAnimated:NO];
    self.callViewController = nil;

    self.shouldShowCallView = NO;

    [self ensureWindowState];
}

- (void)leaveCallView
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.callViewController);
    OWSAssert(self.shouldShowCallView);

    self.shouldShowCallView = NO;

    [self ensureWindowState];
}

- (void)showCallView
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.callViewController);
    OWSAssert(!self.shouldShowCallView);

    self.shouldShowCallView = YES;

    [self ensureWindowState];
}

- (BOOL)hasCall
{
    OWSAssertIsOnMainThread();

    return self.callViewController != nil;
}

#pragma mark - Window State

- (void)ensureWindowState
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.rootWindow);
    OWSAssert(self.returnToCallWindow);
    OWSAssert(self.callViewWindow);
    OWSAssert(self.screenBlockingWindow);

    // To avoid bad frames, we never want to hide the blocking window, so we manipulate
    // its window level to "hide" it behind other windows.  The other windows have fixed
    // window level and are shown/hidden as necessary.
    //
    // Note that we always "hide" before we "show".
    if (self.isScreenBlockActive) {
        // Show Screen Block.

        [self ensureRootWindowHidden];
        [self ensureReturnToCallWindowHidden];
        [self ensureCallViewWindowHidden];
        [self ensureScreenBlockWindowShown];
    } else if (self.callViewController && self.shouldShowCallView) {
        // Show Call View.

        [self ensureRootWindowHidden];
        [self ensureReturnToCallWindowHidden];
        [self ensureCallViewWindowShown];
        [self ensureScreenBlockWindowHidden];
    } else if (self.callViewController) {
        // Show Root Window + "Return to Call".

        [self ensureRootWindowShown];
        [self ensureReturnToCallWindowShown];
        [self ensureCallViewWindowHidden];
        [self ensureScreenBlockWindowHidden];
    } else {
        // Show Root Window

        [self ensureRootWindowShown];
        [self ensureReturnToCallWindowHidden];
        [self ensureCallViewWindowHidden];
        [self ensureScreenBlockWindowHidden];
    }
}

- (void)ensureRootWindowShown
{
    OWSAssertIsOnMainThread();

    if (self.rootWindow.hidden) {
        DDLogInfo(@"%@ showing root window.", self.logTag);
    }

    // By calling makeKeyAndVisible we ensure the rootViewController becomes firt responder.
    // In the normal case, that means the SignalViewController will call `becomeFirstResponder`
    // on the vc on top of its navigation stack.
    [self.rootWindow makeKeyAndVisible];
}

- (void)ensureRootWindowHidden
{
    OWSAssertIsOnMainThread();

    if (!self.rootWindow.hidden) {
        DDLogInfo(@"%@ hiding root window.", self.logTag);
    }

    self.rootWindow.hidden = YES;
}

- (void)ensureReturnToCallWindowShown
{
    OWSAssertIsOnMainThread();

    if (!self.returnToCallWindow.hidden) {
        return;
    }

    DDLogInfo(@"%@ showing 'return to call' window.", self.logTag);
    self.returnToCallWindow.hidden = NO;
    [self.returnToCallViewController startAnimating];
}

- (void)ensureReturnToCallWindowHidden
{
    OWSAssertIsOnMainThread();

    if (self.returnToCallWindow.hidden) {
        return;
    }

    DDLogInfo(@"%@ hiding 'return to call' window.", self.logTag);
    self.returnToCallWindow.hidden = YES;
    [self.returnToCallViewController stopAnimating];
}

- (void)ensureCallViewWindowShown
{
    OWSAssertIsOnMainThread();

    if (self.callViewWindow.hidden) {
        DDLogInfo(@"%@ showing call window.", self.logTag);
    }

    [self.callViewWindow makeKeyAndVisible];
}

- (void)ensureCallViewWindowHidden
{
    OWSAssertIsOnMainThread();

    if (!self.callViewWindow.hidden) {
        DDLogInfo(@"%@ hiding call window.", self.logTag);
    }

    self.callViewWindow.hidden = YES;
}

- (void)ensureScreenBlockWindowShown
{
    OWSAssertIsOnMainThread();

    if (self.screenBlockingWindow.windowLevel != UIWindowLevel_ScreenBlocking()) {
        DDLogInfo(@"%@ showing block window.", self.logTag);
    }

    self.screenBlockingWindow.windowLevel = UIWindowLevel_ScreenBlocking();
    [self.screenBlockingWindow makeKeyAndVisible];
}

- (void)ensureScreenBlockWindowHidden
{
    OWSAssertIsOnMainThread();

    if (self.screenBlockingWindow.windowLevel != UIWindowLevel_Background) {
        DDLogInfo(@"%@ hiding block window.", self.logTag);
    }

    // Never hide the blocking window (that can lead to bad frames).
    // Instead, manipulate its window level to move it in front of
    // or behind the root window.
    self.screenBlockingWindow.windowLevel = UIWindowLevel_Background;
}

#pragma mark - ReturnToCallViewControllerDelegate

- (void)returnToCallWasTapped:(ReturnToCallViewController *)viewController
{
    [self showCallView];
}

@end

NS_ASSUME_NONNULL_END
