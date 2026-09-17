#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#import <notify.h>

// 版本串同时用于日志与预览层标题。EchoReborn 侧的版本号由 scripts/er_set_version.py
// 统一写入（本文件里的 ver= 与 EchoRebornRebornDualCam 段一并同步）。
static NSString *const kDualCamVersion = @"1.0.7-18";
static BOOL g_dualCamOn = NO;
static NSHashTable *g_appSessions = nil;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_toggleBtn = nil;

@class DualCamPreviewController;
static DualCamPreviewController *g_preview = nil;
static UIImage *g_backShot = nil;
static UIImage *g_frontShot = nil;

static void toggleDualCam(void);

@interface DualCamToggleTarget : NSObject
@end
@implementation DualCamToggleTarget
+ (void)toggle { toggleDualCam(); }
@end


@interface DualCamPreviewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) AVCaptureMultiCamSession *session;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *backLayer;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *frontLayer;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *backPhotoOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *frontPhotoOutput;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *shutterButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *flashView;
@property (nonatomic, strong) UIButton *flashButton;
@property (nonatomic, strong) UIButton *modeButton;
@property (nonatomic, strong) UILabel *zoomLabel;
@property (nonatomic, strong) AVCaptureDevice *backDevice;
@property (nonatomic, strong) AVCaptureDevice *frontDevice;
@property (nonatomic, assign) BOOL isVideoMode;
@property (nonatomic, assign) int flashState;
@property (nonatomic, assign) CGFloat zoomBase;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, assign) CVPixelBufferPoolRef recordPool;
@property (nonatomic, assign) CVPixelBufferRef lastBackBuf;
@property (nonatomic, assign) CVPixelBufferRef lastFrontBuf;
@property (nonatomic, assign) BOOL writerSessionStarted;
@property (nonatomic, assign) CGFloat recordDegrees;
@property (nonatomic, assign) CGFloat recordW;
@property (nonatomic, assign) CGFloat recordH;
- (void)startDualCam;
- (void)stopDualCam;
- (void)captureShutter;
- (void)toggleFlash;
- (void)toggleMode;
- (void)startRecording;
- (void)stopRecording;
- (void)handlePinch:(UIPinchGestureRecognizer *)g;
@end

static void shootPhoto(void);

@interface DualCamShutterTarget : NSObject
@end
@implementation DualCamShutterTarget
+ (void)shoot { shootPhoto(); }
@end

static void shootPhoto(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_preview captureShutter];
    });
}

@implementation DualCamPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.sampleQueue = dispatch_queue_create("com.macxk.dualcam.sample", DISPATCH_QUEUE_SERIAL);

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 320, self.view.bounds.size.width - 60, 120)];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    self.statusLabel.layer.cornerRadius = 10;
    self.statusLabel.layer.masksToBounds = YES;
    self.statusLabel.hidden = YES;
    [self.view addSubview:self.statusLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sessionRuntimeError:)
                                                 name:AVCaptureSessionRuntimeErrorNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sessionWasInterrupted:)
                                                 name:AVCaptureSessionWasInterruptedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateOrientations)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];

    [self ensureLayers];

    // 快门键
    self.shutterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.shutterButton.frame = CGRectMake(self.view.bounds.size.width / 2 - 35, self.view.bounds.size.height - 130, 70, 70);
    self.shutterButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    self.shutterButton.backgroundColor = [UIColor whiteColor];
    self.shutterButton.layer.cornerRadius = 35;
    self.shutterButton.layer.borderWidth = 4;
    self.shutterButton.layer.borderColor = [UIColor lightGrayColor].CGColor;
    [self.shutterButton addTarget:[DualCamShutterTarget class] action:@selector(shoot) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shutterButton];

    // 1.0.7-17：**返回按钮**（双摄画面常驻）。双摄用全屏窗口接管了相机 UI，
    // 原来唯一的退出途径是顶部栏按钮 —— 而它在覆盖层之下，用户反馈「返回图标
    // 会消失」。这里在双摄画面左上角放一个常驻的返回按钮，点一下退回相机。
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.frame = CGRectMake(18.0, 18.0, 36.0, 36.0);
    closeButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    closeButton.layer.cornerRadius = 18.0;
    closeButton.layer.masksToBounds = YES;
    [closeButton setImage:[UIImage systemImageNamed:@"chevron.left"]
                 forState:UIControlStateNormal];
    closeButton.tintColor = UIColor.whiteColor;
    closeButton.accessibilityLabel = @"退出双摄";
    [closeButton addTarget:[DualCamToggleTarget class]
                    action:@selector(toggle)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeButton];
    _closeButton = closeButton;

    // 拍照闪光反馈
    self.flashView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.flashView.backgroundColor = [UIColor whiteColor];
    self.flashView.alpha = 0;
    self.flashView.userInteractionEnabled = NO;
    self.flashView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.flashView];

    // 闪光灯按钮（关/开/自动）
    self.flashButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.flashButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    self.flashButton.layer.cornerRadius = 22;
    self.flashButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [self.flashButton setTitle:@"关" forState:UIControlStateNormal];
    [self.flashButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.flashButton addTarget:self action:@selector(toggleFlash) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.flashButton];

    // 照片/录像切换
    self.modeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.modeButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    self.modeButton.layer.cornerRadius = 22;
    self.modeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [self.modeButton setTitle:@"录像" forState:UIControlStateNormal];
    [self.modeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.modeButton addTarget:self action:@selector(toggleMode) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.modeButton];

    // 变焦倍数提示
    self.zoomLabel = [[UILabel alloc] init];
    self.zoomLabel.textColor = [UIColor whiteColor];
    self.zoomLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.zoomLabel.textAlignment = NSTextAlignmentCenter;
    self.zoomLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    self.zoomLabel.layer.cornerRadius = 8;
    self.zoomLabel.layer.masksToBounds = YES;
    self.zoomLabel.hidden = YES;
    [self.view addSubview:self.zoomLabel];

    // 双指捏合变焦
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self.view addGestureRecognizer:pinch];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.backLayer.frame = self.view.bounds;
    CGFloat w = 130, h = 180;
    self.frontLayer.frame = CGRectMake(self.view.bounds.size.width - w - 16, 80, w, h);
    self.statusLabel.frame = CGRectMake(30, self.view.bounds.size.height / 2 - 60,
                                        self.view.bounds.size.width - 60, 120);
    CGFloat sw = self.view.bounds.size.width, sh = self.view.bounds.size.height;
    CGFloat cy = sh - 130;
    self.shutterButton.frame = CGRectMake(sw / 2 - 35, cy, 70, 70);
    self.flashButton.frame = CGRectMake(sw / 2 - 160, cy + 13, 44, 44);
    self.modeButton.frame = CGRectMake(sw / 2 + 116, cy + 13, 44, 44);
    self.zoomLabel.frame = CGRectMake(sw / 2 - 40, 40, 80, 30);
}

