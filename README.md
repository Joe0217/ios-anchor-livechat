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
# 1. 生成 Xcode 工程
xcodegen generate

# 2. 安装/集成 Pods（涉及 Pod 变更时）
LANG=en_US.UTF-8 pod install

# 3. 打开（必须用 workspace，否则云信找不到模块）
open Hily.xcworkspace
```

在 Xcode 中：
1. 选中 target `Hily` → Signing & Capabilities → Team 选个人 Apple ID（免费即可）。
2. 顶部选**真机**（美颜/相机必须真机，模拟器无摄像头）。
3. ⌘R 运行。首次装机需在 iPhone「设置 → 通用 → VPN与设备管理」信任开发者证书。

## 文档

- `docs/plan/原生iOS接入技术文档-202606161955.md` — 声网/云信/相芯 接入细节、踩坑、待确认清单
