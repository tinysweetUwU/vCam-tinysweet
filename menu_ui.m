#import "vcam_menu.h"
#import "vcam_shared.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>

@interface VCamMenuViewController : UIViewController <PHPickerViewControllerDelegate>
- (void)setMenuVisible:(BOOL)visible;
@end

@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface VCamPassThroughView : UIView
@property (nonatomic, weak) UIView *floatingControl;
@property (nonatomic, weak) UIView *floatingPanel;
@property (nonatomic) BOOL menuVisible;
@end

@implementation VCamPassThroughView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (self.menuVisible) return YES;
    if (self.floatingPanel && !self.floatingPanel.hidden && CGRectContainsPoint(self.floatingPanel.frame, point)) return YES;
    if (self.floatingControl && !self.floatingControl.hidden && CGRectContainsPoint(self.floatingControl.frame, point)) return YES;
    return NO;
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
    [_floatingControl setTitle:@"Control" forState:UIControlStateNormal];
    [_floatingControl setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _floatingControl.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _floatingControl.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    _floatingControl.layer.cornerRadius = 17;
    _floatingControl.layer.borderWidth = 1;
    _floatingControl.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    _floatingControl.layer.shadowColor = UIColor.blackColor.CGColor;
    _floatingControl.layer.shadowOpacity = 0.28;
    _floatingControl.layer.shadowRadius = 8;
    _floatingControl.layer.shadowOffset = CGSizeMake(0, 3);
    _floatingControl.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 86.0,
                                        UIScreen.mainScreen.bounds.size.height * 0.68,
                                        72.0, 38.0);
    [self.view addSubview:_floatingControl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFloatingPanel)];
    [_floatingControl addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFloatingControl:)];
    pan.cancelsTouchesInView = NO;
    [_floatingControl addGestureRecognizer:pan];

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    panel.frame = CGRectMake(0, 0, 228, 296);
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    panel.hidden = YES;
    _floatingPanel = panel;
    [self.view addSubview:panel];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-10],
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:9],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-9]
    ]];

    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    UILabel *heading = VCamMakeLabel(@"Position & Transform", [UIFont systemFontOfSize:13 weight:UIFontWeightBold], UIColor.whiteColor);
    [header addArrangedSubview:heading];
    [header addArrangedSubview:[[UIView alloc] init]];
    UIButton *close = VCamMakeButton(@"✕", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(toggleFloatingPanel));
    [close.widthAnchor constraintEqualToConstant:34].active = YES;
    [header addArrangedSubview:close];
    [stack addArrangedSubview:header];

    UIStackView *moveRow1 = [self horizontalRow];
    [moveRow1 addArrangedSubview:[self spacer]];
    [moveRow1 addArrangedSubview:VCamMakeButton(@"↑", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(moveUp))];
    [moveRow1 addArrangedSubview:[self spacer]];
    UIStackView *moveRow2 = [self horizontalRow];
    [moveRow2 addArrangedSubview:VCamMakeButton(@"←", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(moveLeft))];
    [moveRow2 addArrangedSubview:VCamMakeButton(@"Center", [UIColor colorWithWhite:1 alpha:0.08], self, @selector(resetPosition))];
    [moveRow2 addArrangedSubview:VCamMakeButton(@"→", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(moveRight))];
    UIStackView *moveRow3 = [self horizontalRow];
    [moveRow3 addArrangedSubview:[self spacer]];
    [moveRow3 addArrangedSubview:VCamMakeButton(@"↓", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(moveDown))];
    [moveRow3 addArrangedSubview:[self spacer]];
    [stack addArrangedSubview:moveRow1];
    [stack addArrangedSubview:moveRow2];
    [stack addArrangedSubview:moveRow3];

    UIStackView *rotateRow = [self horizontalRow];
    [rotateRow addArrangedSubview:VCamMakeButton(@"↶ Rotate", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(rotateLeft))];
    [rotateRow addArrangedSubview:VCamMakeButton(@"Rotate ↻", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(rotateRight))];
    [stack addArrangedSubview:rotateRow];

    UIStackView *zoomRow = [self horizontalRow];
    [zoomRow addArrangedSubview:VCamMakeButton(@"− Zoom", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(zoomOut))];
    [zoomRow addArrangedSubview:VCamMakeButton(@"+ Zoom", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(zoomIn))];
    [stack addArrangedSubview:zoomRow];

    _passThroughView.floatingControl = _floatingControl;
    _passThroughView.floatingPanel = _floatingPanel;
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

- (void)toggleFloatingPanel {
    _floatingPanel.hidden = !_floatingPanel.hidden;
    [self layoutFloatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
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
    NSString *outputLine = rendered ? [NSString stringWithFormat:@"Buffer render call: SENT (%@)", runtime[@"renderedFrameSize"] ?: @"size unknown"] : @"Buffer render call: NOT SENT YET";

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        daemonLine,
        heartbeatLine,
        [NSString stringWithFormat:@"BWNodeOutput hook: %@", hookState.uppercaseString],
        frameLine,
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
    [self.view bringSubviewToFront:_floatingControl];
    if (!_floatingPanel.hidden) [self.view bringSubviewToFront:_floatingPanel];
    [self.view bringSubviewToFront:_floatingControl];
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

+ (void)showMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sOverlayWindow) {
            UIWindowScene *activeScene = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                }
            }
            VCamOverlayWindow *window = activeScene
                ? [[VCamOverlayWindow alloc] initWithWindowScene:activeScene]
                : [[VCamOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            window.frame = UIScreen.mainScreen.bounds;
            window.windowLevel = UIWindowLevelAlert + 100.0;
            window.backgroundColor = UIColor.clearColor;
            window.rootViewController = [[VCamMenuViewController alloc] init];
            sOverlayWindow = window;
        }
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