- (void)ensureLayers {
    if (!self.backLayer) {
        self.backLayer = [[AVSampleBufferDisplayLayer alloc] init];
        self.backLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.view.layer addSublayer:self.backLayer];
    }
    if (!self.frontLayer) {
        self.frontLayer = [[AVSampleBufferDisplayLayer alloc] init];
        self.frontLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.frontLayer.cornerRadius = 14;
        self.frontLayer.masksToBounds = YES;
        self.frontLayer.borderWidth = 2;
        self.frontLayer.borderColor = [UIColor whiteColor].CGColor;
        [self.view.layer addSublayer:self.frontLayer];
    }
    [self.view setNeedsLayout];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (AVCaptureVideoOrientation)currentVideoOrientation {
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationPortraitUpsideDown: return AVCaptureVideoOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft:      return AVCaptureVideoOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight:     return AVCaptureVideoOrientationLandscapeLeft;
        default:                                    return AVCaptureVideoOrientationPortrait;
    }
}

- (void)updateOrientations {
    if (!self.session) return;
    AVCaptureVideoOrientation o = [self currentVideoOrientation];
    for (AVCaptureConnection *c in self.backOutput.connections) {
        if (c.supportsVideoOrientation) c.videoOrientation = o;
    }
    for (AVCaptureConnection *c in self.frontOutput.connections) {
        if (c.supportsVideoOrientation) c.videoOrientation = o;
    }
}

- (void)setStatus:(NSString *)status {
    self.statusLabel.text = status;
    self.statusLabel.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self.statusLabel.text isEqualToString:status]) self.statusLabel.hidden = YES;
    });
}

- (void)sessionRuntimeError:(NSNotification *)note {
    if (note.object != self.session) return;
    NSError *err = note.userInfo[AVCaptureSessionErrorKey];
    [self setStatus:[NSString stringWithFormat:@"会话错误: %@", err.localizedDescription]];
}

- (void)sessionWasInterrupted:(NSNotification *)note {
    if (note.object != self.session) return;
    NSNumber *reason = note.userInfo[AVCaptureSessionInterruptionReasonKey];
    [self setStatus:[NSString stringWithFormat:@"会话被中断: %@", reason]];
}

- (AVCaptureInputPort *)videoPortOfInput:(AVCaptureDeviceInput *)input {
    for (AVCaptureInputPort *p in input.ports) {
        if ([p.mediaType isEqualToString:AVMediaTypeVideo]) return p;
    }
    return nil;
}

- (void)matchFormatsOfDevice:(AVCaptureDevice *)device to:(AVCaptureDeviceFormat *)format {
    if (!format || ![device lockForConfiguration:NULL]) return;
    device.activeFormat = format;
    device.activeVideoMinFrameDuration = CMTimeMake(1, 30);
    device.activeVideoMaxFrameDuration = CMTimeMake(1, 30);
    [device unlockForConfiguration];
}

- (void)configureDevicesBack:(AVCaptureDevice *)back front:(AVCaptureDevice *)front {
    AVCaptureDeviceFormat *backFmt = nil, *frontFmt = nil;
    for (AVCaptureDeviceFormat *f in back.formats) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        if (d.width == 1920 && d.height == 1080) { backFmt = f; break; }
    }
    for (AVCaptureDeviceFormat *f in front.formats) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        if (d.width == 1920 && d.height == 1080) { frontFmt = f; break; }
    }
    if (backFmt) [self matchFormatsOfDevice:back to:backFmt];
    if (frontFmt) [self matchFormatsOfDevice:front to:frontFmt];
}

- (void)startDualCam {
    if (self.session) return;
    [self setStatus:[NSString stringWithFormat:@"DualCam v%@", kDualCamVersion]];
    [self ensureLayers];

    if (![AVCaptureMultiCamSession isMultiCamSupported]) {
        [self setStatus:@"设备不支持多摄（需 A12+ / iOS 13+）"];
        return;
    }

    AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionBack];
    AVCaptureDevice *front = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionFront];
    if (!back || !front) {
        [self setStatus:@"找不到前后摄像头"];
        return;
    }
    self.backDevice = back;
    self.frontDevice = front;

    AVCaptureDeviceInput *backInput = nil, *frontInput = nil;
    for (int i = 0; i < 20; i++) {
        NSError *err = nil;
        backInput = [AVCaptureDeviceInput deviceInputWithDevice:back error:&err];
        err = nil;
        frontInput = [AVCaptureDeviceInput deviceInputWithDevice:front error:&err];
        if (backInput && frontInput) break;
        [self setStatus:@"等待摄像头释放…"];
        usleep(150 * 1000);
    }
    if (!backInput || !frontInput) {
        [self setStatus:@"摄像头被占用，无法开启双摄（看日志）"];
        return;
    }

    [self configureDevicesBack:back front:front];

    AVCaptureMultiCamSession *session = [[AVCaptureMultiCamSession alloc] init];
    session.sessionPreset = AVCaptureSessionPresetInputPriority;
    session.automaticallyConfiguresCaptureDeviceForWideColor = NO;

    [session beginConfiguration];

    if ([session canAddInput:backInput]) {
        [session addInput:backInput];
    } else {
        [self setStatus:@"无法添加后置输入"];
    }
    if ([session canAddInput:frontInput]) {
        [session addInput:frontInput];
    } else {
        [self setStatus:@"无法添加前置输入"];
    }

    self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.frontOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    [self.backOutput setSampleBufferDelegate:self queue:self.sampleQueue];
    [self.frontOutput setSampleBufferDelegate:self queue:self.sampleQueue];

    if ([session canAddOutput:self.backOutput]) [session addOutput:self.backOutput];
    if ([session canAddOutput:self.frontOutput]) [session addOutput:self.frontOutput];

    for (AVCaptureConnection *c in self.backOutput.connections) [session removeConnection:c];
    for (AVCaptureConnection *c in self.frontOutput.connections) [session removeConnection:c];

    AVCaptureInputPort *backPort = [self videoPortOfInput:backInput];
    AVCaptureInputPort *frontPort = [self videoPortOfInput:frontInput];
    if (backPort && frontPort) {
        AVCaptureConnection *backConn = [AVCaptureConnection connectionWithInputPorts:@[backPort] output:self.backOutput];
        backConn.videoMirrored = NO;
        if ([session canAddConnection:backConn]) {
            [session addConnection:backConn];
        }

        AVCaptureConnection *frontConn = [AVCaptureConnection connectionWithInputPorts:@[frontPort] output:self.frontOutput];
        frontConn.automaticallyAdjustsVideoMirroring = NO;
        frontConn.videoMirrored = YES; // 前置按自拍习惯镜像
        if ([session canAddConnection:frontConn]) {
            [session addConnection:frontConn];
        }
    }

    self.backPhotoOutput = [[AVCapturePhotoOutput alloc] init];
    self.frontPhotoOutput = [[AVCapturePhotoOutput alloc] init];
    if ([session canAddOutput:self.backPhotoOutput]) [session addOutput:self.backPhotoOutput];
    if ([session canAddOutput:self.frontPhotoOutput]) [session addOutput:self.frontPhotoOutput];
    for (AVCaptureConnection *c in self.backPhotoOutput.connections) [session removeConnection:c];
    for (AVCaptureConnection *c in self.frontPhotoOutput.connections) [session removeConnection:c];
    if (backPort && frontPort) {
        AVCaptureConnection *backPhotoConn = [AVCaptureConnection connectionWithInputPorts:@[backPort] output:self.backPhotoOutput];
        if ([session canAddConnection:backPhotoConn]) [session addConnection:backPhotoConn];
        AVCaptureConnection *frontPhotoConn = [AVCaptureConnection connectionWithInputPorts:@[frontPort] output:self.frontPhotoOutput];
        if ([session canAddConnection:frontPhotoConn]) [session addConnection:frontPhotoConn];
    }

    [session commitConfiguration];

    self.session = session;
    [self updateOrientations];
    [session startRunning];
}

