# Settings 页面重构：左侧分类导航

## 概述
将 Settings 窗口改为左侧 sidebar + 右侧内容区布局，新增 Config 和 Prompt 两个分类，右键菜单增加三个直达入口。

## 涉及文件

| 文件 | 变更 |
|------|------|
| `Views/SettingsView.swift` | 重构：加 sidebar、分类枚举、Config/Prompt 视图 |
| `App.swift` | `openSettings` 支持指定分类；右键菜单加 3 项直达 |
| `CLAUDE.md` | 更新 UI Layout / Project Structure 描述 |
| `CHANGELOG.md` | 追加 [Unreleased] 条目 |

## 实施步骤

### Step 1: SettingsView.swift 重构

1. **新增 `SettingsCategory` 枚举** — `general / config / prompt`，带 icon (SF Symbol) 和 displayName

2. **重构 `SettingsView`**：
   - 接收可选的 `initialCategory` 参数（用于右键菜单直达）
   - `@State var selectedCategory` 控制当前分类
   - 布局：`HSplitView` 或 `HStack` — 左侧固定宽度 sidebar List，右侧内容区
   - Cancel/Save 按钮保留在右侧底部，Save 只保存当前分类

3. **Sidebar**：每行 = icon + 分类名，选中态高亮，类似 macOS System Settings

4. **GeneralSettingsView** — 保持现有内容不变

5. **ConfigSettingsView**（新增）：
   - `onAppear` 读取 `~/.claude/settings.json` 和 `~/.codex/config.toml`
   - 文件存在 → TextEditor 展示内容，可编辑
   - 文件不存在 → 显示提示信息（"File not found at ..."）
   - Save 时写回磁盘；JSON 做 `JSONSerialization` 校验，失败弹提示不保存

6. **PromptSettingsView**（新增）：
   - `onAppear` 读取 `~/.claude/CLAUDE.md` 和 `~/.codex/AGENTS.md`
   - 文件存在 → TextEditor 展示，可编辑
   - 文件不存在 → 显示提示信息
   - Save 时写回磁盘

7. **分类切换**：`onChange(of: selectedCategory)` 时重新从磁盘加载该分类的 draft 数据（丢弃未保存修改）

### Step 2: App.swift 修改

1. **`openSettings` 方法** 增加 `category` 参数（默认 `.general`）

2. **右键菜单** 增加三个直达项（在现有 Settings 项下方，用 submenu 或平铺）：
   - Settings → General（替换现有 Settings 项）
   - Settings → Config
   - Settings → Prompt
   实现为：把现有 "Settings" 改为带子菜单的项，3 个子项分别调用 `openSettings(category:)`

3. **窗口尺寸** 增大到约 850x580 以容纳 sidebar

### Step 3: 文档更新
- CLAUDE.md 的 UI Layout 和 Project Structure
- CHANGELOG.md [Unreleased]
