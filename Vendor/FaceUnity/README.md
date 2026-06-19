# 相芯（FaceUnity）美颜接入 — 就差引擎二进制

对接代码已全部写好（见本目录）。**只差你从相芯后台下载 iOS SDK,把引擎和资源 bundle 放进来**,我就一键接通。

## ✅ 已就位
- `authpack.h` — 鉴权证书（变量 `g_auth_package`）
- `FUManager.h/.m` — OC 封装（鉴权 + 逐帧渲染 + 美颜参数）
- `FUBeautyRenderer.swift` — Swift 实现 BeautyRenderer，桥接 FUManager
- `Hily-Bridging-Header.h` — 桥接头

## ⬇️ 你需要从相芯下载并放入（缺这些无法编译）

到相芯后台/控制台下载 **iOS 原生 SDK 包**(就是发你 authpack 的那个项目),解压后取:

```
Vendor/FaceUnity/
├── authpack.h                 ✅ 已放
├── FURenderKit.xcframework     ⬅️ 放这里（SDK 包的 Frameworks/ 下）
└── bundles/
    ├── graphics.bundle             ⬅️ 放这里（SDK Resource/ 下，部分版本已内置可省略）
    ├── ai_face_processor.bundle    ⬅️ 放这里（人脸 AI 模型）
    └── face_beautification.bundle  ⬅️ 放这里（美颜资源）
```

> SDK 包里这些文件一般在 `Frameworks/`、`Resource/` 或 `bundle/` 目录下。找不到对应名字的就把整个 Resource 目录发我,我挑。

## 🔌 放好后我会做的（自动化）
1. `project.yml` 加:`FURenderKit.xcframework` 依赖(embed)、bundles 作为资源打包、桥接头设置
2. `FUManager.h/.m` + `FUBeautyRenderer.swift` 移入 `Sources/Beauty/`
3. `CameraManager` 默认 renderer 从 `PassthroughRenderer` 换成 `FUBeautyRenderer`
4. 按你实际 SDK 版本校准 OC 里的 API（类名/方法），`xcodegen generate` + 真机编译

## 交给我时
告诉我"SDK 已放到 Vendor/FaceUnity/",并附上 **FURenderKit 版本号**(如 8.9.0),我按实际头文件校准后接通。
