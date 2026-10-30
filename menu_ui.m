#import "vcam_menu.h"
#import "vcam_shared.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>

@interface VCamMenuViewController : UIViewController <PHPickerViewControllerDelegate>
- (void)setMenuVisible:(BOOL)visible;
@end

@interface VCamPassThroughView : UIView
@property (nonatomic, weak) UIView *floatingControl;
@property (nonatomic, weak) UIView *floatingPanel;
@property (nonatomic) BOOL menuVisible;
- (UIView *)interactiveSubviewAtPoint:(CGPoint)point;
@end

@implementation VCamPassThroughView
- (UIView *)interactiveSubviewAtPoint:(CGPoint)point {
    if (self.floatingControl && !self.floatingControl.hidden) {
        CGPoint controlPoint = [self.floatingControl convertPoint:point fromView:self];
        if (CGRectContainsPoint(self.floatingControl.bounds, controlPoint)) return self.floatingControl;
    }

    if (self.floatingPanel && !self.floatingPanel.hidden) {
        CGPoint panelPoint = [self.floatingPanel convertPoint:point fromView:self];
        UIView *candidate = [self.floatingPanel hitTest:panelPoint withEvent:nil];
        for (UIView *view = candidate; view && view != self.floatingPanel; view = view.superview) {
            if ([view isKindOfClass:UIControl.class]) return view;
        }
    }
    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (self.menuVisible) return YES;
    return [self interactiveSubviewAtPoint:point] != nil;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.menuVisible) return [super hitTest:point withEvent:event];
    return [self interactiveSubviewAtPoint:point];
}
@end

@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    VCamPassThroughView *rootView = (VCamPassThroughView *)self.rootViewController.view;
    if (rootView && !rootView.menuVisible) {
        CGPoint rootPoint = [rootView convertPoint:point fromView:self];
        return [rootView hitTest:rootPoint withEvent:event];
    }
    return [super hitTest:point withEvent:event];
}
@end

static VCamOverlayWindow *sOverlayWindow = nil;
static BOOL sMenuVisible = NO;
static const CGFloat VCamMoveStep = 0.05;
static NSString * const VCamMovieTypeIdentifier = @"public.movie";
static NSString * const VCamImageTypeIdentifier = @"public.image";

static UIButton *VCamMakeButton(NSString *title, UIColor *background, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = background;
    button.layer.cornerRadius = 11.0;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(9, 10, 9, 10);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    return button;
}

static UIButton *VCamMakeIconButton(NSString *symbolName, NSString *accessibilityLabel, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *image = [UIImage systemImageNamed:symbolName];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    button.layer.cornerRadius = 9.0;
    button.layer.masksToBounds = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:34.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:34.0].active = YES;
    button.accessibilityLabel = accessibilityLabel;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UILabel *VCamMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@implementation VCamMenuViewController {
    UILabel *_statusLabel;
    UILabel *_diagnosticLabel;
    UIButton *_toggleButton;
    UIButton *_controlVisibilityButton;
    UIButton *_videoButton;
    UIButton *_logsButton;
    UIButton *_backdrop;
    UIView *_panel;
    UIStackView *_logsContainer;
    VCamPassThroughView *_passThroughView;
    UIButton *_floatingControl;
    UIView *_floatingPanel;
    CGPoint _floatingStartCenter;
    NSTimer *_diagnosticTimer;
}

