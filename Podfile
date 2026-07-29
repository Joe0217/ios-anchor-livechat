platform :ios, '16.0'

# 云信 NIM SDK 只有 CocoaPods 分发（无 SPM），与现有 SPM(声网)/embedded framework(相芯) 共存。
# 工作流：xcodegen generate 后需重新 pod install；构建用 Hily.xcworkspace。

# 打包环境切换新增的 Release-Test / Release-Dev configuration 必须显式声明为 release 型，
# 否则 CocoaPods 默认只为 Debug/Release 生成 xcconfig，新增 configuration 会缺 Pods 引用导致
# 真机 build 报 `No such module 'AgoraRtcKit'` / dyld not loaded。
project 'Hily.xcodeproj',
  'Debug' => :debug,
  'Release' => :release,
  'Release-Test' => :release,
  'Release-Dev' => :release

target 'Hily' do
  use_frameworks!
  pod 'NIMSDK_LITE', '~> 10.10.0'  # IM + 聊天室（V2NIMChatroomClient），不含多余 RTC
  # 声网视频 SDK：官方指定的专用包（含 AgoraRtcKit.xcframework），替代原 SPM AgoraRtcEngine_iOS。
  # 版本号必须精确写全 '4.5.2.9.BASIC'（.BASIC 被当 prerelease，用 ~> 或省略会命不中）。
  pod 'AgoraVideo_Special_iOS', '4.5.2.9.BASIC'
  # 声网 RTM2 专版：1v1 通话信令（VideoCall/Cancel/Accept/Reject/Hangup 五类 CallAction）。
  # ⚠️ 仅装 RtmKit subspec、跳过 RtmBasic：RtmBasic 与 AgoraVideo_Special_iOS 都带
  # aosl.xcframework（同名不同二进制冲突），二者同代号下复用 RTC 的 aosl 即可。
  pod 'AgoraRtm_OC_Special/RtmKit', '~> 2.2.6'
  # 礼物特效引擎：SVGA 动效播放 + EVA（yylive/YYEVA-iOS）高性能 MP4 特效播放
  # ⚠️ YYEVA 最新是 1.1.42，无 1.2+/1.4 系列（`pod search YYEVA` 2026-07-09 验证），
  # 别按语义化推 `~> 1.4`（会命不中）；锁 `~> 1.1.42` 保守；升 2.x 前需重跑 pod search 验证。
  pod 'SVGAPlayer', '~> 2.5'
  pod 'YYEVA', '~> 1.1.42'
  # 数数 ThinkingData：统一事件、用户身份和即时 flush，配置由本机 xcconfig 注入。
  pod 'ThinkingSDK', '~> 3.4.6'
end

# ⚠️ SVGAPlayer 2.5.x upstream bug（截至 2026-07）：Svga.pbobjc.m 用 OSAtomicCompareAndSwapPtrBarrier
# 但未 import <libkern/OSAtomic.h>；Xcode 16 + iOS 18 SDK 起 implicit function declaration 由
# warning 升级为 error → SVGAPlayer 编译失败 → Hily main target 级联挂 → tests 全部跑不了。
#
# 两条同时打：
#   (1) 关 implicit declaration 报 error（治 c99 严格模式那部分）
#   (2) 用 -include libkern/OSAtomic.h 强制预注入头（治 module import + 类型冲突那部分）
# 这样不改 pod 源码，pod install 重跑不会丢配置。详见 github.com/svga/SVGAPlayer-iOS 未修 issue。
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      # ⚠️ Xcode 14+ 移除 libarclite（旧 ARC 兼容库，仅 iOS < 11 需要）；若某 pod 的 podspec 声明
      # IPHONEOS_DEPLOYMENT_TARGET < 11.0，真机 build 会报
      #   "SDK does not contain 'libarclite' at ... libarclite_iphoneos.a"
      # 修复：全局拉平到 iOS 16（对齐主 target 的 deploymentTarget，避免真机 build 挂）
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
    if target.name == 'SVGAPlayer'
      target.build_configurations.each do |config|
        config.build_settings['GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS'] = 'NO'
        cflags = config.build_settings['OTHER_CFLAGS'] || '$(inherited)'
        cflags = [cflags, '-include', 'libkern/OSAtomic.h'].join(' ')
        config.build_settings['OTHER_CFLAGS'] = cflags
      end
    end
  end

  # 2026-07-13 YYEva regionMode 强制忽略 mp4 effectInfo（座驾特效左右颠倒修复）：
  # H5 端座驾 mp4 内嵌的 yyeffectmp4json metadata (rgbFrame/alphaFrame) 与实际像素布局标反了：
  # metadata 声明"左 RGB 右 Alpha"，但 chroma variance 实测左半灰度、右半彩色。
  # H5 web yyeva.js 默认不读 mp4 metadata（除非显式传 dataUrl）反而歪打正着；iOS Pod 忠实读了错的
  # metadata → 走 maskFragmentSharder 通用路径按错的 rgbFrame/alphaFrame 采样 → 座驾灰白无色。
  # 本 patch 让 SDK 判定 hasValidEffectInfo 时加一个闸门：仅 region == NoSpecify 时才允许走 metadata
  # 路径；业务显式设 region (LGRC=3 / LCRG=2 / TCBG=4 / TGBC=5) → 忽略 metadata，走固定 shader。
  # 配合 Swift 侧 YYEVAAnimationPlayer.makePlayer 里 p.regionMode = .LGRC(3) 一起使用。
  # ⚠️ Idempotent marker: patch 后独有子串 `self.playAssets.region == YYEVAColorRegion_NoSpecify`
  # ⚠️ anchor miss 用 raise fail-fast：SDK 微改（换行/空格/refactor）时 pod install 直接失败，
  #     不静默 ships (对齐红队 A · Pod patch 稳定性要求)
  yyeva_alpha_render = File.expand_path('Pods/YYEVA/YYEVA/Classes/Render/YYEVAVideoAlphaRender.m', __dir__)
  # ⚠️ File.exist? 失败与内层 anchor content miss 对称 fail-fast（对齐 code-review 建议）：
  # SDK 未来若重排目录（如 Classes/Render/ → Sources/Render/）会静默 skip patch → 座驾颜色反转 bug 悄悄回归。
  unless File.exist?(yyeva_alpha_render)
    raise "[Podfile] YYEva 目标源码文件不存在: #{yyeva_alpha_render} — SDK 目录重排后需人工重对齐 anchor（当前锁 ~> 1.1.42）"
  end
  content = File.read(yyeva_alpha_render)
  marker = 'self.playAssets.region == YYEVAColorRegion_NoSpecify'
  unless content.include?(marker)
    original = "                             !CGRectIsEmpty(effectInfo.alphaFrame);"
    replacement = "                             !CGRectIsEmpty(effectInfo.alphaFrame) &&\n" \
                  "                             self.playAssets.region == YYEVAColorRegion_NoSpecify;"
    if content.include?(original)
      content.sub!(original, replacement)
      # ⚠️ pod cache clean 后重下载的 tarball 里文件权限可能是 read-only (0444) → File.write 报
      # Permission denied。显式 chmod 让文件可写；已可写则 no-op。
      File.chmod(0o644, yyeva_alpha_render)
      File.write(yyeva_alpha_render, content)
      puts '[Podfile] ✅ YYEva regionMode patched OK'
    else
      raise "[Podfile] YYEva regionMode patch anchor MISSING at YYEVAVideoAlphaRender.m — SDK 升级后需人工重对齐 anchor（当前锁版本 ~> 1.1.42）"
    end
  end
end