- (void)stopDualCam {
    if (self.isRecording) [self stopRecording];
    if (self.lastBackBuf) { CVPixelBufferRelease(self.lastBackBuf); self.lastBackBuf = NULL; }
    if (self.lastFrontBuf) { CVPixelBufferRelease(self.lastFrontBuf); self.lastFrontBuf = NULL; }
    [self.session stopRunning];
    self.session = nil;
    [self.backLayer removeFromSuperlayer];
    [self.frontLayer removeFromSuperlayer];
    self.backLayer = nil;
    self.frontLayer = nil;
    self.backOutput = nil;
    self.frontOutput = nil;
    self.backPhotoOutput = nil;
    self.frontPhotoOutput = nil;
    g_backShot = nil;
    g_frontShot = nil;
    self.statusLabel.hidden = YES;
}

static int g_backFrames = 0;

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
 
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pb) {
        if (output == self.backOutput) {
            if (self.lastBackBuf) CVPixelBufferRelease(self.lastBackBuf);
            self.lastBackBuf = CVPixelBufferRetain(pb);
            if (self.isRecording && self.lastFrontBuf && self.writerInput.readyForMoreMediaData) {
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                [self appendVideoFrameAtTime:pts];
            }
        } else {
            if (self.lastFrontBuf) CVPixelBufferRelease(self.lastFrontBuf);
            self.lastFrontBuf = CVPixelBufferRetain(pb);
        }
    }
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        AVSampleBufferDisplayLayer *layer = nil;
        if (output == self.backOutput) {
            layer = self.backLayer;
            if (g_backFrames++ == 0) [self setStatus:@"运行中：后置 + 前置"];
        } else {
            layer = self.frontLayer;
        }
        if (layer) {
            if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                [layer flushAndRemoveImage];
            }
            [layer enqueueSampleBuffer:sampleBuffer];
        }
        CFRelease(sampleBuffer);
    });
}

- (void)captureShutter {
    if (self.isVideoMode) {
        [self toggleRecording];
        return;
    }
    if (!self.session || !self.backPhotoOutput || !self.frontPhotoOutput) {
        [self setStatus:@"双摄未运行"];
        return;
    }
    // 快门白闪反馈
    self.flashView.alpha = 0.9;
    [UIView animateWithDuration:0.25 animations:^{ self.flashView.alpha = 0; }];

    AVCapturePhotoSettings *bs = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
    bs.flashMode = (AVCaptureFlashMode)self.flashState;
    AVCapturePhotoSettings *fs = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
    fs.flashMode = AVCaptureFlashModeOff;
    [self.backPhotoOutput capturePhotoWithSettings:bs delegate:self];
    [self.frontPhotoOutput capturePhotoWithSettings:fs delegate:self];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (!self.backDevice) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.zoomBase = self.backDevice.videoZoomFactor;
    }
    CGFloat maxZoom = MIN(self.backDevice.activeFormat.videoMaxZoomFactor, 10.0);
    CGFloat zoom = MAX(1.0, MIN(maxZoom, self.zoomBase * g.scale));
    if ([self.backDevice lockForConfiguration:NULL]) {
        self.backDevice.videoZoomFactor = zoom;
        [self.backDevice unlockForConfiguration];
    }
    self.zoomLabel.text = [NSString stringWithFormat:@"%.1fx", zoom];
    self.zoomLabel.hidden = NO;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.zoomLabel.hidden = YES;
        });
    }
}

- (void)toggleFlash {
    self.flashState = (self.flashState + 1) % 3; // 关 -> 开 -> 自动
    if (self.backDevice && self.backDevice.hasTorch && [self.backDevice lockForConfiguration:NULL]) {
        self.backDevice.torchMode = (AVCaptureTorchMode)self.flashState;
        [self.backDevice unlockForConfiguration];
    }
    NSString *t = self.flashState == 0 ? @"关" : (self.flashState == 1 ? @"开" : @"自动");
    [self.flashButton setTitle:t forState:UIControlStateNormal];
}

- (void)toggleMode {
    if (self.isRecording) return;
    self.isVideoMode = !self.isVideoMode;
    [self.modeButton setTitle:self.isVideoMode ? @"照片" : @"录像" forState:UIControlStateNormal];
}