- (void)loadView {
    _passThroughView = [[VCamPassThroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _passThroughView.backgroundColor = UIColor.clearColor;
    self.view = _passThroughView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    _backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    [_backdrop addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    _backdrop.hidden = YES;
    [self.view addSubview:_backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [_backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = 22;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 1;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _panel = blur;
    _panel.hidden = YES;
    [self.view addSubview:blur];
    CGFloat panelWidth = MIN(UIScreen.mainScreen.bounds.size.width - 32.0, 350.0);
    CGFloat panelHeight = MIN(UIScreen.mainScreen.bounds.size.height - 72.0, 470.0);
    [NSLayoutConstraint activateConstraints:@[
        [blur.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [blur.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [blur.widthAnchor constraintEqualToConstant:panelWidth],
        [blur.heightAnchor constraintEqualToConstant:panelHeight]
    ]];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [blur.contentView addSubview:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    UILabel *title = VCamMakeLabel(@"VCam", [UIFont systemFontOfSize:22 weight:UIFontWeightBold], UIColor.whiteColor);
    [header addArrangedSubview:title];
    [header addArrangedSubview:[[UIView alloc] init]];
    UIButton *close = VCamMakeButton(@"✕", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(closeMenu));
    [close.widthAnchor constraintEqualToConstant:42].active = YES;
    [header addArrangedSubview:close];
    [stack addArrangedSubview:header];

    _statusLabel = VCamMakeLabel(@"No replacement media selected", [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:0.72]);
    [stack addArrangedSubview:_statusLabel];

    UIButton *chooseButton = VCamMakeButton(@"Choose Photo / Video", [UIColor colorWithRed:0.20 green:0.42 blue:0.86 alpha:1], self, @selector(chooseMedia));
    [stack addArrangedSubview:chooseButton];

    _toggleButton = VCamMakeButton(@"Enable Replacement", [UIColor colorWithRed:0.13 green:0.52 blue:0.32 alpha:1], self, @selector(toggleReplacement));
    [stack addArrangedSubview:_toggleButton];

    _controlVisibilityButton = VCamMakeButton(@"Hide Control", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleFloatingControlVisibility));
    [stack addArrangedSubview:_controlVisibilityButton];

    _logsButton = VCamMakeButton(@"View Logs", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleLogs));
    [stack addArrangedSubview:_logsButton];

    UIStackView *logsStack = [[UIStackView alloc] init];
    logsStack.axis = UILayoutConstraintAxisVertical;
    logsStack.spacing = 8;
    logsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _logsContainer = logsStack;
    _logsContainer.hidden = YES;
    [stack addArrangedSubview:_logsContainer];

    _diagnosticLabel = VCamMakeLabel(@"Checking camera service…", [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular], [UIColor colorWithWhite:1 alpha:0.84]);
    _diagnosticLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
    _diagnosticLabel.layer.cornerRadius = 10;
    _diagnosticLabel.layer.masksToBounds = YES;
    _diagnosticLabel.text = @"Checking camera service…";
    [_logsContainer addArrangedSubview:_diagnosticLabel];

    UIButton *copyDiagnostics = VCamMakeButton(@"Copy Logs", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(copyDiagnostics));
    [_logsContainer addArrangedSubview:copyDiagnostics];

    UILabel *footer = VCamMakeLabel(@"Press Volume Up + Volume Down together to open or close VCam.",
                                    [UIFont systemFontOfSize:12], [UIColor colorWithWhite:1 alpha:0.60]);
    [stack addArrangedSubview:footer];

    [self setupFloatingControl];
    [self refreshStatus];
    [self setMenuVisible:NO];
}

- (UIStackView *)horizontalRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 7;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

- (UIView *)spacer {
    UIView *view = [[UIView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}

- (void)setupFloatingControl {
    _floatingControl = [UIButton buttonWithType:UIButtonTypeSystem];
    [_floatingControl setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    _floatingControl.tintColor = UIColor.whiteColor;
    _floatingControl.accessibilityLabel = @"Open camera controls";
    _floatingControl.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    _floatingControl.layer.cornerRadius = 19.0;
    _floatingControl.layer.borderWidth = 1;
    _floatingControl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    _floatingControl.layer.shadowColor = UIColor.blackColor.CGColor;
    _floatingControl.layer.shadowOpacity = 0.28;
    _floatingControl.layer.shadowRadius = 7;
    _floatingControl.layer.shadowOffset = CGSizeMake(0, 2);
    _floatingControl.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 52.0,
                                        UIScreen.mainScreen.bounds.size.height * 0.68,
                                        38.0, 38.0);
    [_floatingControl addTarget:self action:@selector(toggleFloatingPanel) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *openMenuPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(openMainMenuFromControl:)];
    openMenuPress.minimumPressDuration = 0.65;
    openMenuPress.cancelsTouchesInView = YES;
    [_floatingControl addGestureRecognizer:openMenuPress];
    [self.view addSubview:_floatingControl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloatingControl:)];
    pan.cancelsTouchesInView = NO;
    [_floatingControl addGestureRecognizer:pan];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    panel.frame = CGRectMake(0, 0, 132, 168);
    panel.layer.cornerRadius = 15;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    panel.hidden = YES;
    _floatingPanel = panel;
    [self.view addSubview:panel];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-8]
    ]];

    UIStackView *row1 = [self horizontalRow];
    [row1 addArrangedSubview:VCamMakeIconButton(@"arrow.up", @"Move up", self, @selector(moveUp))];
    [row1 addArrangedSubview:VCamMakeIconButton(@"rotate.left", @"Rotate left", self, @selector(rotateLeft))];
    [row1 addArrangedSubview:VCamMakeIconButton(@"rotate.right", @"Rotate right", self, @selector(rotateRight))];

    UIStackView *row2 = [self horizontalRow];
    [row2 addArrangedSubview:VCamMakeIconButton(@"arrow.left", @"Move left", self, @selector(moveLeft))];
    [row2 addArrangedSubview:VCamMakeIconButton(@"scope", @"Reset position", self, @selector(resetPosition))];
    [row2 addArrangedSubview:VCamMakeIconButton(@"arrow.right", @"Move right", self, @selector(moveRight))];

    UIStackView *row3 = [self horizontalRow];
    [row3 addArrangedSubview:VCamMakeIconButton(@"arrow.down", @"Move down", self, @selector(moveDown))];
    [row3 addArrangedSubview:VCamMakeIconButton(@"minus.magnifyingglass", @"Zoom out", self, @selector(zoomOut))];
    [row3 addArrangedSubview:VCamMakeIconButton(@"plus.magnifyingglass", @"Zoom in", self, @selector(zoomIn))];

    UIStackView *row4 = [self horizontalRow];
    _videoButton = VCamMakeIconButton(@"pause.fill", @"Pause video", self, @selector(toggleVideoPlayback));
    [row4 addArrangedSubview:_videoButton];
    [row4 addArrangedSubview:VCamMakeIconButton(@"eye.slash", @"Hide floating control", self, @selector(hideFloatingControl))];
    [row4 addArrangedSubview:VCamMakeIconButton(@"xmark", @"Close controls", self, @selector(toggleFloatingPanel))];

    [stack addArrangedSubview:row1];
    [stack addArrangedSubview:row2];
    [stack addArrangedSubview:row3];
    [stack addArrangedSubview:row4];

    _passThroughView.floatingControl = _floatingControl;
    _passThroughView.floatingPanel = _floatingPanel;
    [self updateControlVisibilityButton];
    [self updateVideoButton];
    [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutFloatingPanel];
}

- (void)layoutFloatingPanel {
    if (!_floatingPanel || !_floatingControl) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGRect buttonFrame = _floatingControl.frame;
    CGFloat panelWidth = CGRectGetWidth(_floatingPanel.bounds);
    CGFloat panelHeight = CGRectGetHeight(_floatingPanel.bounds);
    CGFloat x = CGRectGetMidX(buttonFrame) > width * 0.5 ? 12.0 : width - panelWidth - 12.0;
    CGFloat y = CGRectGetMinY(buttonFrame) > height * 0.55
        ? CGRectGetMinY(buttonFrame) - panelHeight - 10.0
        : CGRectGetMaxY(buttonFrame) + 10.0;
    x = MAX(8.0, MIN(width - panelWidth - 8.0, x));
    y = MAX(8.0, MIN(height - panelHeight - 8.0, y));
    _floatingPanel.frame = CGRectMake(x, y, panelWidth, panelHeight);
}

- (void)openMainMenuFromControl:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [VCamMenuPresenter showMenu];
    }
}

- (void)toggleFloatingPanel {
    _floatingPanel.hidden = !_floatingPanel.hidden;
    [self layoutFloatingPanel];
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
}

- (void)updateControlVisibilityButton {
    BOOL hidden = _floatingControl.hidden;
    [_controlVisibilityButton setTitle:(hidden ? @"Show Control" : @"Hide Control") forState:UIControlStateNormal];
}

- (void)toggleFloatingControlVisibility {
    if (!_floatingControl) return;
    _floatingControl.hidden = !_floatingControl.hidden;
    _floatingPanel.hidden = YES;
    [self updateControlVisibilityButton];
}

- (void)hideFloatingControl {
    _floatingControl.hidden = YES;
    _floatingPanel.hidden = YES;
    [self updateControlVisibilityButton];
}

- (void)updateVideoButton {
    if (!_videoButton) return;
    NSString *mediaType = VCamCopySetting(VCamMediaTypeKey);
    BOOL isVideo = [mediaType isKindOfClass:NSString.class] && [mediaType isEqualToString:@"video"];
    BOOL paused = [VCamCopySetting(VCamVideoPausedKey) boolValue];
    NSString *symbol = paused ? @"play.fill" : @"pause.fill";
    [_videoButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    _videoButton.enabled = isVideo;
    _videoButton.alpha = isVideo ? 1.0 : 0.35;
    _videoButton.accessibilityLabel = paused ? @"Resume video" : @"Pause video";
}

- (void)toggleVideoPlayback {
    NSString *mediaType = VCamCopySetting(VCamMediaTypeKey);
    if (![mediaType isKindOfClass:NSString.class] || ![mediaType isEqualToString:@"video"]) return;
    BOOL paused = [VCamCopySetting(VCamVideoPausedKey) boolValue];
    VCamSetSetting(VCamVideoPausedKey, @(!paused));
    [self updateVideoButton];
}

- (void)dragFloatingControl:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _floatingStartCenter = _floatingControl.center;
        [self.view bringSubviewToFront:_floatingControl];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.view];
        CGPoint center = CGPointMake(_floatingStartCenter.x + translation.x, _floatingStartCenter.y + translation.y);
        CGFloat halfWidth = CGRectGetWidth(_floatingControl.bounds) * 0.5;
        CGFloat halfHeight = CGRectGetHeight(_floatingControl.bounds) * 0.5;
        center.x = MAX(halfWidth + 6.0, MIN(CGRectGetWidth(self.view.bounds) - halfWidth - 6.0, center.x));
        center.y = MAX(halfHeight + 8.0, MIN(CGRectGetHeight(self.view.bounds) - halfHeight - 8.0, center.y));
        _floatingControl.center = center;
        [self layoutFloatingPanel];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setMenuVisible:YES];
}

