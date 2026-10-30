# 闪念编辑器优化 Implementation Plan

> **For agentic workers:** Use executing-plans for the shared integration and dispatching-parallel-agents for independent list editing and image preview work. Track verified results here.

**Goal:** 完成用户七项修复，验证混排编辑持久化与图片稳定性，更新现用本机拾片。

**Architecture:** 保持原生 NSTextView/TextKit 连续正文与现有 NotesCore 数据格式。列表变更集中在语义属性、编号归一化与键盘行为；图片输入统一经过自有附件导入；可见图片强引用与有界布局反馈防止重载循环。新预览视图复用 NotesTheme 与原图片附件操作。

**Tech Stack:** SwiftPM、AppKit、SwiftUI、XCTest，SSD 输出根 /Volumes/ZERO_SSD/Development/shipian/tasks/2026-10-31-editor-improvements。

## 验收与步骤

- [x] 列表：为数字空格识别、中间插入递增、两级缩进、Enter/Backspace、保存重开、剪贴板/Markdown 语义写回归并观察旧实现失败。实现 NotesListEditing，接入 NotesContinuousDocument、NotesContinuousTextView 和 Aa 菜单。
- [x] 图片输入：为标准图像剪贴板、单图对外复制、多图批量导入、挂绳文件拖放、匹配光标字号/去背景写回归并确认失败，修复相应输入路径。
- [x] 双图稳定性：构建隔离双图编辑器，测量真实布局/缓存重载次数及高度序列；定位后修复，重复滚动/重排并验证有界稳定。
- [x] 统一新建：更新 LineControl 与 NotesLibraryView，原存储兼容；原生按钮测试确认直接创建通用闪念。
- [x] 大图：新增 NotesImagePreview 及真实交互/布局验证，接入 NoteEditorView；复制、缩放、关闭、导出沿用可验证原生行为。
- [x] 集成：完整 Swift 测试与原生 UI harness；独立复核必要变更；构建本机 Release 候选，签名、图标、路径泄漏与来源文件检查。
- [x] 安装：正常退出当前 App；保存资料/偏好与旧包哈希；替换现用 App、校验候选一致与回退包；真实启动和原资料核对；交付 SSD 证据位置与剩余限制。

测试命令：将 CLANG_MODULE_CACHE_PATH、SWIFTPM_MODULECACHE_OVERRIDE 指向任务根 ModuleCache；swift test --scratch-path <任务根>/swift-build --disable-sandbox，聚焦测试后运行全套。禁止并发向同一 Swift scratch 构建。编译与临时证据均传递既有显式路径；Swift 系统启动小型临时文件仍由工具管理。

完成记录：272 项 XCTest 全部通过；原生 UI harness 通过；独立复核问题已关闭。0.5.19（27）已正常启动且原闪念库可见，安装/原包/资料/设置的核验见 SSD qa/。启动验收脚本写 SSD 报告曾在 Foundation open 阻塞；该诊断进程尚未进入 AppKit/资料加载，已仅结束精确诊断 PID，去掉诊断参数后正常启动。没有加入日常启动 SSD 检查；GitHub 未推送。