- (CGFloat)currentDegrees {
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationPortraitUpsideDown: return 270;
        case UIDeviceOrientationLandscapeLeft:      return 180;
        case UIDeviceOrientationLandscapeRight:     return 0;
        default:                                    return 90;
    }
}

- (void)toggleRecording {
    if (self.isRecording) [self stopRecording];
    else [self startRecording];
}

- (void)startRecording {
    if (!self.session) {
        [self setStatus:@"双摄未运行"];
        return;
    }
    self.recordDegrees = [self currentDegrees];
    BOOL swap = ((int)self.recordDegrees % 180) != 0;
    CMFormatDescriptionRef fd = self.backDevice.activeFormat.formatDescription;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
    self.recordW = swap ? dims.height : dims.width;
    self.recordH = swap ? dims.width : dims.height;

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dualcam_rec.mov"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSError *err = nil;
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeQuickTimeMovie error:&err];
    if (!w) {
        [self setStatus:@"无法开始录像"];
        return;
    }
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(self.recordW),
        AVVideoHeightKey: @(self.recordH),
    }];
    self.writerInput.expectsMediaDataInRealTime = YES;
    self.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput
                                                                                    sourcePixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(self.recordW),
        (id)kCVPixelBufferHeightKey: @(self.recordH),
    }];
    if ([w canAddInput:self.writerInput]) [w addInput:self.writerInput];
   
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(self.recordW),
        (id)kCVPixelBufferHeightKey: @(self.recordH),
    };
    if (self.recordPool) CVPixelBufferPoolRelease(self.recordPool);
    CVPixelBufferPoolRef pool = NULL;
    CVReturn poolRet = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)poolAttrs, &pool);
    self.recordPool = pool;
    if (poolRet != kCVReturnSuccess || !self.recordPool) {
        [self setStatus:@"无法开始录像"];
        return;
    }
    self.writer = w;
    if (![w startWriting]) {
        [self setStatus:@"无法开始录像"];
        return;
    }
    self.writerSessionStarted = NO;
    self.isRecording = YES;
    self.shutterButton.backgroundColor = [UIColor redColor];
    [self setStatus:@"录像中…"];
}

- (void)stopRecording {
    if (!self.isRecording) return;
    self.isRecording = NO;
    self.shutterButton.backgroundColor = [UIColor whiteColor];
    [self setStatus:@"正在保存视频…"];
    AVAssetWriter *w = self.writer;
    NSURL *url = w.outputURL;
    [self.writerInput markAsFinished];
    // 1.0.7-5：必须是 __typeof__ 而不是 typeof。
    // 本文件是 .xm（Theos 按 ObjC++ 编译），在 C++ 模式下 `typeof` 不是关键字
    // （只有 GNU 扩展的 __typeof__ 可用），写 typeof(self) 会连锁报
    //     error: expected unqualified-id
    //     error: use of undeclared identifier 'weakSelf'  ×N
    __weak __typeof__(self) weakSelf = self;
    [w finishWritingWithCompletionHandler:^{
        if (w.status == AVAssetWriterStatusCompleted) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            } completionHandler:^(BOOL success, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf setStatus:success ? @"视频已保存到相册" : [NSString stringWithFormat:@"保存失败: %@", error.localizedDescription]];
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setStatus:@"视频写入失败"];
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.recordPool) {
                CVPixelBufferPoolRelease(weakSelf.recordPool);
                weakSelf.recordPool = NULL;
            }
            weakSelf.writer = nil;
            weakSelf.writerInput = nil;
            weakSelf.adaptor = nil;
        });
    }];
}

static void releaseFrameCopy(void *info, const void *data, size_t size) {
    free((void *)data);
}

- (CGImageRef)cgImageFromBuffer:(CVPixelBufferRef)buf {
    if (!buf) return NULL;
    CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
    size_t bpr = CVPixelBufferGetBytesPerRow(buf);
    void *base = CVPixelBufferGetBaseAddress(buf);
    void *copy = malloc(bpr * h);
    memcpy(copy, base, bpr * h);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, copy, bpr * h, releaseFrameCopy);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(w, h, 8, 32, bpr, cs,
                                  kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                  provider, NULL, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    return cg;
}

- (CVPixelBufferRef)compositeVideoFrame {
    CVPixelBufferRef outBuf = NULL;
    if (self.recordPool) {
        CVPixelBufferPoolCreatePixelBuffer(NULL, self.recordPool, &outBuf);
    }
    if (!outBuf) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(outBuf, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(outBuf),
                                           self.recordW, self.recordH, 8,
                                           CVPixelBufferGetBytesPerRow(outBuf),
                                           cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!c) {
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(outBuf, 0);
        CVPixelBufferRelease(outBuf);
        return NULL;
    }

    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, self.recordW, self.recordH));

    CGImageRef backImg = [self cgImageFromBuffer:self.lastBackBuf];
    if (backImg) {
        [self drawCGImage:backImg inContext:c at:CGPointMake(self.recordW / 2, self.recordH / 2)
                     size:CGSizeMake(self.recordW, self.recordH)
                  degrees:self.recordDegrees mirrored:NO];
        CGImageRelease(backImg);
    }

    CGImageRef frontImg = [self cgImageFromBuffer:self.lastFrontBuf];
    if (frontImg) {
        size_t fw = CGImageGetWidth(frontImg), fh = CGImageGetHeight(frontImg);
        BOOL swap = ((int)self.recordDegrees % 180) != 0;
        CGFloat pw = self.recordW * 0.28;
        CGFloat fAspect = swap ? ((CGFloat)fw / fh) : ((CGFloat)fh / fw);
        CGFloat ph = pw * fAspect;
        CGFloat px = self.recordW - pw - self.recordW * 0.03;
        CGFloat py = self.recordH - ph - self.recordH * 0.03;
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(px, py, pw, ph) cornerRadius:14];
        CGContextSaveGState(c);
        [path addClip];
        [self drawCGImage:frontImg inContext:c at:CGPointMake(px + pw / 2, py + ph / 2)
                     size:CGSizeMake(pw, ph) degrees:self.recordDegrees mirrored:YES];
        CGContextRestoreGState(c);
        [[UIColor whiteColor] setStroke];
        path.lineWidth = 4;
        [path stroke];
        CGImageRelease(frontImg);
    }

    CGColorSpaceRelease(cs);
    CGContextRelease(c);
    CVPixelBufferUnlockBaseAddress(outBuf, 0);
    return outBuf;
}

