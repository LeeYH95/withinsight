#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the established bundle ID so existing notes remain available.
notes_build_root="${LINENOTES_BUILD_OUTPUT_DIR:-$PWD/build}"
notes_output="${LINENOTES_RELEASE_OUTPUT_DIR:-$notes_build_root/shipian-release}"
LINENOTES_APP_NAME="拾片" LINENOTES_BUNDLE_ID="local.linenotes.test" \
LINENOTES_BUILD_OUTPUT_DIR="$notes_build_root" \
LINENOTES_VERSION="0.5.27" LINENOTES_BUILD="54" LINENOTES_BRAND_ICONS=1 scripts/build-dev-app.sh release
mkdir -p "$notes_output"
ditto "$notes_build_root/拾片.app" "$notes_output/拾片.app"
rm -f "$notes_output/拾片.app/Contents/Resources/ShipianDark.icns" "$notes_output/拾片.app/Contents/Resources/ShipianSystemIconLight.png" "$notes_output/拾片.app/Contents/Resources/ShipianSystemIconDark.png"
cat > "$notes_output/请先阅读.txt" <<'TEXT'
拾片 0.5.27 (54) · Apple Silicon · macOS 14+

双击 拾片.app 即可使用，也可拖到“应用程序”。
使用原 LineNotes Test 的独立应用身份，已有闪念会继续显示。
笔记及附件仍保存在 ~/Library/Application Support/LineNotes Test。
开启复制图片挂绳后，支持 Finder 单张或多张图片；挂上的是 PNG 副本，原图保留。
同图仍在绳上时去重，取下或清空后可以重新挂上；本应用复制的图片不重复收集。
新挂图片提供三秒撤销；编辑闪念时静默挂图。检测前已被覆盖的复制内容仍可能漏掉。
隔空投送图片自动挂上默认开启。允许访问「下载」后，拾片会挂上 macOS 标记为隔空投送的新图片。
如果隔空投送标记晚于文件写入，拾片会短暂复查该文件，确认来源后再挂上。
可在「偏好设置 → 截图」关闭隔空投送自动挂图。拾片会记住你的选择。
图片支持 Command / Ctrl 复制粘贴及从挂绳拖入；正文按松手位置插入，纸面空白处追加到末尾。
有序和无序列表支持快捷创建、自动编号及两级缩进；默认粘贴匹配光标格式。
多图缓存和布局已优化；图片预览支持适应窗口、原始像素、缩放、平移、复制与导出。
挂绳隐藏时暂停周期性微风，展开后摆动更快稳定；CPU 随内容与操作变化。
图片暂时读不到或仍在加载时保留路径和顺序，下次启动重试；原文件仍须可读。
内容统一称为“闪念”；编辑器右上角 × 关闭窗口，自动保存的内容仍保留。
底部保持单排图标；Aa 收纳段落样式、混合字号、粗体/斜体/下划线、列表和粘贴方式。
选中文字显示就近格式工具条，可调整段落、加粗、斜体、下划线及链接；按钮提供小手光标。
链接地址使用编辑区内的输入面板；悬停图片可调整宽度、替换图片和编辑说明，支持撤销。
正文支持连续选择；顶部显示比例仅改变阅读大小，不改原有文字字号。
连续纸面与单排圆润图标，常用字号 12 / 14 / 15（默认）/ 16 / 18 / 24。
正文粘贴单个完整 HTTP(S) 网址后，会访问网页读取标题，显示为融入正文的文字链接。
改进微信公众号文章和 YouTube 视频标题识别，富文本粘贴的原网址也可自动补全标题。
单击链接打开原网址，Command 点击同样可用；Option 点击定位编辑，拖动仍可选择文字。
读取失败或网页没有标题时，保留原网址。
保存重开、跨闪念复制和 Markdown 导出保留链接目标；混合正文和多个网址不自动替换标题。
闪念库预览根据卡片剩余高度显示更多正文和待办，超出后省略。
挂绳预览按正文区实际高度显示完整行，超出时在末行省略，短内容自然留白。
正文与待办按原顺序预览；长待办和多条待办继续显示，手动换行保持续行缩进。
闪念可拖动边缘调整尺寸，缩小时保留当前阅读位置。
底部右侧可直接选择纸张颜色；闪念库卡片与编辑器选色同步。
所有纸张选项均展示色块，新建按钮使用钴蓝，搜索框使用中性底色。
偏好设置使用五分类侧栏，标题前显示拾片图标，设置即时生效。
修正编辑区、挂绳缩略图及闪念库中勾选框与首行文字的基线对齐。
一级和二级待办的勾选框与正文对齐，编辑器和挂绳预览里的已完成待办会显示删除线。
统一选区高亮高度，长闪念首键响应更快，未编辑段落保留原有内容和格式。
从挂绳打开或收回闪念时，纸面仍沿原轨迹运动，正文在真实编辑窗口里淡入淡出，减少动作开始前的等待。
启动时资料就绪后直接打开窗口，减少固定等待。
有明确文字的按钮和闪念卡片不再重复显示 tooltip，图标入口保留必要提示。
显示缩放包含标题；旧内容保留已有文字大小和格式。
输入自动保存到本机，关闭窗口和更新版本后继续读取同一份资料。
异常退出时尝试自动找回已确认的输入；保存成功后清理临时内容。
不再创建完整历史备份，也没有手动备份或恢复管理入口。
最近删除支持一键清空；确认前展示总数量，默认取消，搜索隐藏的条目也计入范围。
闪念库默认 820×560，可手动缩放，顶部与筛选栏空白可拖动，按钮和搜索框保留原操作。
挂绳不会盖住当前拾片窗口及其确认框，切换应用时保留原有悬浮行为。
新建直接进入通用闪念，同一条可混排文字、图片、附件和待办。
绳尾新增带 × 的小图片入口，悬停可查看说明；点击后短银杆从左向右取下所有截图。
批量取下保留闪念、录像和原文件（含自有截图文件夹），完成后的撤销提示三秒后消失；启用减少动态效果时直接完成。
不要同时运行旧 LineNotes Test 和拾片；退出旧版本后再打开拾片。
原版 Tendedero 和 LineNotes Dev 不会被覆盖。

