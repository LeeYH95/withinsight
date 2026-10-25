# 宣传截图与静态主视觉

这里复用当前原生界面生成虚构演示内容，不采集桌面或用户资料。需要 macOS 桌面会话、Swift/Xcode 与 Python 3；先构建正式资源包，再导出截图：

```sh
scripts/build-release.sh
marketing/source/capture-native.sh
```

导出六张原生界面图到 `docs/media/`，数据使用临时目录，应用身份与正式版隔离。默认输出为 Retina 2 倍像素；脚本退出时清理临时应用与数据。

在仓库根目录安装排版工具并生成 Banner、功能图和社交预览：

```sh
npm ci --prefix marketing
npx --prefix marketing playwright install chromium
node marketing/source/render-visuals.cjs
```

也可通过 `CHROME_BIN` 指定已安装的 Chrome 可执行文件。`visuals.html` 只编排真实原生截图；产品窗口内容保持原样。原生图更新后，将视频使用的四张截图同步到 `marketing/videos/shipian/assets/`，再按该工程 README 检查和渲染。
