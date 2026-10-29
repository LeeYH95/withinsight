#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the established bundle ID so existing notes remain available.
notes_build_root="${LINENOTES_BUILD_OUTPUT_DIR:-$PWD/build}"
notes_output="${LINENOTES_RELEASE_OUTPUT_DIR:-$notes_build_root/shipian-release}"
LINENOTES_APP_NAME="拾片" LINENOTES_BUNDLE_ID="local.linenotes.test" \
LINENOTES_BUILD_OUTPUT_DIR="$notes_build_root" \
LINENOTES_VERSION="0.5.16" LINENOTES_BUILD="24" LINENOTES_BRAND_ICONS=1 scripts/build-dev-app.sh release
mkdir -p "$notes_output"
ditto "$notes_build_root/拾片.app" "$notes_output/拾片.app"
rm -f "$notes_output/拾片.app/Contents/Resources/ShipianDark.icns" "$notes_output/拾片.app/Contents/Resources/ShipianSystemIconLight.png" "$notes_output/拾片.app/Contents/Resources/ShipianSystemIconDark.png"
cat > "$notes_output/请先阅读.txt" <<'TEXT'
拾片 0.5.16 (24) · Apple Silicon · macOS 14+

双击 拾片.app 即可使用，也可拖到“应用程序”。
使用原 LineNotes Test 的独立应用身份，已有闪念会继续显示。
笔记及附件仍保存在 ~/Library/Application Support/LineNotes Test。
内容统一称为“闪念”；编辑器右上角 × 关闭窗口，自动保存的内容仍保留。
底部保持单排图标；Aa 收纳段落样式、混合字号、粗体/斜体/下划线、列表和粘贴方式。
正文支持连续选择；顶部显示比例仅改变阅读大小，不改原有文字字号。
连续纸面与单排圆润图标，常用字号 12 / 14 / 15（默认）/ 16 / 18 / 24。
正文粘贴单个完整 HTTP(S) 网址后，会访问网页读取标题，显示为融入正文的文字链接。
按住 Command 点击链接打开原网址；读取失败或网页没有标题时，保留原网址。
保存重开、跨闪念复制和 Markdown 导出保留链接目标；混合正文和多个网址不自动替换标题。
闪念可拖动边缘调整尺寸，缩小时保留当前阅读位置。
底部右侧可直接选择纸张颜色；闪念库卡片与编辑器选色同步。
所有纸张选项均展示色块，新建按钮使用钴蓝，搜索框使用中性底色。
偏好设置使用五分类侧栏，标题前显示拾片图标，设置即时生效。
修正编辑区、挂绳缩略图及闪念库中勾选框与首行文字的基线对齐。
有明确文字的按钮和闪念卡片不再重复显示 tooltip，图标入口保留必要提示。
显示缩放包含标题；旧内容保留已有文字大小和格式。
输入自动保存到本机，关闭窗口和更新版本后继续读取同一份资料。
异常退出时尝试自动找回已确认的输入；保存成功后清理临时内容。
不再创建完整历史备份，也没有手动备份或恢复管理入口。
最近删除支持一键清空；确认前展示总数量，默认取消，搜索隐藏的条目也计入范围。
闪念库默认 820×560，可手动缩放，顶部与筛选栏空白可拖动，按钮和搜索框保留原操作。
挂绳不会盖住当前拾片窗口及其确认框，切换应用时保留原有悬浮行为。
挂绳新建菜单补齐类型图标；菜单打开时保持挂绳可见，收起挂绳时同步关闭所属菜单。
绳尾新增带 × 的小图片入口，悬停可查看说明；点击后短银杆从左向右取下所有截图。
批量取下保留闪念、录像和原文件（含自有截图文件夹），完成后可撤销；启用减少动态效果时直接完成。
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
ditto -c -k --sequesterRsrc --keepParent "$notes_output/拾片.app" "$notes_output/Shipian-0.5.16-arm64.zip"
notes_stage="$(mktemp -d "$notes_build_root/shipian-dmg-stage.XXXXXX")"
trap 'rm -rf "$notes_stage"' EXIT
ditto "$notes_output/拾片.app" "$notes_stage/拾片.app"
cp "$notes_output/请先阅读.txt" "$notes_stage/请先阅读.txt"
ln -s /Applications "$notes_stage/Applications"
hdiutil create -quiet -srcfolder "$notes_stage" -volname '拾片' -format UDZO -ov "$notes_output/Shipian-0.5.16-arm64.dmg"
(cd "$notes_output" && shasum -a 256 Shipian-0.5.16-arm64.zip Shipian-0.5.16-arm64.dmg) > "$notes_output/SHA256SUMS.txt"
# The signed distributable is canonical. Do not leave a second Launchpad-visible build copy.
rm -rf "$notes_build_root/拾片.app"
echo "Built $notes_output"
