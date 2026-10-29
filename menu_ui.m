#import "vcam_menu.h"
#import "vcam_shared.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>

@interface VCamMenuViewController : UIViewController <PHPickerViewControllerDelegate>
@end

@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

static VCamOverlayWindow *sOverlayWindow = nil;
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
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
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
    UIButton *_toggleButton;
    UIView *_panel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIButton *backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    [backdrop addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = 22;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 1;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _panel = blur;
    [self.view addSubview:blur];
    CGFloat panelWidth = MIN(UIScreen.mainScreen.bounds.size.width - 32.0, 360.0);
    CGFloat panelHeight = MIN(UIScreen.mainScreen.bounds.size.height - 72.0, 600.0);
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
    UILabel *title = VCamMakeLabel(@"VCam Control", [UIFont systemFontOfSize:21 weight:UIFontWeightBold], UIColor.whiteColor);
    [title setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
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

    [stack addArrangedSubview:VCamMakeLabel(@"Move media", [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], UIColor.whiteColor)];
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

    [stack addArrangedSubview:VCamMakeLabel(@"Transform", [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold], UIColor.whiteColor)];
    UIStackView *transformRow = [self horizontalRow];
    [transformRow addArrangedSubview:VCamMakeButton(@"↶ Rotate", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(rotateLeft))];
    [transformRow addArrangedSubview:VCamMakeButton(@"Rotate ↻", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(rotateRight))];
    [stack addArrangedSubview:transformRow];

    UIStackView *zoomRow = [self horizontalRow];
    [zoomRow addArrangedSubview:VCamMakeButton(@"− Zoom out", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(zoomOut))];
    [zoomRow addArrangedSubview:VCamMakeButton(@"+ Zoom in", [UIColor colorWithWhite:1 alpha:0.12], self, @selector(zoomIn))];
    [stack addArrangedSubview:zoomRow];

    [stack addArrangedSubview:VCamMakeLabel(@"Press Volume Up + Volume Down together to open or close this menu.",
                                            [UIFont systemFontOfSize:12], [UIColor colorWithWhite:1 alpha:0.60])];
    [self refreshStatus];
}

- (UIStackView *)horizontalRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

- (UIView *)spacer {
    UIView *view = [[UIView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    return view;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

- (void)refreshStatus {
    NSString *path = VCamCopySetting(VCamMediaPathKey);
    BOOL enabled = [VCamCopySetting(VCamEnabledKey) boolValue];
    if ([path isKindOfClass:[NSString class]] && path.length > 0) {
        _statusLabel.text = [NSString stringWithFormat:@"Selected: %@%@", path.lastPathComponent, enabled ? @" · Active" : @" · Disabled"];
    } else {
        _statusLabel.text = @"No replacement media selected";
    }
    [_toggleButton setTitle:(enabled ? @"Disable Replacement" : @"Enable Replacement") forState:UIControlStateNormal];
    _toggleButton.backgroundColor = enabled ? [UIColor colorWithRed:0.66 green:0.25 blue:0.22 alpha:1]
                                            : [UIColor colorWithRed:0.13 green:0.52 blue:0.32 alpha:1];
}

- (void)closeMenu { [VCamMenuPresenter hideMenu]; }

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
        if (!result) return;
        [self importProvider:result.itemProvider];
    }];
}

- (void)importProvider:(NSItemProvider *)provider {
    NSString *typeIdentifier = nil;
    if ([provider hasItemConformingToTypeIdentifier:VCamMovieTypeIdentifier]) {
        typeIdentifier = VCamMovieTypeIdentifier;
    } else if ([provider hasItemConformingToTypeIdentifier:VCamImageTypeIdentifier]) {
        typeIdentifier = VCamImageTypeIdentifier;
    }
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
        NSError *copyError = nil;
        [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0755 } error:&copyError];
        if (copyError) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not create media folder"; });
            return;
        }

        NSString *extension = temporaryURL.pathExtension.lowercaseString;
        if (extension.length == 0) extension = [typeIdentifier isEqualToString:VCamMovieTypeIdentifier] ? @"mov" : @"jpg";
        NSString *filename = [NSString stringWithFormat:@"media-%@.%@", [[NSUUID UUID] UUIDString], extension];
        NSString *destination = [directory stringByAppendingPathComponent:filename];
        NSError *fileError = nil;
        [fileManager copyItemAtURL:temporaryURL toURL:[NSURL fileURLWithPath:destination] error:&fileError];
        if (fileError) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_statusLabel.text = @"Could not save selected media"; });
            return;
        }
        chmod(directory.fileSystemRepresentation, 0755);
        chmod(destination.fileSystemRepresentation, 0644);

        VCamSetSetting(VCamMediaPathKey, destination);
        VCamSetSetting(VCamEnabledKey, @YES);
        // Keep only the currently selected import to avoid filling Media with old videos.
        for (NSString *existingName in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *existingPath = [directory stringByAppendingPathComponent:existingName];
            if (![existingName isEqualToString:@"settings.plist"] && ![existingPath isEqualToString:destination]) {
                [fileManager removeItemAtPath:existingPath error:nil];
            }
        }
        if (!VCamCopySetting(VCamZoomKey)) VCamSetSetting(VCamZoomKey, @1.0);
        if (!VCamCopySetting(VCamOffsetXKey)) VCamSetSetting(VCamOffsetXKey, @0.0);
        if (!VCamCopySetting(VCamOffsetYKey)) VCamSetSetting(VCamOffsetYKey, @0.0);
        if (!VCamCopySetting(VCamRotationKey)) VCamSetSetting(VCamRotationKey, @0);

        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStatus]; });
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
- (void)rotateLeft { NSInteger v = [VCamCopySetting(VCamRotationKey) integerValue]; VCamSetSetting(VCamRotationKey, @((v - 90 + 360) % 360)); }
- (void)rotateRight { NSInteger v = [VCamCopySetting(VCamRotationKey) integerValue]; VCamSetSetting(VCamRotationKey, @((v + 90) % 360)); }
- (void)zoomIn { CGFloat v = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MIN(3.0, v + 0.1))); }
- (void)zoomOut { CGFloat v = [VCamCopySetting(VCamZoomKey) respondsToSelector:@selector(doubleValue)] ? [VCamCopySetting(VCamZoomKey) doubleValue] : 1.0; VCamSetSetting(VCamZoomKey, @(MAX(0.5, v - 0.1))); }
@end

@implementation VCamMenuPresenter
+ (void)toggleMenu {
    if (sOverlayWindow && !sOverlayWindow.hidden) [self hideMenu];
    else [self showMenu];
}

+ (void)showMenu {
    if (sOverlayWindow && !sOverlayWindow.hidden) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sOverlayWindow && !sOverlayWindow.hidden) return;
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
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
        [window makeKeyAndVisible];
    });
}

+ (void)hideMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        [sOverlayWindow resignKeyWindow];
        sOverlayWindow.hidden = YES;
        sOverlayWindow.rootViewController = nil;
        sOverlayWindow = nil;
    });
}
@end
