# Git 工作流规范

- Commit 格式：`<type>: [scope] <description>`
  - type: feat/fix/docs/dx/style/refactor/perf/test/workflow/build/ci/chore/types/wip/release
  - scope: 修改范围，全局用 [*]
  - 示例：feat: [直播] 新增 6s 心跳与强制下播分流
- 尽量保证每个 commit 只做一件事
- NEVER commit/push unless explicitly asked
- NEVER amend published commits
- NEVER force push 到主分支
- 工程文件（`*.xcodeproj`/`*.xcworkspace`）、`Pods/`、`.spm/`、相芯 framework/authpack 均不入库（见 `.gitignore`）；
  改了依赖只提交 `project.yml` / `Podfile` / `Podfile.lock`
- 分支命名：`feature/功能名`（新功能）、`hotfix/修复名`（紧急修复）
- 本仓库为新建工程，暂无远程；接入远程后再补主分支保护与发布流程
