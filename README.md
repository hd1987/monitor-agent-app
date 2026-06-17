<p align="center">
  <img src="icon.png" width="128" height="128" alt="Monitor Agent">
</p>

<h1 align="center">Monitor Agent</h1>

<p align="center">
  A lightweight macOS menu bar app that tracks your AI coding assistant usage.<br>
  Supports <strong>Claude Code</strong> and <strong>Codex</strong>.
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#screenshot">Screenshot</a> •
  <a href="#installation">Installation</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#中文说明">中文说明</a>
</p>

---

## Features

- **Menu bar native** — lives in your menu bar, one click to view stats
- **Zero configuration** — automatically reads local session logs, no API keys needed
- **Filter by app** — switch between All / Claude Code / Codex
- **Time range** — Today, 7 Days, 30 Days, or All Time
- **Stats at a glance** — Requests, Sessions, Input Tokens, Output Tokens, Cache Read, Cache Hit Rate
- **Activity heatmap** — GitHub-style yearly contribution graph with hover tooltips
- **Model distribution** — stacked bar showing usage across models (Opus, Sonnet, Haiku, GPT-5.5, etc.)
- **Auto-update** — built-in update checker with one-click download and install

## Screenshot

![Monitor Agent Screenshot](screenshot.png)

## Installation

### Download

Download the latest `MonitorAgent.zip` from [Releases](https://github.com/hd1987/monitor-agent-app/releases), unzip, and drag to `/Applications`.

> **First launch:** macOS will show *"MonitorAgent is damaged and can't be opened"* because the app is not code-signed. This is expected. Run this once in Terminal to fix it:
> ```bash
> xattr -cr /Applications/MonitorAgent.app
> ```

### Build from source

```bash
git clone https://github.com/hd1987/monitor-agent-app.git
cd monitor-agent-app
swift build -c release
```

## How It Works

Monitor Agent reads the JSONL session logs that Claude Code and Codex write locally:

| Source | Path |
|--------|------|
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` |

All data stays on your machine. Nothing is sent anywhere. The app stores parsed results in `~/.monitor-agent/monitor.db` and syncs incrementally every 30 seconds.

## Requirements

- macOS 14.0+
- Claude Code and/or Codex installed locally

## License

MIT

---

## 中文说明

<p align="center">
  一款轻量的 macOS 菜单栏应用，追踪你的 AI 编程助手使用情况。<br>
  支持 <strong>Claude Code</strong> 和 <strong>Codex</strong>。
</p>

### 功能

- **菜单栏常驻** — 点击图标即可查看统计
- **零配置** — 自动读取本地会话日志，无需 API Key
- **按工具筛选** — All / Claude Code / Codex 一键切换
- **时间范围** — 今日、7 天、30 天、全部
- **核心指标** — 请求数、会话数、输入 Token、输出 Token、缓存读取、缓存命中率
- **活动热力图** — GitHub 风格的年度活动图，悬停显示详情
- **模型分布** — 堆叠比例条展示各模型使用占比
- **自动更新** — 内置更新检查，一键下载安装

### 安装

从 [Releases](https://github.com/hd1987/monitor-agent-app/releases) 下载最新的 `MonitorAgent.zip`，解压后拖入 `/Applications` 即可。

> **首次启动：** macOS 会提示 *"MonitorAgent 已损坏，无法打开"*，这是因为应用未签名。在终端执行一次即可修复：
> ```bash
> xattr -cr /Applications/MonitorAgent.app
> ```

### 工作原理

Monitor Agent 读取 Claude Code 和 Codex 在本地生成的 JSONL 会话日志：

| 来源 | 路径 |
|------|------|
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` |

所有数据保留在本地，不会上传。解析结果存储在 `~/.monitor-agent/monitor.db`，每 30 秒增量同步。

### 系统要求

- macOS 14.0+
- 本地已安装 Claude Code 和/或 Codex
