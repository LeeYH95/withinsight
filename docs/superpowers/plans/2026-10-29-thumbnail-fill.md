# Thumbnail Fill Implementation Plan

> **For agentic workers:** Use executing-plans for inline execution. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 挂绳预览按实际高度显示完整行，溢出时末尾省略，并更新现用 App。

**Architecture:** 保持原 SwiftUI 标题和纸面。用原生文本排版处理正文/勾选框的连续内容及末行截断，使几何约束来自实际预览区；不改存储模型。

**Tech Stack:** SwiftUI、AppKit、XCTest。

## Task 1: 复现真实渲染缺陷

**Files:** `Tests/LineIntegrationTests/NoteThumbnailTests.swift`

- [x] 用 `NoteThumbnail.image(for:)` 渲染虚构长文，断言正文区域底部仍有完整行文字，而不是固定五行后留白。
- [x] 用长待办验证超过两行仍继续排版，多条待办验证超过两条仍可见。
- [x] 用正文后接待办的笔记验证首段未被过滤；用短内容验证底部正常留白。
- [x] 在已核验 SSD scratch/cache 下运行 `swift test --filter NoteThumbnailTests`，保存预期失败与基线图。

## Task 2: 按实际几何约束截断

**Files:** `Sources/Tendedero/NoteThumbnail.swift`；必要时同目录增加仅负责正文布局的小文件。

- [x] 移除 `checks.prefix(2)` 和 `.lineLimit(5)`，按 `note.blocks` 顺序构造连续正文；没有文字时使用原占位说明。
- [x] 在现有纸面内获取实际可用尺寸，原生排版只显示完整行，最后可见行还有后文时添加省略号。
- [x] 待办保持状态图形、首行对齐和续行缩进，不使用拉大文字或行距来填充空间。
- [x] 运行新测试及 `ChecklistAlignmentTests`，输出虚构浅色、深色、长文、待办和混合预览，实际查看像素结果后修正。

## Task 3: 验收及现用 App 更新

**Files:** 本任务文档；现用 App 原路径（仅安装阶段）。

- [x] 完整 `swift test` 和 `Tests/NativeNotesUIHarness/run.sh`；显式指定 SSD 输出、模块缓存及编译 scratch。
- [x] SSD 上构建 Release 候选，沿用 `local.linenotes.test` 和当前资源，版本 0.5.17（25）；签名和路径检查通过。
- [x] 正常退出旧版，保存资料内容/偏好校验基线和旧 App 回退包；安装候选到原路径并正常启动。
- [x] 校验安装未改笔记内容、附件及偏好，确认新进程与真实挂绳效果；用户开始编辑后的保存与启动锁文件另记。
- [x] 仅提交本任务文件；记录 SSD 实际输出、必要本机 App/回退包及工具管理的小型系统临时例外。本机安装阶段未发布 GitHub。

## 验收结果

完整测试 230 项与原生 UI harness 通过。独立复核发现的待办硬换行缩进/段距及测试外观隔离已修正并复核。当前 App 已安装 0.5.17（25），原笔记、附件、偏好核对一致。真实缩略图函数已用虚构数据输出并查看长文、多待办、深色和硬换行结果；安装后的原闪念库可见。工具尝试打开挂绳菜单时报告外部 UI 状态变化，已停止额外窗口操作，挂绳现场效果留给用户直接试用。

## 后续发布阶段

用户实际试用后已确认效果正常，并于 2026-10-29 要求更新到 GitHub。公开版本说明及下载入口见 [0.5.17 更新说明](../../launch/RELEASE-0.5.17.md)。
