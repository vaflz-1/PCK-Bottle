<div align="center">

# 🍶 PCK Bottle

**原生 macOS 的 Godot `.pck` 包编辑器 —— 浏览、编辑、重新打包并安装 mod，无需终端。**

[English](README.md) · [Русский](README.ru.md) · **中文**

[![macOS](https://img.shields.io/badge/macOS-10.13%2B-000000?logo=apple&logoColor=white)](../../releases/latest)
[![Universal](https://img.shields.io/badge/Universal-Intel%20%2B%20Apple%20Silicon-555)](../../releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Download](https://img.shields.io/badge/⬇%20下载-Releases-2ea44f)](../../releases/latest)

</div>

PCK Bottle 可打开 Godot 游戏（`.app` 包或独立的 `.pck`），以类似 Finder 的树状结构
展示内容，让你拖入文件来添加或替换、在写入前预览改动、备份原文件并重新打包，
也可以把文件从 `.pck` 中提取回磁盘。

> 不仅仅是汉化/翻译安装器，而是面向 Godot PCK 的通用、Finder 风格的 mod 管理器
> —— 支持 **Godot 3 与 Godot 4** 包以及任意内容（纹理、场景、脚本、`.import`
> 数据、语言文件等）。

## ⬇️ 下载与安装

1. 在 [**Releases**](../../releases/latest) 页面获取最新的 **`PCK Bottle.dmg`**
   （或 `.app.zip`）—— 无需自行构建。
2. 打开 `.dmg`，把 **PCK Bottle.app** 拖到 `/Applications`。

构建采用 **ad‑hoc** 签名（未经 Apple 公证），因此首次启动时 macOS Gatekeeper 可能
提示应用“已损坏”或来自“身份不明的开发者”。执行一次以清除下载隔离属性：

```bash
xattr -dr com.apple.quarantine "/Applications/PCK Bottle.app"
```

……或右键点击应用 → **打开** → **打开**。（经过公证的版本可直接双击打开。）

## ✨ 功能

- 打开 Godot **`.app`**（自动发现其中的 `.pck`）或独立的 **`.pck`**。
- 以文件/文件夹树状结构浏览包内容。
- **拖放**文件或整个文件夹来暂存改动 —— 保留目录层级，并自动“拆包”像
  `translation/` 这样的分发外层目录，使其内容落到匹配的包路径上。
- 在可折叠分组的**「更改」**面板中审阅暂存内容（替换 / 添加 / 删除 / 复制）；
  在点击**「打包」**之前不会写入任何内容。
- **删除 / 复制 / 拷贝 / 粘贴**，把行**拖出到 Finder**，并**提取**选中文件到磁盘。
- 对每一次暂存改动支持**撤销 / 重做**（⌘Z / ⇧⌘Z），带动画。
- 自动**备份**原文件，并可随时**从备份恢复**（文件 → 从备份恢复）。
- 正确的 Godot 打包：忠实的流式重打包、按格式正确的路径填充与数据对齐
  （Godot 3 / Godot 4），并包含 Godot 的隐藏目录 `.import` / `.godot`（已导入纹理）。
- 界面本地化 —— **English / Русский / 中文** —— 可从菜单栏切换。
- 原生**通用**应用（Intel + Apple Silicon），macOS 10.13+。

## 🚀 使用方法

1. **打开**游戏：把游戏的 `.app` 或 `.pck` 拖到窗口，或使用**文件 → 打开**。
2. **暂存** mod：把它的文件夹拖到树上。对于翻译包，直接拖入 **`translation/`**
   文件夹 —— 其中的 `scenarios/`、`UI/`、`.import/` …… 会落到匹配的包路径。
3. **审阅**「更改」面板，保持勾选**「备份原文件」**，然后点击**「打包更改」**。
4. 启动游戏。若要还原，使用**文件 → 从备份恢复**。

## 🔧 从源码构建

需求：较新的 Xcode（Swift）工具链，以及带两个 Apple target 的 Rust。

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# 通用 .app（debug 或 release）：
CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh
# → macos/PCKBottle/build/PCK Bottle.app

# 可选的磁盘镜像：
bash macos/PCKBottle/scripts/make-dmg.sh

# 运行 Rust 核心测试：
cargo test --manifest-path crates/pck-core/Cargo.toml
```

Release 构建会重映射本地路径并 strip 二进制，因此发布的 `.app` 不含主目录或用户名。

## 🧩 工作原理

| 路径 | 说明 |
|------|------|
| [`crates/pck-core`](crates/pck-core) | 共享 **Rust** 核心：PCK 扫描、读取、提取以及安全的**原子**重打包。以小巧的 `pck-core-cli` 形式打包进应用。 |
| [`macos/PCKBottle`](macos/PCKBottle) | 原生 macOS **AppKit** 应用 —— 维护中的产品。 |
| [`legacy/`](legacy) | 已弃用的 Tauri/Vue 界面 + JS 测试，仅作参考，不随应用发布。 |

应用是一个轻量的 AppKit 外壳，调用内置的 `pck-core-cli`，因此所有与安全相关的
解析/重打包逻辑都集中在一个可审计的 Rust crate 中。

## 📄 许可证

[Apache License 2.0](LICENSE)。
