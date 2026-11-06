# 拾片 0.5.24（41）

在闪念正文粘贴一个网址后，拾片会读取页面标题，把网址显示成可点击的文字链接。这次改进了微信公众号文章、YouTube 视频和富文本链接的识别。

- 微信公众号文章可以从网页提供的标题信息中读取文章名。
- YouTube 视频和短链接优先读取视频标题。
- 从网页或文档复制的富文本链接，如果显示文字就是原网址，也会尝试补全标题。已有自定义文字的链接保留原样。
- 识别完成后保留原始跳转地址，包括 YouTube 链接里的起播时间。保存并重新打开闪念后，仍可点击标题访问原页面。
- 网页需要登录、限制访问或暂时无法读取时，保留可点击的原网址。

在原生闪念编辑器中，用真实微信文章和 YouTube 链接验证了粘贴、标题补全、原始地址和保存重开。

适用于 Apple Silicon 和 macOS 14 或更新版本。更新前请从菜单栏退出旧版拾片，再替换应用。新版沿用原有本机闪念资料。安装包采用 ad hoc 签名，未经过 Apple 公证。

- [DMG 安装包](https://github.com/LeeYH95/withinsight/releases/download/v0.5.24/Shipian-0.5.24-arm64.dmg)
- [ZIP 压缩包](https://github.com/LeeYH95/withinsight/releases/download/v0.5.24/Shipian-0.5.24-arm64.zip)
- [SHA-256 校验和](https://github.com/LeeYH95/withinsight/releases/download/v0.5.24/SHA256SUMS.txt)
