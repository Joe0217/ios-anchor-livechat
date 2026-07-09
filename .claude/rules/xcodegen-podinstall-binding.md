# xcodegen + pod install 强制绑定

## 首选：`./bin/regen.sh` 一条龙脚本（Claude 遇到重生场景一律推荐此命令）

项目根 `bin/regen.sh` 已封装：**关 Xcode → `xcodegen generate` → `LANG=en_US.UTF-8 pod install` → sanity check → 打开 workspace**，并含 Xcode 弹窗处理提示（Revert / Cancel Update）。

**触发条件（命中任一即提示用户跑 `./bin/regen.sh`）**：
- 新增/删除 `.swift` 源文件（协作者或本次改动均适用）
- 改 `project.yml` 的 sources/dependencies/settings
- 改 `Podfile` / `Podfile.lock`
- 真机 build 报 `No such module 'AgoraRtcKit'` / `Search path XCFrameworkIntermediates not found` / `dyld: Library not loaded`
- 真机 build 报 `Switch must be exhaustive` 但源码 switch 已穷尽（pbxproj 缺文件 → 类型解析失败 → exhaustive 误报）
- 引用已存在的类型但编译报 `cannot find type ... in scope`（pbxproj 未登记新文件）

**Claude 操作纪律**：
- 检测到上述条件 → **一句话推荐：`请跑 ./bin/regen.sh`**，不再拆解三步骤教学
- **不擅自跑** —— 脚本会 kill Xcode，用户可能有未保存工作；等用户签字
- 若用户明示 "我关了 Xcode，帮我跑" → 用 Bash 调 `./bin/regen.sh`

## 规则（底层机制，理解用）

**每次跑 `xcodegen generate` 后必须立刻跟 `LANG=en_US.UTF-8 pod install`**，没有例外。`bin/regen.sh` 就是这个铁律的封装。

**Why**：xcodegen 由 project.yml 重写 `Hily.xcodeproj`，会清掉 `pod install` 加进去的：
- `[CP] Copy XCFrameworks` script phase
- `[CP] Embed Pods Frameworks` build phase
- Pods xcconfig 引用

漏跑直接命中：
- 编译期：`No such module 'AgoraRtcKit'` / `'NIMSDK'`
- 真机运行期：`dyld: Library not loaded: @rpath/...`
- Xcode 显示：`Search path '.../XCFrameworkIntermediates/*' not found`

**How to apply**：
- 任何任务里跑 `xcodegen generate` 都必须**当次合一**跟 `LANG=en_US.UTF-8 pod install`，作为单条 bash 命令用 `&&` 串联：
  ```bash
  xcodegen generate && LANG=en_US.UTF-8 pod install
  ```
- 命令行 `xcodebuild build` 可能因 DerivedData 旧缓存侥幸过——**不能**作为"修好了"的证据；必须 Xcode Clean Build 或真机 Build 实测
- 修 project.yml 源文件列表 / target settings / dependencies 任一项，回归路径必须包括 pod install

## ⚠️ Xcode 同时开着会让 pod install 静默失效（trial #3 真根因发现）

**症状**：明明跑了 `xcodegen generate && pod install` 都看到 "Pod installation complete!"，
用户 IDE Cmd+B 仍报 `No such module 'AgoraRtcKit'` + `Search path XCFrameworkIntermediates not found`。
检验：`grep -c PBXShellScriptBuildPhase Hily.xcodeproj/project.pbxproj` = 0 —— script phase 不在 pbxproj。

**真因**：Xcode 打开 workspace 时持有 .xcodeproj 文件 reference + 内存 cache。三方时序：
1. xcodegen 重写 pbxproj → Xcode 检测 external change → 弹"The project has been modified externally"
2. pod install 注入 `[CP] Copy XCFrameworks` / `[CP] Embed Pods Frameworks` script phase
3. 用户切回 Xcode → 弹窗里点"Keep Xcode Version"（或后续 auto-save）→ **Xcode 用内存版本覆盖磁盘** → pod install 改动丢失
4. Build 时找不到 XCFrameworkIntermediates 路径（script phase 没注入）

**预防（必做）**：

跑 `xcodegen + pod install` **前**让用户关闭 Xcode（或至少 Hily.xcworkspace tab）：

