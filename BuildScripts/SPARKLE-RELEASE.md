# macOS 版 Sparkle 自动更新：说明与发版流程

报销整理 macOS 版自 2.1.0 起接入 Sparkle（2.10.1）：同事装过一次 2.1.0（种子版）后，后续版本由程序启动时自动检查、后台下载增量包、提示重启生效，不再逐人重发 DMG。

## 先弄清一个概念（最容易搞混的地方）

更新永远是「**已安装的旧版本**读 feed，发现**更高版本**，下载安装」。所以：

- 给某个版本**本身**建 Release、把它写进 feed，对它自己没有任何作用——2.1.0 不会“更新到 2.1.0”；
- 要验证更新链是否通，必须再做一个更高版本（哪怕只改版本号，如 2.1.1），让 2.1.0 去升它；
- feed 里的下载地址必须指向**新版本文件实际存放的位置**，地址对不上，客户端读得到 feed 也下不到包。

本项目的存放约定（固定不变）：更新包（dmg 与增量 .delta）和 feed（`appcast.xml`）统一托管在**阿里云 OSS** 的 Bucket `reimbursment-macosupdate`（华东2·上海，公共读）根目录，只追加不删旧。程序内 `SUFeedURL` 指向 `https://reimbursment-macosupdate.oss-cn-shanghai.aliyuncs.com/appcast.xml`。选 OSS 是因为 GitHub 在国内网络可达性不稳定，同事端更新容易静默失败。仓库根目录与 main 上的 appcast.xml 是早期 GitHub 方案的遗留，不再被使用。

信任链是 EdDSA 签名，与苹果代码签名相互独立：应用内置公钥（Info.plist 的 `SUPublicEDKey`），更新包与 feed 条目用私钥签名，私钥只存在发布人 Mac 的钥匙串里。

## 一次性准备（均已于 2026-11-10 完成，仅作记录）

1. Sparkle 工具包 2.10.1 已下载解压（`generate_keys`、`generate_appcast` 在其 `bin/` 下）。
2. `./bin/generate_keys` 已生成密钥对：私钥在本机钥匙串（另有导出备份），公钥已填入 `Sources/Info.plist` 的 `SUPublicEDKey` 并入仓。私钥丢失 = 再也签不出可信更新，全体同事需手动重装，切记备份。
3. OSS Bucket `reimbursment-macosupdate` 已建好（2026-11-10）。可选再装 ossutil 并用 RAM 子账号密钥配置（仅授予该 Bucket 读写），发版脚本即可自动上传；不装则每次在控制台手动传。

## 种子版 2.1.0 怎么发

2.1.0 是种子版，**只需要把 DMG 发给同事安装**，不需要为它单独跑 appcast 流程。它与普通版本的区别仅在于：它是第一个内置 Sparkle 的版本，装上它的人从此能自动升级；还停留在 2.0.0 的人不会被自动升到 2.1.0（2.0.0 里没有 Sparkle），必须手动装这一次。

## 每个版本发版（脚本一条龙）

版本号规则：`CFBundleShortVersionString` 用语义版本（2.1.1、2.2.0…），`CFBundleVersion` 为对应整数（211、220…，即 X*100+Y*10+Z），脚本自动换算并写入，两者必须单调递增，Sparkle 只按 `CFBundleVersion` 判断新旧。

在仓库根目录执行：

```sh
bash BuildScripts/release_macos.sh 2.1.1
```

脚本自动完成：改版本号 → 构建并打 DMG → 以 ASCII 名 `Reimbursement-2.1.1.dmg` 归档到 `~/SparkleArchives/`（该目录须长期保留全部历史版本，增量包靠新旧对比生成）→ `generate_appcast` 生成带签名的 `appcast.xml` 与增量包 → 把增量包改成 ASCII 名并同步修正 appcast 里的地址 → 装有 ossutil 时自动上传（更新包先传、appcast 最后传）。

手动部分只剩：没装 ossutil 时按脚本末尾清单把文件传到 OSS；以及启动一个旧版本验证能发现并完成更新。

另建版本 Release（如 `v2.1.1`）把 DMG 挂上去供人手动下载也可以，但那与自动更新无关，不建也不影响更新。

## 种子验证清单（2.1.0 分发前必做，通过标准）

1. 本机装好 2.1.0 并能正常启动，菜单「报销整理 → 检查更新…」存在且可点；
2. 用脚本发一个仅改版本号的 2.1.1 并完成上传；
3. 启动 2.1.0 点「检查更新…」：应发现 2.1.1、下载（走增量包）、提示重启更新，更新后「关于」里版本为 2.1.1；
4. 三项全过才能把 2.1.0 DMG 发给同事；失败时把 Sparkle 的报错弹窗或控制台日志发回定位，不要分发。

## 已知坑

- **文件名必须 ASCII**：generate_appcast 用应用名给增量包命名（带中文），而 GitHub 会剥掉资产名中的中文导致地址对不上、下载 404（2026-11-10 在 GitHub 方案下实测踩中）。脚本已自动把增量包改名为 ASCII 并修正 feed 地址；归档的 dmg 同理一律用 `Reimbursement-<版本>.dmg`。
- **先传包、后推 feed**：顺序反了会出现客户端读到新版却下不到包的窗口期。
- **归档目录不能清**：`~/SparkleArchives/` 里少了任何一版，指向它的增量包就生成不出来（客户端会回退全量下载，不致命，但白下载几百 MB）。
