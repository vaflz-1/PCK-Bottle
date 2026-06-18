<div align="center">

# 🍶 PCK Bottle

在 macOS 上编辑 Godot `.pck` 包，无需命令行。

[English](README.md) · [Русский](README.ru.md) · **中文**

[![macOS](https://img.shields.io/badge/macOS-10.13%2B-000000?logo=apple&logoColor=white)](../../releases/latest)
[![Universal](https://img.shields.io/badge/Universal-Intel%20%2B%20Apple%20Silicon-555)](../../releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Download](https://img.shields.io/badge/⬇%20下载-Releases-2ea44f)](../../releases/latest)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-支持-ff5e5b?logo=kofi&logoColor=white)](https://ko-fi.com/vaflz)

![PCK Bottle 编辑 Godot .pck](docs/screenshot-editor.png)

</div>

PCK Bottle 打开 Godot 游戏（`.app` 包或独立的 `.pck`），以文件树展示。把文件拖进去
即可添加或替换，查看改了什么，然后打包。也可以把文件从 `.pck` 中取回磁盘。它支持
Godot 3 和 Godot 4 的包以及其中的任意内容：纹理、场景、脚本、`.import` 数据、语言文件。

## ⬇️ 下载

1. 打开 [Releases](../../releases/latest) 页面，下载 `PCK Bottle.dmg`。
2. 打开 `.dmg`，把 **PCK Bottle.app** 拖进「应用程序」文件夹。

Apple 未公证此构建（采用 ad-hoc 签名），所以首次启动时 Gatekeeper 会提示应用
「已损坏」或来自「身份不明的开发者」。清除一次下载隔离属性，提示便不再出现。

**打开「终端」：** 按 `⌘ 空格`，输入 `Terminal`，按 `Return`。在打开的窗口里粘贴这行
并按 `Return`：

```bash
xattr -dr com.apple.quarantine "/Applications/PCK Bottle.app"
```

之后即可像普通应用一样从访达或启动台打开。（右键点击应用并选「打开」也可以；终端
命令则总能奏效。）

### 🍺 或使用 Homebrew 安装

```bash
brew tap vaflz-1/tap
brew install --cask pck-bottle
```

若 macOS 拦截首次启动，用上面的 `xattr` 命令清除一次隔离属性即可。之后用
`brew upgrade --cask pck-bottle` 更新。

## ✨ 功能

- 打开 Godot **`.app`**（自动找到其中的 `.pck`）或独立的 **`.pck`**。
- 以文件树浏览包内容。
- 拖入文件或文件夹来暂存改动。目录层级保持不变，像 `translation/` 这样的外层文件夹
  会拆开，落到匹配的包路径上。
- 分组可折叠的「更改」面板（替换、添加、删除、复制）。在点击**「打包」**前不写入磁盘。
- 删除、复制、拷贝、粘贴、把行拖出到访达、提取文件到磁盘。
- 对每次改动支持撤销与重做（⌘Z / ⇧⌘Z），带动画。
- 每次打包都备份原文件，并可随时恢复。
- 按 Godot 的方式打包：正确的路径填充与按格式的数据对齐（Godot 3 为 16 字节，
  Godot 4 为 32 字节），并包含存放已导入纹理的隐藏目录 `.import` 与 `.godot`。
- 界面支持 English、Русский、中文，可从菜单栏切换。
- Intel 与 Apple Silicon 通用构建，macOS 10.13 及以上。

## 🚀 使用方法

1. 打开游戏：把它的 `.app` 或 `.pck` 拖到窗口，或用**文件 → 打开**。
2. 把 mod 文件夹拖到树上。对于翻译包，拖入 **`translation`** 文件夹；其中的
   `scenarios/`、`UI/`、`.import/` 会落到匹配的包路径上。
3. 检查「更改」面板，保持勾选**「备份原文件」**，点击**「打包更改」**。
4. 启动游戏。

### ↩️ 恢复原文件

勾选**「备份原文件」**后，每次打包都会先在包旁边写入带时间戳的
`<名称>.pck.<时间戳>.bak`。回滚方式：

- 在应用中选择**文件 → 从备份恢复…**（⇧⌘R），恢复最新的备份并重新加载包。
- 手动删除已修改的 `.pck`，把最新的 `.bak` 改名回原始名称
  （`Game.pck.1700000000000.bak` 改为 `Game.pck`）。

### 🌐 切换语言

打开菜单栏的 **「语言 (Language)」** 菜单，选择 English、Русский 或 中文。应用会记住
你的选择，否则跟随系统语言。

## 🔧 从源码构建

需要较新的 Xcode（Swift）工具链，以及带两个 Apple target 的 Rust。

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# 通用 .app（debug 或 release）：
CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh
# → macos/PCKBottle/build/PCK Bottle.app

# 可选的磁盘镜像：
bash macos/PCKBottle/scripts/make-dmg.sh

# Rust 核心测试：
cargo test --manifest-path crates/pck-core/Cargo.toml
```

构建会重映射本地路径并 strip 二进制，因此发布的 `.app` 不含主目录或用户名。

## 🧩 工作原理

| 路径 | 说明 |
|------|------|
| [`crates/pck-core`](crates/pck-core) | 共享 **Rust** 核心：PCK 扫描、读取、提取与原子重打包。以小巧的 `pck-core-cli` 形式打包进应用。 |
| [`macos/PCKBottle`](macos/PCKBottle) | 原生 macOS **AppKit** 应用，维护中的产品。 |
| [`legacy/`](legacy) | 旧的 Tauri/Vue 界面，仅作参考，不随应用发布。 |

应用是覆盖在内置 `pck-core-cli` 之上的轻量 AppKit 外壳，因此解析与重打包代码都集中
在一个 Rust crate 里。

## ❤️ 支持

PCK Bottle 是免费的。如果它帮你省了事，可以到
[ko-fi.com/vaflz](https://ko-fi.com/vaflz) 打赏一点。完全自愿。

## 📄 许可证

[Apache License 2.0](LICENSE)。