系统图标采用 Icon Composer 编译资产，修复 Dock 与启动器的额外灰色底板；设置中的 logo 保留原图。
图标已替换为确认的「拾片」白天版。夜间资源同时内置，应用运行时图标
和偏好设置中的品牌图标随应用的浅色/深色/跟随系统设置切换。
Finder 和未运行时的静态图标使用白天版，不宣称系统范围自动切换。
关闭窗口不会退出菜单栏应用，再次双击应用可重开闪念库。
截图监听与开机启动默认不开启；本次打包不会修改已有用户偏好。

本机 ad hoc 签名，未进行 Apple 公证。其他 Mac 从互联网下载后，
可能需要在系统设置中手动确认打开。
TEXT
# Remove debug symbols that retain absolute build-machine paths, then re-sign.
xcrun strip -S "$notes_output/拾片.app/Contents/MacOS/LineNotes"
python3 scripts/check-release-paths.py "$notes_output/拾片.app"
codesign --force --deep --sign - "$notes_output/拾片.app"
codesign --verify --deep --strict "$notes_output/拾片.app"
python3 scripts/check-brand-icons.py "$notes_output/拾片.app"
# Local app updates do not need duplicate ZIP/DMG artifacts.
if [[ "${SHIPIAN_APP_ONLY:-0}" == "1" ]]; then
    rm -rf "$notes_build_root/拾片.app"
    echo "Built $notes_output (App only)"
    exit 0
fi
ditto -c -k --sequesterRsrc --keepParent "$notes_output/拾片.app" "$notes_output/Shipian-0.5.27-arm64.zip"
notes_stage="$(mktemp -d "$notes_build_root/shipian-dmg-stage.XXXXXX")"
trap 'rm -rf "$notes_stage"' EXIT
ditto "$notes_output/拾片.app" "$notes_stage/拾片.app"
cp "$notes_output/请先阅读.txt" "$notes_stage/请先阅读.txt"
ln -s /Applications "$notes_stage/Applications"
hdiutil create -quiet -srcfolder "$notes_stage" -volname '拾片' -format UDZO -ov "$notes_output/Shipian-0.5.27-arm64.dmg"
(cd "$notes_output" && shasum -a 256 Shipian-0.5.27-arm64.zip Shipian-0.5.27-arm64.dmg) > "$notes_output/SHA256SUMS.txt"
# The signed distributable is canonical. Do not leave a second Launchpad-visible build copy.
rm -rf "$notes_build_root/拾片.app"
echo "Built $notes_output"