- (void)dealloc {
    [_diagnosticTimer invalidate];
}

- (NSString *)diagnosticText {
    NSDictionary *combined = VCamCopyRuntimeStatus();
    NSDictionary *daemonStatuses = [combined[@"daemonStatuses"] isKindOfClass:[NSDictionary class]] ? combined[@"daemonStatuses"] : @{};
    NSDictionary *mediaDaemon = [daemonStatuses[@"mediaserverd"] isKindOfClass:[NSDictionary class]] ? daemonStatuses[@"mediaserverd"] : @{};
    BOOL mediaLoaded = [mediaDaemon[@"runtimeVersion"] isEqualToString:VCamRuntimeVersion] && [mediaDaemon[@"daemonLoaded"] boolValue];
    NSDictionary *runtime = mediaDaemon.count ? mediaDaemon : combined;

    NSString *processName = [runtime[@"daemonProcess"] isKindOfClass:[NSString class]] ? runtime[@"daemonProcess"] : @"mediaserverd";
    NSString *hookState = [runtime[@"hookState"] isKindOfClass:[NSString class]] ? runtime[@"hookState"] : @"unknown";
    BOOL framesSeen = [runtime[@"cameraFramesSeen"] boolValue];
    BOOL rendered = [runtime[@"replacementRendered"] boolValue];
    NSString *mediaState = [runtime[@"mediaState"] isKindOfClass:[NSString class]] ? runtime[@"mediaState"] : @"not-checked";
    NSString *mediaDetail = [runtime[@"mediaDetail"] isKindOfClass:[NSString class]] ? runtime[@"mediaDetail"] : @"";
    NSString *hookDetail = [runtime[@"hookDetail"] isKindOfClass:[NSString class]] ? runtime[@"hookDetail"] : @"";
    NSString *renderError = [runtime[@"renderError"] isKindOfClass:[NSString class]] ? runtime[@"renderError"] : @"";
    NSInteger heartbeatAge = [runtime[@"heartbeatAgeSeconds"] respondsToSelector:@selector(integerValue)] ? [runtime[@"heartbeatAgeSeconds"] integerValue] : -1;

    NSString *daemonLine = mediaLoaded ? [NSString stringWithFormat:@"Camera daemon injection: YES (%@)", processName] : @"Camera daemon injection: NO HEARTBEAT from mediaserverd";
    NSString *heartbeatLine = heartbeatAge >= 0 ? [NSString stringWithFormat:@"mediaserverd heartbeat: %@ (%lds ago)", mediaLoaded ? @"ALIVE" : @"STALE", (long)heartbeatAge] : @"mediaserverd heartbeat: NOT RECEIVED";
    NSString *frameLine = framesSeen ? [NSString stringWithFormat:@"Camera frames: RECEIVED (%@)", runtime[@"cameraFrameSize"] ?: @"size unknown"] : @"Camera frames: WAITING (open Camera and start preview)";
    NSString *mediaLine = [NSString stringWithFormat:@"Media: %@%@", mediaState.uppercaseString, mediaDetail.length ? [@" — " stringByAppendingString:mediaDetail] : @""];
    NSString *enabledLine = [runtime[@"replacementEnabled"] respondsToSelector:@selector(boolValue)]
        ? [NSString stringWithFormat:@"Replacement state (mediaserverd): %@", [runtime[@"replacementEnabled"] boolValue] ? @"ON" : @"OFF"]
        : @"Replacement state (mediaserverd): WAITING";
    NSString *outputLine = rendered ? [NSString stringWithFormat:@"Buffer render call: SENT (%@)", runtime[@"renderedFrameSize"] ?: @"size unknown"] : @"Buffer render call: NOT SENT YET";
    BOOL selectionReceived = [runtime[@"mediaSelectionReceived"] boolValue];
    NSString *selectionName = [runtime[@"mediaSelectionFilename"] isKindOfClass:NSString.class] ? runtime[@"mediaSelectionFilename"] : @"";
    NSString *selectionLine = selectionReceived
        ? [NSString stringWithFormat:@"Media selection (daemon): RECEIVED (%@)", selectionName.length ? selectionName : @"filename unavailable"]
        : @"Media selection (daemon): NOT RECEIVED";

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        daemonLine,
        heartbeatLine,
        [NSString stringWithFormat:@"BWNodeOutput hook: %@", hookState.uppercaseString],
        frameLine,
        enabledLine,
        selectionLine,
        mediaLine,
        outputLine,
        @"Camera coverage: front and rear live preview streams"
    ]];
    if (hookDetail.length) [lines addObject:[@"Hook detail: " stringByAppendingString:hookDetail]];
    if (renderError.length) [lines addObject:[@"Render error: " stringByAppendingString:renderError]];

    if (!mediaLoaded) {
        [lines addObject:@"Action: enable Tweak Injection in Relaxin and run a Userspace Reboot."];
    } else if (![hookState isEqualToString:@"installed"]) {
        [lines addObject:@"Action: the camera hook is not installed. Check Hook detail."];
    } else if (!framesSeen) {
        [lines addObject:@"Action: open the built-in Camera app and start a live preview."];
    } else if ([mediaState isEqualToString:@"disabled"]) {
        [lines addObject:@"Action: enable Replacement."];
    } else if ([mediaState isEqualToString:@"no-selection"]) {
        [lines addObject:@"Action: choose a photo or video."];
    } else if ([mediaState containsString:@"failed"] || [mediaState containsString:@"not-readable"] || [mediaState containsString:@"not-found"] || [mediaState containsString:@"missing"]) {
        [lines addObject:@"Action: choose the media again. Check that the shared media file is readable."];
    } else if (!rendered) {
        [lines addObject:@"Action: wait for the camera frame to be replaced, then check Media above."];
    } else {
        [lines addObject:@"Status: replacement frames are being submitted to the live camera stream."];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)refreshStatusTimer:(NSTimer *)timer {
    (void)timer;
    [self refreshStatus];
}

