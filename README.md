# Claude & Codex Updater

安装或更新 Claude Code 和 Codex CLI，适用于 Linux / macOS。

在终端复制对应命令，运行后按菜单选择「更新」或「安装」即可。

## Claude Code

```bash
curl -fsSL https://raw.githubusercontent.com/Einstore2015/claude-codex-updater/main/claude.sh -o /tmp/claude.sh && bash /tmp/claude.sh
```

## Codex

```bash
curl -fsSL https://raw.githubusercontent.com/Einstore2015/claude-codex-updater/main/codex.sh -o /tmp/codex.sh && bash /tmp/codex.sh
```

首次使用请选择「安装」；已经装过请选择「更新」。

Claude 入口调用 [ipfred/cc-download](https://github.com/ipfred/cc-download)；Codex 脚本参考该项目的优化流程编写。
