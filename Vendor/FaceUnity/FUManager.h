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

@end

NS_ASSUME_NONNULL_END