- (void)refreshStatus {
    NSString *path = VCamCopySetting(VCamMediaPathKey);
    BOOL enabled = [VCamCopySetting(VCamEnabledKey) boolValue];
    if ([path isKindOfClass:[NSString class]] && path.length > 0) {
        _statusLabel.text = [NSString stringWithFormat:@"Selected: %@ · %@", path.lastPathComponent, enabled ? @"Enabled" : @"Disabled"];
    } else {
        _statusLabel.text = @"No replacement media selected";
    }
    [_toggleButton setTitle:(enabled ? @"Disable Replacement" : @"Enable Replacement") forState:UIControlStateNormal];
    _toggleButton.backgroundColor = enabled ? [UIColor colorWithRed:0.66 green:0.25 blue:0.22 alpha:1]
                                            : [UIColor colorWithRed:0.13 green:0.52 blue:0.32 alpha:1];
    _diagnosticLabel.text = [self diagnosticText];
    [self updateControlVisibilityButton];
    [self updateVideoButton];
}

- (void)toggleLogs {
    _logsContainer.hidden = !_logsContainer.hidden;
    [_logsButton setTitle:(_logsContainer.hidden ? @"View Logs" : @"Hide Logs") forState:UIControlStateNormal];
    if (!_logsContainer.hidden) _diagnosticLabel.text = [self diagnosticText];
}

