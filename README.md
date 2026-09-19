# 墨知 MoRead · iOS

面向 iPhone 和 iPad 的本地阅读器，基于 [MoRead](https://github.com/ovo066/MoRead) 的功能与数据规则移植。

当前为开发中的版本，最低支持 iOS 17。

- TXT、EPUB 导入，章节目录、书内搜索、书签与阅读进度保存。
- 多级分组、合集和彩色标签，组合筛选、拖动排序与批量归类。
- 字号、行距、纸张配色，以及荧光、下划线和波浪线批注。
- 系统连续听书、当前文字高亮、锁屏播放控制。
- 自填服务商地址、模型与密钥，支持 OpenAI 兼容、Responses、Claude、Gemini 四种聊天接口。
- SillyTavern JSON、PNG 角色卡与世界书，流式伴读、对话分支、原文引用和已读范围限制。
- 完整本地备份、恢复前校验、恢复内容预览和撤销上次恢复。

书籍和对话保存在设备中，服务商密钥保存在系统钥匙串。发送伴读消息时，所选服务商会收到角色资料、近期对话和检索到的已读原文。角色设定不能保证模型绝不剧透；原文检索按本地阅读边界截断。

<p><img src="docs/screenshots/txt-reading.png" alt="TXT 阅读界面" width="260"> <img src="docs/screenshots/epub-reading.png" alt="EPUB 阅读界面" width="260"></p>

## 开发

双击 `MoRead.xcodeproj`，在 Xcode 中打开工程并等待组件下载完成。顶部选择 `MoRead` 和一个 iPhone 模拟器，再点击三角形运行按钮。

安装到自己的 iPhone：

1. 在 Mac 打开 Xcode，完成首次启动设置，并在 Xcode 的 Settings → Accounts 中登录 Apple 账户。
2. 用数据线连接 iPhone，按手机提示信任这台 Mac。
3. 在工程左侧点击蓝色 `MoRead` 图标，选择 TARGETS 下的 `MoRead`，打开 Signing & Capabilities，在 Team 中选择自己的账户。
4. 在 Xcode 顶部设备列表选择这台 iPhone，点击三角形运行按钮。若手机要求启用“开发者模式”，按设备提示完成后再运行。

核心检查使用 `swift test`。`project.yml` 是工程配置，修改它后用 XcodeGen 执行 `xcodegen generate`。GitHub Actions 会构建 iPhone 应用，并在模拟器中检查 TXT 与 EPUB 阅读及重启后的进度恢复。云端产物未经个人账户签名，不能直接安装到手机。

## 来源与许可

本项目基于 [DataDeletionAZA/MoRead](https://github.com/DataDeletionAZA/MoRead)，参考版本 `2421731e4e29fc081b28cd7f89e2566095cc6513`。

按 [GPL-3.0](LICENSE) 发布，第三方来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