- (void)appendVideoFrameAtTime:(CMTime)pts {
    if (!self.writerSessionStarted) {
        [self.writer startSessionAtSourceTime:pts];
        self.writerSessionStarted = YES;
    }
    CVPixelBufferRef outBuf = [self compositeVideoFrame];
    if (!outBuf) return;
    [self.adaptor appendPixelBuffer:outBuf withPresentationTime:pts];
    CVPixelBufferRelease(outBuf);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setStatus:@"拍照失败"]; });
        return;
    }
    NSData *data = [photo fileDataRepresentation];
    UIImage *img = data ? [UIImage imageWithData:data] : nil;
    if (!img) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (output == self.backPhotoOutput) {
            g_backShot = img;
        } else {
            g_frontShot = img;
        }
        [self trySaveIfBothReady];
    });
}

- (void)drawCGImage:(CGImageRef)img inContext:(CGContextRef)c at:(CGPoint)center size:(CGSize)box degrees:(CGFloat)deg mirrored:(BOOL)mirror {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, center.x, center.y);
    CGContextRotateCTM(c, deg * M_PI / 180.0);
    if (mirror) CGContextScaleCTM(c, -1, 1);
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    BOOL swap = ((int)deg % 180) != 0;
    CGFloat contentW = swap ? h : w;
    CGFloat contentH = swap ? w : h;
    CGFloat scale = MAX(box.width / contentW, box.height / contentH);
    CGContextDrawImage(c, CGRectMake(-w * scale / 2, -h * scale / 2, w * scale, h * scale), img);
    CGContextRestoreGState(c);
}

// 1.0.7-17：**恢复源代码状态** —— 前置画面以画中画合成到后置照片上，只存一张。
// （1.0.7-14 按当时的要求改成了前后分开存；用户实测后要求回到源代码的画中画状态。）
- (UIImage *)composeShot {
    CGSize bs = g_backShot.size;
    if (bs.width < 1 || bs.height < 1) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:bs];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [g_backShot drawInRect:CGRectMake(0, 0, bs.width, bs.height)];
        CGSize fs = g_frontShot.size;
        if (fs.width < 1 || fs.height < 1) return;
        CGFloat pw = bs.width * 0.28;
        CGFloat ph = pw * fs.height / fs.width;
        CGFloat px = bs.width - pw - bs.width * 0.03;
        CGFloat py = bs.height - ph - bs.height * 0.03;
        CGRect pip = CGRectMake(px, py, pw, ph);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:pip cornerRadius:14];
        CGContextSaveGState(ctx.CGContext);
        [path addClip];
        CGContextTranslateCTM(ctx.CGContext, px + pw, py);
        CGContextScaleCTM(ctx.CGContext, -1, 1);
        [g_frontShot drawInRect:CGRectMake(0, 0, pw, ph)];
        CGContextRestoreGState(ctx.CGContext);
        [[UIColor whiteColor] setStroke];
        path.lineWidth = 4;
        [path stroke];
    }];
}

- (void)trySaveIfBothReady {
    if (!g_backShot || !g_frontShot) return;
    [self setStatus:@"正在合成…"];
    UIImage *composed = [self composeShot];
    g_backShot = nil;
    g_frontShot = nil;
    if (!composed) {
        [self setStatus:@"合成失败"];
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:composed];
    } completionHandler:^(BOOL success, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatus:success ? @"已保存到相册" : [NSString stringWithFormat:@"保存失败: %@", err.localizedDescription]];
        });
    }];
}

@end

// ---------------------------------------------------------------------------
// 1.0.7-5 · 相机侧入口（EchoReborn 版本）
//
// 与参考源码的三处差异：
//   1. 入口不再是浮在右上角的自建按钮，而是**插进相机顶部栏、「实况」图标左边**
//      （需求原文：「在相机的顶部的实况图标，左边加入一个图标就可以开启双摄」）；
//   2. 受设置页的 DualCamEnabled 门控 —— 关闭时不建按钮、也不做任何事；
//   3. 关键路径全部落 [DUALCAM] 日志到 EchoReborn 共用日志文件，坏了能查。
// ---------------------------------------------------------------------------
static NSString *const kERDualCamPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERDualCamEnabledKey = @"DualCamEnabled";
static const char *kERDualCamReloadNotification = "com.strive.echoreborn/ReloadPrefs";
static BOOL g_dualCamFeatureEnabled = NO;
static __weak UIView *g_topBarHost = nil;
static BOOL g_topBarDumpDone = NO;

static void DualCamLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [DUALCAM] %@\n", [NSDate date].description, message];
    // 1.0.7-9：**必须同时 NSLog**。相机 App 是沙盒进程，往
    // /var/mobile/Library/Logs 写很可能被拒 —— 1.0.7-5~8 在实机上「一条 [DUALCAM]
    // 都没有」，使整个排查变成盲打。NSLog 走统一日志，idevicesyslog / Console 都能
    // 看到，不依赖文件写权限。
    NSLog(@"[DUALCAM] %@", message);
    NSString *directory = @"/var/mobile/Library/Logs/EchoReborn";
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [directory stringByAppendingPathComponent:@"echoreborn.log"];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        // 沙盒拒绝写入时静默放弃 —— NSLog 已经留了底。
    }
}

// 读设置页写入的开关。**1.0.7-9 的重要修正**：相机 App 是沙盒进程，**很可能读不到**
// /var/mobile/Library/Preferences 里的这份 plist —— 而参考的 DualCamTweak 恰恰是
// 「不做任何门控」才在实机上出了按钮。所以这里按三级回退：
//   1) CFPreferences 正常读到 → 以它为准；
//   2) 读不到键（沙盒拒绝 / 键不存在）→ 再读一个 SpringBoard 落的标记文件；
//   3) 都不行 → **默认开**（宁可多显示一个按钮，也不能因为读不到偏好而永远没按钮
//      —— 那正是 1.0.7-5~8 一直没按钮的最可能原因）。
// 注意用 initWithSuiteName: 重建实例读磁盘最新值，不做 synchronize（那会把进程内存
// 里的旧值写回磁盘，覆盖用户刚改的设置 —— 本项目 0.5.x 踩过这个坑）。
static BOOL DualCamFeatureEnabled(void) {
    @try {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kERDualCamPrefsDomain];
        if ([defaults objectForKey:kERDualCamEnabledKey] != nil) {
            BOOL value = [defaults boolForKey:kERDualCamEnabledKey];
            DualCamLog(@"DUALCAM pref read OK -> %@", value ? @"ON" : @"OFF");
            return value;
        }
    } @catch (__unused NSException *exception) {
    }
    // 2) 标记文件（SpringBoard 侧开关时同步落盘，见 EchoReborn 主 tweak）
    NSString *flag = @"/var/mobile/Library/Logs/EchoReborn/dualcam_enabled";
    NSData *data = [NSFileManager.defaultManager contentsAtPath:flag];
    if (data) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        raw = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL value = raw.boolValue;
        DualCamLog(@"DUALCAM flag file read -> %@", value ? @"ON" : @"OFF");
        return value;
    }
    DualCamLog(@"DUALCAM pref UNREADABLE in this process -> assuming ON");
    return YES;
}