- (void)copyDiagnostics {
    UIPasteboard.generalPasteboard.string = [self diagnosticText];
    _logsContainer.hidden = NO;
    [_logsButton setTitle:@"Hide Logs" forState:UIControlStateNormal];
    _diagnosticLabel.text = [[self diagnosticText] stringByAppendingString:@"\n\nCopied to clipboard."];
}

- (void)setMenuVisible:(BOOL)visible {
    if (!self.isViewLoaded) return;
    sMenuVisible = visible;
    _passThroughView.menuVisible = visible;
    _backdrop.hidden = !visible;
    _panel.hidden = !visible;
    if (visible) {
        [self refreshStatus];
        if (!_diagnosticTimer) {
            _diagnosticTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                               target:self
                                                             selector:@selector(refreshStatusTimer:)
                                                             userInfo:nil
                                                              repeats:YES];
        }
    } else {
        [_diagnosticTimer invalidate];
        _diagnosticTimer = nil;
    }
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    if (!_floatingControl.hidden) [self.view bringSubviewToFront:_floatingControl];
}

- (void)closeMenu {
    [VCamMenuPresenter hideMenu];
}

- (void)chooseMedia {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *result = results.firstObject;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (result) [self importProvider:result.itemProvider];
    }];
}

- (void)importProvider:(NSItemProvider *)provider {
    NSString *typeIdentifier = nil;
    if ([provider hasItemConformingToTypeIdentifier:VCamMovieTypeIdentifier]) typeIdentifier = VCamMovieTypeIdentifier;
    else if ([provider hasItemConformingToTypeIdentifier:VCamImageTypeIdentifier]) typeIdentifier = VCamImageTypeIdentifier;
    if (!typeIdentifier) {
        _statusLabel.text = @"Unsupported media type";
        return;
    }

    _statusLabel.text = @"Importing media…";
    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *temporaryURL, NSError *error) {
        if (!temporaryURL || error) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not import the selected media"; });
            return;
        }

        NSString *directory = VCamMediaDirectory();
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSError *directoryError = nil;
        [fileManager createDirectoryAtPath:directory
               withIntermediateDirectories:YES
                                attributes:@{ NSFilePosixPermissions: @0755 }
                                     error:&directoryError];
        if (directoryError) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not create shared media folder"; });
            return;
        }

        NSString *extension = temporaryURL.pathExtension.lowercaseString;
        if (extension.length == 0) extension = [typeIdentifier isEqualToString:VCamMovieTypeIdentifier] ? @"mov" : @"jpg";
        NSString *filename = [NSString stringWithFormat:@"media-%@.%@", [[NSUUID UUID] UUIDString], extension];
        NSString *destination = [directory stringByAppendingPathComponent:filename];
        NSError *copyError = nil;
        [fileManager copyItemAtURL:temporaryURL toURL:[NSURL fileURLWithPath:destination] error:&copyError];
        if (copyError) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not save selected media"; });
            return;
        }

        chmod(directory.fileSystemRepresentation, 0755);
        chmod(destination.fileSystemRepresentation, 0644);
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:destination error:nil];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
            [fileManager removeItemAtPath:destination error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"The selected media is not a regular file"; });
            return;
        }

        VCamSetSetting(VCamMediaTypeKey, [typeIdentifier isEqualToString:VCamMovieTypeIdentifier] ? @"video" : @"image");
        VCamSetSetting(VCamVideoPausedKey, @NO);
        VCamSetSetting(VCamMediaPathKey, destination);
        VCamSetSetting(VCamEnabledKey, @YES);
        for (NSString *existingName in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
            if (![existingName hasPrefix:@"media-"] || [existingName isEqualToString:filename]) continue;
            NSString *existingPath = [directory stringByAppendingPathComponent:existingName];
            [fileManager removeItemAtPath:existingPath error:nil];
        }
        if (!VCamCopySetting(VCamZoomKey)) VCamSetSetting(VCamZoomKey, @1.0);
        if (!VCamCopySetting(VCamOffsetXKey)) VCamSetSetting(VCamOffsetXKey, @0.0);
        if (!VCamCopySetting(VCamOffsetYKey)) VCamSetSetting(VCamOffsetYKey, @0.0);
        if (!VCamCopySetting(VCamRotationKey)) VCamSetSetting(VCamRotationKey, @0);

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusLabel.text = @"Media imported · Original file preserved";
            [self refreshStatus];
            [self updateVideoButton];
        });
    }];
}

