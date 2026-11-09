# CLI Updaters

在不同机器上安装或更新 Claude Code 与 Codex CLI。

## 快速使用

先下载脚本再运行，以保留交互菜单。以下命令适用于 Linux 和 macOS 的终端。

### Codex

```bash
curl -fsSL https://raw.githubusercontent.com/Einstore2015/cli-updaters/main/codex.sh -o /tmp/codex.sh \
  && bash /tmp/codex.sh
```

菜单可选择更新、安装或下载离线包。非交互环境默认更新，首次安装可明确指定 `install`。

```bash
# 首次安装
bash /tmp/codex.sh install --yes

# 更新，使用本机代理
bash /tmp/codex.sh update --proxy http://127.0.0.1:7897

# 下载适用于 Linux ARM64 的离线包
bash /tmp/codex.sh download --platform linux-arm64 --output . --yes

# 查看全部选项
bash /tmp/codex.sh --help
```

Codex 脚本提供：

- 当前版本检查、指定版本安装。
- 系统代理检测、自定义代理与直接连接。
- 官方下载源与 GitHub Releases 回退。
- 下载缓存复用与 SHA256 校验。
- 完整二进制包安装，保留搜索、沙箱等辅助程序。
- npm、Bun、Homebrew 安装的识别与对应更新。
- 安装验证、版本链接切换及切换失败后的回滚。
- Linux、macOS 和 Windows 目标平台的离线包下载；本机安装支持 Linux 和 macOS。

运行需要 Bash、`curl` 或 `wget`、`jq` 或 Python 3；完整包安装还需要 `tar`、gzip 和 SHA256 工具（`sha256sum`、`shasum` 或 `openssl`）。

### Claude Code

```bash
curl -fsSL https://raw.githubusercontent.com/Einstore2015/cli-updaters/main/claude.sh -o /tmp/claude.sh \
  && bash /tmp/claude.sh
```

`claude.sh` 是 [ipfred/cc-download](https://github.com/ipfred/cc-download) 优化脚本的入口，会获取并执行该项目 `master` 分支上的最新 `cc_download.sh`。它的菜单、安装与更新逻辑由上游项目维护。

## 代理

Codex 脚本会检测已有代理环境变量，也可以使用 `--proxy` 或 `--no-proxy`。若下载脚本本身也需要代理，在最外层 `curl` 中加入 `-x`：

```bash
curl -x http://127.0.0.1:7897 -fsSL \
  https://raw.githubusercontent.com/Einstore2015/cli-updaters/main/codex.sh \
  -o /tmp/codex.sh \
  && bash /tmp/codex.sh update --proxy http://127.0.0.1:7897
```

## 来源

- Claude Code 优化脚本：[ipfred/cc-download](https://github.com/ipfred/cc-download)。
- Codex 脚本参考其交互、代理、缓存、校验与直接更新流程，适配 Codex 官方完整安装包结构。
- Codex 安装与更新说明：[官方文档](https://learn.chatgpt.com/docs/codex/cli)。

本项目为个人维护的工具集合，与 Anthropic、OpenAI 均无官方关联。
