# Third-Party Notices

本项目自身以 [MIT](LICENSE) 发布。Dukou 的 Swift 代码为独立编写，只依赖下面两个第三方组件。

## Sparkle 2.9.6 — MIT

Dukou 使用原版 Sparkle framework 提供签名更新检查与安装。Sparkle 的 MIT 许可、
版权声明及其所含外部组件声明完整保存在
`Resources/Licenses/Sparkle-LICENSE.txt`，并随 App 一同分发。

项目主页：<https://github.com/sparkle-project/Sparkle>

## Zstandard (zstd) 1.5.7 — BSD

读取微信本地数据库里的语音转文字（默认关闭）时，用 zstd 官方的单文件解码器解开微信压缩存放的消息。
`Sources/CZstd/zstddeclib.c` 由 facebook/zstd v1.5.7 的 `build/single_file_libs/combine.sh`
生成，`include/` 里是同一版本的 `zstd.h` 与 `zstd_errors.h`，未作修改；只编进 App，不链接系统或
Homebrew 里的库。zstd 以 BSD 与 GPLv2 双许可发布，Dukou 按 BSD 许可使用，许可全文见
`Sources/CZstd/LICENSE`，并作为 `Resources/Licenses/zstd-LICENSE.txt` 随 App 一同分发。

项目主页：<https://github.com/facebook/zstd>

## 商标

微信是腾讯公司的商标。Dukou 是独立项目，与腾讯无关联、未获其背书；它只接住微信自己通过系统共享服务交出的文件。