- (void)toggleReplacement {
    BOOL enabled = [VCamCopySetting(VCamEnabledKey) boolValue];
    VCamSetSetting(VCamEnabledKey, @(!enabled));
    [self refreshStatus];
}

- (void)adjustOffsetX:(CGFloat)delta {
    CGFloat value = [VCamCopySetting(VCamOffsetXKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamOffsetXKey) doubleValue] : 0.0;
    VCamSetSetting(VCamOffsetXKey, @(MAX(-1.0, MIN(1.0, value + delta))));
}
- (void)adjustOffsetY:(CGFloat)delta {
    CGFloat value = [VCamCopySetting(VCamOffsetYKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamOffsetYKey) doubleValue] : 0.0;
    VCamSetSetting(VCamOffsetYKey, @(MAX(-1.0, MIN(1.0, value + delta))));
}
- (void)moveLeft { [self adjustOffsetX:-VCamMoveStep]; }
- (void)moveRight { [self adjustOffsetX:VCamMoveStep]; }
- (void)moveUp { [self adjustOffsetY:VCamMoveStep]; }
- (void)moveDown { [self adjustOffsetY:-VCamMoveStep]; }
- (void)resetPosition { VCamSetSetting(VCamOffsetXKey, @0.0); VCamSetSetting(VCamOffsetYKey, @0.0); }
- (void)rotateLeft { NSInteger value = [VCamCopySetting(VCamRotationKey) integerValue]; VCamSetSetting(VCamRotationKey, @((value - 90 + 360) % 360)); }
- (void)rotateRight { NSInteger value = [VCamCopySetting(VCamRotationKey) integerValue]; VCamSetSetting(VCamRotationKey, @((value + 90) % 360)); }
- (void)zoomIn { CGFloat value = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MIN(3.0, value + 0.1))); }
- (void)zoomOut { CGFloat value = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MAX(0.5, value - 0.1))); }
@end

@implementation VCamMenuPresenter
+ (void)toggleMenu {
    if (sMenuVisible) [self hideMenu];
    else [self showMenu];
}

+ (void)ensureOverlayWindow {
    if (sOverlayWindow) return;

    // SpringBoard owns this detached system overlay, so it remains above
    // foreground app windows instead of being tied to the Home Screen scene.
    VCamOverlayWindow *window = [[VCamOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    window.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    window.windowLevel = UIWindowLevelAlert - 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.rootViewController = [[VCamMenuViewController alloc] init];
    sOverlayWindow = window;
}

+ (void)installOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureOverlayWindow];
        [sOverlayWindow makeKeyAndVisible];
        [(VCamMenuViewController *)sOverlayWindow.rootViewController setMenuVisible:NO];
        [sOverlayWindow resignKeyWindow];
    });
}

+ (void)showMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureOverlayWindow];
        [sOverlayWindow makeKeyAndVisible];
        [(VCamMenuViewController *)sOverlayWindow.rootViewController setMenuVisible:YES];
    });
}

+ (void)hideMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sOverlayWindow) return;
        [(VCamMenuViewController *)sOverlayWindow.rootViewController setMenuVisible:NO];
        [sOverlayWindow resignKeyWindow];
    });
}
@end