```bash
# 1. 提示用户：先关闭 Hily.xcworkspace（让 Xcode 释放 .xcodeproj 内存 cache）
# 2. 我跑命令链：
xcodegen generate && LANG=en_US.UTF-8 pod install
# 3. Sanity check：验证 phase 注入 + 命令行 build 通
#    ⚠️ 不要用 `grep -c PBXShellScriptBuildPhase`——那数关键字次数（section start/end + 每 phase 1 次 isa），
#      count 4 = 2 phases、count 5 = 3 phases，非直观且易错判。
#    正确方法：数 `name = "[CP]` 出现的**唯一 phase 名**：
phase_names=$(grep 'name = "\[CP\]' Hily.xcodeproj/project.pbxproj | sort -u | wc -l | tr -d ' ')
if [ "$phase_names" -lt 2 ]; then
  echo "❌ Pods phase 注入不足 (unique names=$phase_names, 期望 ≥2)"
  echo "   检查 Xcode 是否还开着 workspace；关掉后再跑一次 pod install"
  exit 1
fi
# 4. 更硬的验证：直接跑一次命令行 build（Xcode IDE cache 独立于此路径）
xcodebuild build -workspace Hily.xcworkspace -scheme Hily \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
# 5. 跑完用户再 open Hily.xcworkspace 重新打开 + Clean Build Folder (Shift+Cmd+K)
```

**Hily target 里预期至少 2 个 CP phase**（CocoaPods 1.16 分工模型）：
- `[CP] Check Pods Manifest.lock`
- `[CP] Embed Pods Frameworks`

**Copy XCFrameworks 不在 Hily target**（**注意 CocoaPods 1.16 分工**）：CocoaPods 1.16+ 把 `[CP] Copy XCFrameworks` phase 加到 `Pods.xcodeproj` 里**每个 pod target**（AgoraVideo_Special_iOS / NIMSDK_LITE / AgoraRtm_OC_Special / YXArtemis_XCFramework），不加到 Hily target。查证方法：`grep 'Copy XCFrameworks' Pods/Pods.xcodeproj/project.pbxproj`（应 ≥ 3 处）。若 Pods.xcodeproj 里也没有，才是真挂。

**验证**：`grep 'Copy XCFrameworks' Pods/Pods.xcodeproj/project.pbxproj | wc -l` 应 ≥ 3

**Sanity check 有硬约束**：命令行 `xcodebuild build` **必须 SUCCEEDED**。命令行成功 + Xcode IDE 失败 = **纯 IDE cache 问题**（用户重新打开 workspace + Clean Build Folder 即可）。

## 与既有 CLAUDE.md 关联

CLAUDE.md "构建工作流" 段已写明此铁律：
> ⚠️ **xcodegen generate 后必须跟 pod install**：xcodegen 重写 .xcodeproj 会**清掉** `pod install` 加进去的
> `[CP] Copy XCFrameworks` script phase + Embed Frameworks phase；漏跑 pod install 直接 build
> 会得 `No such module 'AgoraRtcKit'` + 真机 `dyld: Library not loaded`，命令行 build 可能因
> DerivedData stale 缓存侥幸过、但 Xcode Clean Build 后立刻暴露

本规则独立成文是因为这是**最容易在多步任务中漏掉**的步骤，需要在每次 xcodegen 调用点显式自检。

## 历史教训

- 2026-06-24 H M0-9 / M1-12：跑 xcodegen 验证主 target build 没跟 pod install，用户真机 build 触发上述错误链，需要重新 pod install 修复
- 2026-06-25 trial #3 H-0：xcodegen + pod install 都跑了 3 次都看到 "Pod installation complete!"，但 Xcode 一直开着 workspace → 真机 Cmd+B 报 `No such module 'AgoraRtcKit'`。grep pbxproj 0 script phase。**真因**：Xcode IDE 持有 .xcodeproj 内存 cache 覆盖了磁盘 pod install 写入。本规则补"预防"段沉淀。
- 2026-07-02 K H5 对齐后 IDE build 挂：跑完 xcodegen + pod install + sanity check `grep -c PBXShellScriptBuildPhase = 4` 通过 → 结果 IDE Cmd+B 报 `Search path XCFrameworkIntermediates not found`。**发现 2 个 bug**：(1) sanity check 命令数关键字次数（section+isa）不是 phase 数量，count 4 实为 2 phases；(2) CocoaPods 1.16 分工模型下 Copy XCFrameworks 在 Pods.xcodeproj 各 pod target 里，**不在 Hily target 里**——旧规则以为 Hily target 里应有 Copy XCFrameworks 是错的。**真因**：命令行 `xcodebuild build` SUCCEEDED，Xcode IDE 错是纯 DerivedData/内存 cache 遗留（用户之前 Xcode 开着 workspace 时 build 过失败版本，cache 里存了 stale 状态）。修复：重启 Xcode + Clean Build Folder + 重 build。本规则补 sanity check 命令 + CocoaPods 1.16 分工说明。