// 1.0.7-11：把安装流程的每一步结论**用通知名本身**发出去。
// Darwin 通知带不了数据，但名字可以区分状态；相机沙盒写不进日志文件，
// 而 SpringBoard 侧的主 tweak 会把这些名字代写进共用日志 —— 这是唯一可靠的
// 跨沙盒诊断通道。
//   off        = 双摄开关被读成「关」
//   notopbar   = 开关是开的，但在相机视图树里没找到顶部栏
//   installed  = 按钮已装上
static void DualCamPostState(NSString *state) {
    @try {
        notify_post([@"com.strive.echoreborn/dualcam.state." stringByAppendingString:state].UTF8String);
    } @catch (__unused NSException *exception) {
    }
}

static UIWindow *appWindow(void) {
    // 1.0.7-5：不走 UIApplication.keyWindow / .windows —— 两者已分别自 iOS 13 / 15
    // 弃用，而本 target 开 -Werror，直接编译失败。改走 scene 的 window 列表：
    // 相机进程里必然有一个前台 scene，第一条基本必然命中。
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive &&
            windowScene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
        if (windowScene.windows.count) return windowScene.windows.firstObject;
    }
    return nil;
}

// 在视图树里找相机顶部栏。两级发现：
//   1) 类名含 "TopBar"（旧启发式，实机证明在这台 iOS 上找不到）；
//   2) **几何发现**（1.0.7-16 新增）：位于屏幕顶部（y < 100）、高度 30–70、
//      宽度超过屏宽一半的视图 —— 顶部栏无论叫什么类名都满足这组几何特征。
// 都失败返回 nil，调用方再走 key-window 兜底。
static UIView *dualCamFindTopBar(UIView *root) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (queue.count && guard++ < 4000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"TopBar"]) return view;
        if (queue.count > 2000) continue;
        for (UIView *child in view.subviews) [queue addObject:child];
    }
    // 几何发现：宽 > 60% 屏宽、高 30–70、顶部 y < 100 的最上层视图
    CGFloat screenWidth = CGRectGetWidth(root.bounds);
    if (screenWidth < 1.0) return nil;
    for (UIView *view in root.subviews) {
        for (UIView *child in view.subviews) {
            CGRect f = child.frame;
            if (f.origin.y < 100.0 && CGRectGetHeight(f) >= 30.0 && CGRectGetHeight(f) <= 70.0 &&
                CGRectGetWidth(f) >= screenWidth * 0.5) {
                DualCamLog(@"DUALCAM topbar by geometry: %@", NSStringFromClass(child.class));
                return child;
            }
        }
        CGRect f2 = view.frame;
        if (view != root && f2.origin.y < 100.0 && CGRectGetHeight(f2) >= 30.0 && CGRectGetHeight(f2) <= 70.0 &&
            CGRectGetWidth(f2) >= screenWidth * 0.5) {
            DualCamLog(@"DUALCAM topbar by geometry(direct): %@", NSStringFromClass(view.class));
            return view;
        }
    }
    return nil;
}

// 找「实况」按钮：类名含 LivePhoto 优先，其次含 Live 且含 Photo。
static UIView *dualCamFindLivePhotoAnchor(UIView *topBar) {
    if (!topBar) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:topBar];
    NSInteger guard = 0;
    UIView *fallback = nil;
    while (queue.count && guard++ < 2000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        if ([name containsString:@"livephoto"]) return view;
        if (!fallback && [name containsString:@"live"] && [name containsString:@"photo"]) fallback = view;
        for (UIView *child in view.subviews) [queue addObject:child];
    }
    return fallback;
}

static UIImage *dualCamButtonImage(void) {
    // 候选符号逐个试（低版本缺某个 SF Symbol 时自动退下一个），全失败则退回文字。
    for (NSString *name in @[@"camera.on.rectangle", @"rectangle.on.rectangle",
                             @"square.on.square", @"camera.fill"]) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (image) return image;
    }
    return nil;
}

static void dualCamUpdateButtonAppearance(void) {
    if (!g_toggleBtn) return;
    g_toggleBtn.tintColor = g_dualCamOn ? [UIColor systemYellowColor] : [UIColor whiteColor];
    g_toggleBtn.accessibilityLabel = g_dualCamOn ? @"关闭双摄" : @"开启双摄";
}

