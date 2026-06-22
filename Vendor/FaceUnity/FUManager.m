#import "FUManager.h"
#import "authpack.h"
@import FURenderKit;

// 注意：以下 API 基于相芯 Nama iOS SDK 8.x。不同 SDK 版本类名/方法可能略有差异，
// 接入时以你下载到的 FURenderKit 头文件和官方 FULiveDemo 为准，我会按实际版本校准。

@interface FUManager ()
@property (nonatomic, strong) FUBeauty *beauty;
@property (nonatomic, assign) BOOL didSetup;
@end

@implementation FUManager

+ (instancetype)shared {
    static FUManager *m = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ m = [[FUManager alloc] init]; });
    return m;
}

- (void)setup {
    [self setupSync];
}

- (BOOL)setupSync {
    if (self.didSetup) return self.beauty != nil;
    self.didSetup = YES;

    @try {
        // 1) 鉴权 + 初始化
        FUSetupConfig *config = [[FUSetupConfig alloc] init];
        config.authPack = FUAuthPackMake((void *)g_auth_package, (int)sizeof(g_auth_package));
        [FURenderKit setupWithSetupConfig:config];

        // 2) 加载人脸 AI 模型
        NSString *aiFacePath = [[NSBundle mainBundle] pathForResource:@"ai_face_processor" ofType:@"bundle"];
        if (!aiFacePath) return NO;
        [FUAIKit loadAIModeWithAIType:FUAITYPE_FACEPROCESSOR dataPath:aiFacePath];
        [FUAIKit shareKit].maxTrackFaces = 1;

        // 3) 美颜模块
        NSString *beautyPath = [[NSBundle mainBundle] pathForResource:@"face_beautification" ofType:@"bundle"];
        if (!beautyPath) return NO;
        FUBeauty *beauty = [[FUBeauty alloc] initWithPath:beautyPath name:@"FUBeauty"];
        if (!beauty) return NO;
        [FURenderKit shareRenderKit].beauty = beauty;
        self.beauty = beauty;
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[FUManager] setupSync exception: %@", exception);
        return NO;
    }
}

- (CVPixelBufferRef)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    FURenderInput *input = [[FURenderInput alloc] init];
    input.pixelBuffer = pixelBuffer;
    // 相机已设为竖屏、前置镜像
    input.renderConfig.imageOrientation = FUImageOrientationUP;
    input.renderConfig.isFromFrontCamera = YES;
    input.renderConfig.isFromMirroredCamera = YES;
    FURenderOutput *output = [[FURenderKit shareRenderKit] renderWithInput:input];
    return output.pixelBuffer ? output.pixelBuffer : pixelBuffer;
}

- (void)updateBlur:(double)blur
            whiten:(double)whiten
        eyeEnlarge:(double)eyeEnlarge
          faceThin:(double)faceThin
           enabled:(BOOL)enabled {
    if (!self.beauty) return;
    self.beauty.blurLevel    = enabled ? blur * 6.0 : 0;  // 磨皮 0~6
    self.beauty.colorLevel   = enabled ? whiten : 0;      // 美白 0~1
    self.beauty.eyeEnlarging = enabled ? eyeEnlarge : 0;  // 大眼 0~1
    self.beauty.cheekThinning = enabled ? faceThin : 0;   // 瘦脸 0~1
}

@end
