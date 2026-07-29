#import "FUManager.h"
#import "authpack.h"
@import FURenderKit;

// 注意：以下 API 基于相芯 Nama iOS SDK 8.x。不同 SDK 版本类名/方法可能略有差异，
// 接入时以你下载到的 FURenderKit 头文件和官方 FULiveDemo 为准，我会按实际版本校准。

@interface FUManager ()
@property (nonatomic, strong) FUBeauty *beauty;
@property (nonatomic, assign) BOOL didSetup;
@property (atomic, assign) BOOL faceDetected;
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
    // 必须在 renderWithInput 之后读取：FaceProcessor 在本帧 render 过程中更新检测结果。
    // Swift 侧轮询发生在主线程，不能跨线程直接调用相芯 C API。
    self.faceDetected = fuFaceProcessorGetNumResults() > 0;
    return output.pixelBuffer ? output.pixelBuffer : pixelBuffer;
}

- (BOOL)hasFaceDetected {
    return self.beauty != nil && self.faceDetected;
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

// MARK: - 贴纸接入（K 里程碑 2026-07-02）

- (BOOL)loadSticker:(NSString *)bundleName {
    // 空/nil → 清除当前贴纸（同 clearSticker 语义）
    if (!bundleName || bundleName.length == 0) {
        [self clearSticker];
        return YES;
    }
    // 查 bundle 路径：主 bundle 中查找 <bundleName>.bundle
    // 用户 workflow：把相芯 demo 的 sticker bundle 拷到 Vendor/FaceUnity/bundles/stickers/
    // + project.yml 里 `- path: Vendor/FaceUnity/bundles/stickers, buildPhase: resources`
    NSString *path = [[NSBundle mainBundle] pathForResource:bundleName ofType:@"bundle"];
    if (!path) {
        NSLog(@"[FUManager] sticker bundle not found: %@ (需拷 bundle 到 Vendor/FaceUnity/bundles/stickers/ + project.yml 加 resources)", bundleName);
        return NO;
    }
    FUSticker *sticker = [[FUSticker alloc] initWithPath:path name:bundleName];
    if (!sticker) {
        NSLog(@"[FUManager] FUSticker init failed: %@", bundleName);
        return NO;
    }
    // 同时刻只 1 张贴纸（H5 modules/03 §3.4 语义）
    FUStickerContainer *container = [FURenderKit shareRenderKit].stickerContainer;
    [container removeAllSticks];
    [container addSticker:sticker completion:nil];
    return YES;
}

- (void)clearSticker {
    [[FURenderKit shareRenderKit].stickerContainer removeAllSticks];
}

@end
