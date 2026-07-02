#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// 相芯美颜 OC 封装：鉴权初始化 + 逐帧渲染 + 美颜参数。
/// 用 OC 的原因：FURenderKit 是 OC SDK、authpack.h 是 C 数组，OC 直接用最省事，再桥接给 Swift。
@interface FUManager : NSObject

+ (instancetype)shared;

/// 全局初始化（鉴权 + 加载人脸模型 + 美颜模块），只需调用一次
- (void)setup;

/// 同步初始化（B 里程碑 spec §6.1）：返回 YES 表示鉴权+模型+美颜全部就绪；NO 则降级 PassthroughRenderer。
- (BOOL)setupSync;

/// 逐帧美颜渲染：输入相机 CVPixelBuffer，返回美颜后的 CVPixelBuffer
/// CF_RETURNS_NOT_RETAINED：返回的 buffer 归 FURenderKit 所有，调用方不持有 +1
- (CVPixelBufferRef)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer CF_RETURNS_NOT_RETAINED;

/// 更新美颜参数（均为 0~1）
- (void)updateBlur:(double)blur
            whiten:(double)whiten
        eyeEnlarge:(double)eyeEnlarge
          faceThin:(double)faceThin
           enabled:(BOOL)enabled;

// MARK: - K 里程碑（2026-07-02）：贴纸接入
// 参考 FULiveDemo (https://github.com/Faceunity/FULiveDemo) 的 sticker 加载模式：
// FUStickerContainer.removeAllSticks + addSticker:completion:（同时刻仅 1 张，对齐 H5 §3.4）

/// 加载贴纸 bundle。bundleName 为不含 .bundle 扩展名的资源名（如 "BlueMask" / "CatSparks"）。
/// 内部先 removeAllSticks 再 addSticker，保证同时刻只有 1 张贴纸。
/// 返回 NO：bundleName 为空 or bundle 未在 mainBundle 中找到（未拷入 Vendor/FaceUnity/bundles/stickers/）
- (BOOL)loadSticker:(nullable NSString *)bundleName;

/// 清除当前贴纸（等价 loadSticker:nil）
- (void)clearSticker;

@end

NS_ASSUME_NONNULL_END
