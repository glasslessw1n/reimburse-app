# CI（待激活）

`windows.yml` 是 GitHub Actions 工作流：windows-latest 上跑 Core 全量测试 + WinUI App 构建。

当前它没有放在 `.github/workflows/` 下，是因为代为推送的 GitHub 集成没有 workflows
权限（推送 .github/workflows/ 路径会被 GitHub 以 403 拒绝）。激活只需一步，任选其一：

- 在 GitHub 网页上：把本目录的 windows.yml 内容粘贴为 `.github/workflows/windows.yml` 新建文件；
- 或本地 git：`git mv` / 复制到 `.github/workflows/windows.yml` 后正常 push。

激活后，feature/windows-app 等分支的每次推送都会自动验证 Core 测试与 App 编译。
