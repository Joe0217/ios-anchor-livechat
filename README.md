# Hily — 原生 iOS 主播端

H5 主播端（`anchor-livechat-h5`：1v1 通话、直播、PK、美颜、礼物收益）的 Swift 原生重建。
工程名 `ios-anchor-livechat`，App 显示名 **Hily**，bundleId `com.anchor.livechat`（相芯 authpack 绑定，不可改）。

> 本工程由验证级 POC 升级而来，已真机跑通核心链路；正在按里程碑演进为生产应用。

## 已打通链路

登录（AES 鉴权）→ 相机采集 → 相芯 FURenderKit 实时美颜 → Metal 预览 + 声网外部源推流 → 真实开播/心跳/下播 → 云信 IM 登录 + 聊天室（公屏/在线人数）。1v1 通话媒体走声网 `.communication`。

## 技术栈

- Swift 5 + SwiftUI，iOS 16，仅 iPhone（竖屏）
- 工程生成：xcodegen（`project.yml` → `.xcodeproj`）
- 依赖：CocoaPods（声网 `AgoraVideo_Special_iOS` 4.5.2.9.BASIC + 云信 `NIMSDK_LITE` 10.10.0）、embedded `FURenderKit.framework`（相芯）
- 美颜管线：相机(AVCaptureSession 前置/BGRA) → `BeautyRenderer`(相芯/直通可热替换) → `MetalPreviewView`(Metal+CoreImage)；前后皆 `CVPixelBuffer`，预览路径不变

## 运行步骤

```bash
# 1. 首次克隆：创建仅本地使用的配置文件并填入开发环境凭证
./bin/bootstrap.sh

# 2. 关闭 Xcode 后，重新生成工程、安装 Pods 并打开 workspace
./bin/regen.sh
```

需要 Xcode 16.1+、XcodeGen 和 CocoaPods。`Config/Config-*.xcconfig` 只保留在本机；从对应的
`.xcconfig.example` 创建文件后，向团队受控的凭证渠道取得实际值。切换环境使用
`./bin/switch-env.sh <dev|test|prod>`，它会调用 `regen.sh`。

`xcodegen generate` 必须与 `pod install` 成对执行。不要手动只运行前者；`regen.sh` 已处理这两个步骤。

在 Xcode 中：
1. 选中 target `Hily` → Signing & Capabilities → Team 选个人 Apple ID（免费即可）。
2. 顶部选**真机**（美颜/相机必须真机，模拟器无摄像头）。
3. ⌘R 运行。首次装机需在 iPhone「设置 → 通用 → VPN与设备管理」信任开发者证书。

## 文档

- `docs/plan/原生iOS接入技术文档-202606161955.md` — 声网/云信/相芯 接入细节、踩坑、待确认清单
- `AGENTS.md` — 面向自动化开发协作者的项目约束、验证与安全规则
