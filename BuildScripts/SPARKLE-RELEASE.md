# macOS 版 Sparkle 自动更新：发版流程

报销整理 macOS 版自 2.1.0 起接入 Sparkle（2.10.1）：同事装过一次 2.1.0（种子版）后，后续版本由程序启动时自动检查、后台下载增量包、提示重启生效，不再需要逐人重发 DMG。

更新的信任链是 EdDSA 签名，与苹果代码签名相互独立：应用内置公钥（Info.plist 的 `SUPublicEDKey`），更新包与 appcast 条目用私钥签名，私钥只存在发布人的 Mac 上。

## 一次性准备（只做一次）

1. 下载与程序内相同版本的 Sparkle 工具包：
   https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
   解压后工具在 `bin/` 目录（`generate_keys`、`generate_appcast`、`sign_update`、`BinaryDelta`）。
2. 生成密钥对：
   ```sh
   ./bin/generate_keys
   ```
   - 私钥存入本机登录钥匙串（条目名类似 “Sparkle signing key”），**不要导出进仓库**；
   - 命令会打印公钥，把它填进 `Sources/Info.plist` 的 `SUPublicEDKey`，替换占位符后提交。占位符不替换，种子版的更新校验必然失败（程序其余功能不受影响）。
3. 另行备份私钥（换机或钥匙串丢失 = 再也签不出可信更新，全体同事需手动重装）：
   ```sh
   ./bin/generate_keys -x ~/SparkleKeyBackup
   ```
   把导出的 `sparkle_private_key` 文件放进密码管理器等安全位置保存，不要留在仓库目录里。

## 每个版本发版步骤

版本号规则：`CFBundleShortVersionString` 用语义版本（2.1.0、2.1.1、2.2.0…），`CFBundleVersion` 用与之对应的整数（210、211、220…），在 `Sources/Info.plist` 里两处一起改，必须单调递增——Sparkle 只按 `CFBundleVersion` 判断新旧。

1. 照常跑 `BuildScripts/build_native.sh` 出 .app 并打 DMG（DMG 继续作为首次安装与兜底分发方式）。
2. 为 Sparkle 准备更新包：把 .app 压成 zip，命名含版本号，放进一个**长期保留**的归档文件夹（例如 `~/SparkleArchives/`）。历次版本的 zip 都要留在里面，`generate_appcast` 靠它们生成相邻版本之间的增量（delta）包。
   ```sh
   ditto -c -k --sequesterRsrc --keepParent 报销整理.app ~/SparkleArchives/报销整理-2.1.0.zip
   ```
3. 生成 feed 与签名（私钥在钥匙串里，工具自动取用）：
   ```sh
   ./bin/generate_appcast --download-url-prefix "https://github.com/glasslessw1n/reimburse-app/releases/download/v2.1.0/" ~/SparkleArchives/
   ```
   注意 `--download-url-prefix` 里的标签与该版本 GitHub Release 的标签保持一致（mac 版历史标签为 `v2.0.0` 形式）。工具会在归档文件夹里写出 `appcast.xml`，并为旧版本生成 `.delta` 增量文件。
4. 在 GitHub 为新版本建 Release（标签如 `v2.1.0`），把归档文件夹里**本版新增**的文件传上去：本版 zip、以及所有指向本版的 `.delta` 文件。DMG 也可以一并挂上供手动下载。
5. 把第 3 步生成的 `appcast.xml` 覆盖仓库根目录的同名文件，提交并推送到 `main`。程序内 `SUFeedURL` 指向的正是这个文件；推送生效后，各客户端下次检查就能看到新版。
6. 顺序不要颠倒：先传 Release 文件、再推 appcast，避免客户端读到 feed 却下不到包。

## 种子版（2.1.0）上线前的必做验证

ad-hoc 签名 + Sparkle 的组合必须实测通过后才能分发种子版，不要跳过：

1. 装好 2.1.0（带真实公钥的正式构建），正常启动一次；
2. 按上面的流程把一个仅改版本号的 2.1.1 走完整发版（可以只挂到 Release 并推送 appcast，不必对外宣布）；
3. 重新启动 2.1.0，应当在后台检查到 2.1.1、下载（增量包）、提示更新，点更新后程序重启并变为 2.1.1，应用菜单里版本号正确；
4. 同时确认：应用菜单「报销整理 → 检查更新…」可点、设置与既有功能不受影响。

验证失败（签名校验报错、更新装不上）时不要分发种子版，把 Sparkle 的报错弹窗或控制台日志发回给开发方定位。