// 把按钮摆到「实况」图标左边。每次布局都调用（幂等），因此不用依赖任何一次性时机。
// 1.0.7-16：宿主可能是整棵 key window（兜底路径），此时锚点在深层容器里，
// 必须用 convertRect 把锚点换算到宿主坐标系，不能直接用 anchor.frame。
static void dualCamLayoutButton(void) {
    if (!g_toggleBtn || !g_topBarHost) return;
    if (g_toggleBtn.superview != g_topBarHost) {
        [g_toggleBtn removeFromSuperview];
        [g_topBarHost addSubview:g_toggleBtn];
    }
    UIView *anchor = dualCamFindLivePhotoAnchor(g_topBarHost);
    CGFloat height = 32.0;
    CGFloat width = 32.0;
    CGFloat gap = 8.0;
    CGRect frame;
    BOOL anchored = NO;
    if (anchor) {
        // 锚点换算到宿主坐标系（跨层级安全），并做合理性检查：
        // 只接受「在宿主可见范围内」的锚点，防止把按钮摆到屏幕外。
        CGRect anchorRect = [g_topBarHost convertRect:anchor.bounds fromView:anchor];
        if (!CGRectIsNull(anchorRect) && CGRectIntersectsRect(anchorRect, g_topBarHost.bounds)) {
            frame = anchorRect;
            frame.origin.x = CGRectGetMinX(anchorRect) - width - gap;
            frame.size = CGSizeMake(width, height);
            frame.origin.y = CGRectGetMidY(anchorRect) - height * 0.5;
            anchored = YES;
        }
    }
    if (!anchored) {
        // 没有实况图标可对齐（不同版本布局不同）——摆到顶部栏右上角内侧，
        // 至少保证功能可用；同时把顶部栏的子视图类名 dump 一次，供下一轮精确对齐。
        frame = CGRectMake(CGRectGetWidth(g_topBarHost.bounds) - width - 12.0, 8.0, width, height);
        if (!g_topBarDumpDone) {
            g_topBarDumpDone = YES;
            NSMutableArray *names = [NSMutableArray array];
            for (UIView *child in g_topBarHost.subviews) {
                [names addObject:NSStringFromClass(child.class)];
            }
            DualCamLog(@"DUALCAM topbar children (anchor missing): %@",
                       [names componentsJoinedByString:@", "]);
        }
    }
    if (!CGRectEqualToRect(g_toggleBtn.frame, frame)) g_toggleBtn.frame = frame;
    // 真·顶部栏里按钮保持透明（融入顶栏）；只有 key-window 兜底模式才上芯片底
    if (![g_topBarHost isKindOfClass:[UIWindow class]]) g_toggleBtn.backgroundColor = UIColor.clearColor;
    dualCamUpdateButtonAppearance();
    [g_topBarHost bringSubviewToFront:g_toggleBtn];
}

static void dualCamInstallIntoTopBar(UIView *topBar) {
    if (!topBar) return;
    g_topBarHost = topBar;
    if (!g_toggleBtn) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImage *image = dualCamButtonImage();
        if (image) {
            [btn setImage:image forState:UIControlStateNormal];
        } else {
            [btn setTitle:@"双摄" forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        }
        btn.tintColor = [UIColor whiteColor];
        [btn addTarget:[DualCamToggleTarget class]
                action:@selector(toggle)
      forControlEvents:UIControlEventTouchUpInside];
        g_toggleBtn = btn;
        DualCamLog(@"DUALCAM installed top-bar button in %@", NSStringFromClass(topBar.class));
    }
    dualCamLayoutButton();
}

// 门控总入口：开关打开就找顶部栏装按钮；关掉就把按钮摘掉。
static void dualCamRefreshInstallation(void);
static void dualCamApplyWindowFallbackLayout(UIWindow *window);

static void dualCamRefreshInstallation(void) {
    BOOL enabled = DualCamFeatureEnabled();
    if (enabled != g_dualCamFeatureEnabled) {
        DualCamLog(@"DUALCAM feature %@", enabled ? @"ENABLED" : @"DISABLED");
        g_dualCamFeatureEnabled = enabled;
    }
    if (!enabled) {
        if (g_toggleBtn) {
            [g_toggleBtn removeFromSuperview];
            g_toggleBtn = nil;
        }
        g_topBarHost = nil;
        DualCamPostState(@"off");
        return;
    }
    UIView *host = g_topBarHost;
    if (!host || !host.window) host = dualCamFindTopBar(appWindow());
    if (host) {
        dualCamInstallIntoTopBar(host);
        DualCamPostState(@"installed");
        return;
    }
    // 1.0.7-16：**key-window 兜底**。实机日志证明「类名 + 几何」都找不到顶部栏
    // （notopbar 刷屏）。按钮必须能出现——直接挂到 key window 顶部左侧，
    // 半透明深色芯片底保证任何背景下可见；拿到真实顶部栏类名后再精确锚定。
    UIWindow *window = appWindow();
    if (!window) {
        DualCamPostState(@"nowindow");
        return;
    }
    if (window.subviews.count == 0) {
        DualCamPostState(@"emptytree");
        return;
    }
    g_topBarHost = window;
    dualCamInstallIntoTopBar(window);
    dualCamApplyWindowFallbackLayout(window);
    DualCamPostState(@"fallback");
}

// 兜底布局（1.0.7-17 按用户截图标注的位置修正）：按钮放**右上角、实况图标旁边**——
// 在顶栏区域（y < 120、高 24–60、宽 24–60 的小视图）里找最靠右的那个图标，
// 按钮贴到它左边；一个都没找到就放右上角固定位。
// 用户明确要求「去掉图标外面的圆」—— 芯片底已移除，只保留图标本身。
static void dualCamApplyWindowFallbackLayout(UIWindow *window) {
    if (!g_toggleBtn || !window) return;
    CGFloat side = 34.0;
    CGFloat gap = 10.0;

    // 在 window 的两层子树里找顶栏区域最靠右的图标视图（坐标统一换算到 window）
    UIView *rightmost = nil;
    CGFloat bestMaxX = -1.0;
    CGFloat screenWidth = CGRectGetWidth(window.bounds);
    for (UIView *level1 in window.subviews) {
        NSArray<UIView *> *scan = @[level1];
        for (UIView *child in level1.subviews) scan = [scan arrayByAddingObject:child];
        for (UIView *view in scan) {
            if (view == g_toggleBtn) continue;
            CGRect f = [window convertRect:view.bounds fromView:view];
            if (f.origin.y > 120.0) continue;
            if (CGRectGetHeight(f) < 24.0 || CGRectGetHeight(f) > 60.0) continue;
            if (CGRectGetWidth(f) < 24.0 || CGRectGetWidth(f) > 64.0) continue;
            CGFloat maxX = CGRectGetMaxX(f);
            if (screenWidth > 1.0 && maxX > screenWidth * 0.75 && maxX > bestMaxX) {
                bestMaxX = maxX;
                rightmost = view;
            }
        }
    }

    CGRect frame;
    if (rightmost) {
        CGRect rightmostInWindow = [window convertRect:rightmost.bounds fromView:rightmost];
        frame = CGRectMake(CGRectGetMinX(rightmostInWindow) - side - gap,
                           CGRectGetMidY(rightmostInWindow) - side * 0.5, side, side);
        DualCamLog(@"DUALCAM fallback anchored left of %@ frame=%@",
                   NSStringFromClass(rightmost.class), NSStringFromCGRect(frame));
    } else {
        frame = CGRectMake(CGRectGetWidth(window.bounds) - side - 14.0, 64.0, side, side);
    }
    if (!CGRectEqualToRect(g_toggleBtn.frame, frame)) g_toggleBtn.frame = frame;
    g_toggleBtn.backgroundColor = UIColor.clearColor;   // 用户要求：去掉外面的圆
    g_toggleBtn.layer.cornerRadius = 0.0;
    g_toggleBtn.layer.masksToBounds = NO;
    dualCamUpdateButtonAppearance();
    [window bringSubviewToFront:g_toggleBtn];
}


