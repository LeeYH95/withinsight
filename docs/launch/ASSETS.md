# 素材来源

本次宣传资料对应拾片 0.5.14，更新日期 2026-10-25。

- `docs/media/rope-native.png`、`editor-light.png`、`editor-dark.png`、`library-light.png`、`settings-light.png`、`new-menu.png`：由 `marketing/source/capture-native.swift` 使用当前原生界面类渲染导出。采用独立临时数据目录与虚构 DemoNotes，示例照片由本项目生成；没有读取个人闪念、桌面或其他应用窗口。Retina 输出保留原生控件，未重画界面。
- `docs/media/icon-light.png`、`icon-dark.png`：维护者确认的拾片独立品牌图标，原品牌图保持不变。应用系统图标另由 Icon Composer 编译，制作命令见 `scripts/make-brand-icons.py`。
- `Sources/Tendedero/Resources/Demo/*.png`、`NoteAtmosphere.png`：本项目独立生成的画廊、建筑演示图与柔和背景。
- Banner、三张功能图、社交预览：`marketing/source/visuals.html` 将上述图标与原生截图排版导出。复现命令见 `marketing/source/README.md`。
- MP4、封面与视频检查拼图：`marketing/videos/shipian` 源工程输出，已替换为当前编辑器与紧凑闪念库界面。视频是截图讲解动画，没有将其表述为实时操作录屏。
- `docs/media/shipian-preview.gif`：从同一份 32 秒视频转换，960×540、15 fps、无声音、循环播放。通过 `scripts/make-readme-gif.sh` 生成。
- 配乐：`build-film.py` 原创合成的和弦与钟琴音色，沿用原片音轨，没有使用第三方录音。
- 编辑器图标：Phosphor Icons，MIT 许可，声明见根目录 `PHOSPHOR-LICENSE.txt`。
- GSAP：官方 npm `gsap@3.14.2`，版权注释保留，适用 GSAP Standard License。根目录 MIT 许可不替代第三方库许可。

素材索引、尺寸及功能承诺对应源码见 `launch-manifest.json`。上游来源与品牌限制见 `NOTICE.md`。

## 0.5.15 清图控件素材

`Sources/Tendedero/Resources/LineControls/ClearScreenshots.png` 和 `ShortScreenshotPole.png` 为本项目独立设计、AI 辅助生成的透明控件素材，分别用于带 × 的小图片入口与短银色取图杆；不含个人截图或第三方品牌素材。显示时在内存裁切透明留白，保留原始 PNG。夹子使用现有原生 `Clothespin` 组件。