static void toggleDualCam(void) {
    // 开关关闭时按钮本就不该存在；万一被别处调用也直接拒绝，避免「设置里关着但相机里
    // 还能进双摄」这种状态不一致。
    if (!g_dualCamFeatureEnabled) {
        DualCamLog(@"DUALCAM toggle ignored (feature disabled)");
        return;
    }
    if (!g_dualCamOn) {
        DualCamLog(@"DUALCAM opening (sessions=%lu)", (unsigned long)g_appSessions.count);
        for (AVCaptureSession *s in g_appSessions) {
            if (s.running) {
                [s stopRunning];
            }
        }
        g_dualCamOn = YES;

        if (!g_preview) g_preview = [[DualCamPreviewController alloc] init];
        if (!g_overlayWindow) {
            g_overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            g_overlayWindow.windowLevel = UIWindowLevelAlert + 1;
            g_overlayWindow.rootViewController = g_preview;
        }

        if (!g_preview.shutterButton) {
            g_preview = [[DualCamPreviewController alloc] init];
            g_overlayWindow.rootViewController = g_preview;
        }
        (void)g_preview.view;
        g_overlayWindow.hidden = NO;
        [g_overlayWindow makeKeyAndVisible];
        dualCamUpdateButtonAppearance();

        [g_preview startDualCam];
        // 双摄窗口接管后，顶部栏的宿主视图可能已不在 key window 上；
        // 退出时会重新解析，这里不需要额外处理。
    } else {
        DualCamLog(@"DUALCAM closing");
        [g_preview stopDualCam];
        g_overlayWindow.hidden = YES;
        g_dualCamOn = NO;
        dualCamUpdateButtonAppearance();
        for (AVCaptureSession *s in g_appSessions) {
            if (!s.running) [s startRunning];
        }
        // 回到相机页面：顶部栏会重新布局，借那次布局把按钮摆回去。
        dualCamRefreshInstallation();
    }
}

%hook AVCaptureSession

- (void)startRunning {
    if (!g_appSessions) g_appSessions = [NSHashTable weakObjectsHashTable];

    if (g_preview && [g_preview.session isEqual:self]) {
        %orig;
        return;
    }

    [g_appSessions addObject:self];

    if (g_dualCamOn) {
        return;
    }
    %orig;
}

- (BOOL)startRunningWithError:(NSError **)error {
    if (!g_appSessions) g_appSessions = [NSHashTable weakObjectsHashTable];

    if (g_preview && [g_preview.session isEqual:self]) {
        return %orig;
    }

    [g_appSessions addObject:self];

    if (g_dualCamOn) {
        if (error) *error = nil;
        return YES;
    }
    return %orig;
}

%end

// 相机顶部栏：每次布局都重算按钮位置。
// 为什么不写死「实况按钮的类名」：那是私有类，版本间会变。这里只按类名含
// "TopBar" 找顶部栏，再在它内部按类名含 LivePhoto 找锚点；找不到锚点时按钮
// 退到右上角内侧并 dump 一次子视图类名（见 dualCamLayoutButton）。
// **整个插入过程包 @try** —— 加一个按钮绝不能把相机 App 弄崩。
%hook CAMTopBar

// Logos 只给被 hook 的类生成一个**前向声明**（forward declaration），所以块里的
// `self` 是 `CAMTopBar *`：既不能与 `UIView *` 比较，也不能直接传给我们声明成
// UIView* 的函数（编译期报 comparison of distinct pointer types /
// no matching function for call / receiver ... is a forward declaration）。
// 统一在入口把它落到 `UIView *`，后面全用这个变量 —— 也不会因为「对前向声明的
// 类发消息」再报错。
- (void)layoutSubviews {
    %orig;
    UIView *topBar = (UIView *)self;
    @try {
        if (g_dualCamFeatureEnabled) {
            if (g_topBarHost != topBar) {
                g_topBarHost = topBar;
                DualCamLog(@"DUALCAM topbar hooked: %@", NSStringFromClass(topBar.class));
            }
            dualCamInstallIntoTopBar(topBar);
        }
    } @catch (NSException *exception) {
        DualCamLog(@"DUALCAM layout EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

- (void)didMoveToWindow {
    %orig;
    UIView *topBar = (UIView *)self;
    @try {
        if (g_dualCamFeatureEnabled) dualCamInstallIntoTopBar(topBar);
    } @catch (__unused NSException *exception) {
    }
}

%end

%ctor {
    @autoreleasepool {
        // 1.0.7-9：**必须显式 %init**。Logos 的规则是——写了 %ctor 就必须自己调 %init，
        // 否则所有 %hook 都不会初始化（参考源码正是因此它那个 AVCaptureSession hook
        // 其实从未生效，但它的按钮不依赖 hook，所以照样能用）。
        %init;
        DualCamLog(@"DUALCAM loaded (build %@)", kDualCamVersion);
        // 1.0.7-10：**心跳**。相机进程写日志文件可能被沙盒拒绝（1.0.7-5~9 实机上
        // 一条 [DUALCAM] 都没有的最合理解释），但 Darwin 通知**跨进程、跨沙盒**。
        // SpringBoard 侧的主 tweak 监听这条通知并代写日志 —— 只要心跳出现在共用
        // 日志里，就证明 dylib 已被加载进相机；一直没有，则问题在注入层。
        notify_post("com.strive.echoreborn/dualcam.heartbeat");
        dualCamRefreshInstallation();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                dualCamRefreshInstallation();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // 顶部栏有时要等首个布局循环才出现，补一次；仍然找不到会打日志。
                if (g_dualCamFeatureEnabled && (!g_topBarHost || !g_topBarHost.window)) {
                    dualCamRefreshInstallation();
                }
            });
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            notify_post("com.strive.echoreborn/dualcam.heartbeat");
            dualCamRefreshInstallation();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if (g_dualCamOn) toggleDualCam();
        }];

        // 设置页改开关后广播的重载通知：立刻生效，不需要重启相机。
        int token = 0;
        notify_register_dispatch(kERDualCamReloadNotification, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DualCamLog(@"DUALCAM reload notification");
            dualCamRefreshInstallation();
        });
    }
}
