#!/usr/bin/env bash
set -euo pipefail

# 参考 ipfred/cc-download 的交互、代理、缓存、校验和直接更新流程。
# 原项目：https://github.com/ipfred/cc-download
# Codex 使用完整官方安装包，保留 rg、沙箱及其他辅助程序。

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1，请先安装。"; }

usage() {
    cat <<'EOF'
用法：./codex.sh [update|install|download] [选项]

不带参数时显示菜单；没有终端时默认更新。
  update                 更新已安装的 Codex（默认）
  install                安装 Codex；已有安装时更新
  download               下载完整离线包和 SHA256 校验文件
  --version VERSION      latest（默认）或指定版本，如 0.166.0
  --platform PLATFORM    仅 download 可用：linux-x64、linux-arm64、
                         darwin-x64、darwin-arm64、win32-x64、win32-arm64
  --method METHOD        auto（默认）、standalone 或 npm
  --proxy URL            HTTP/HTTPS/SOCKS5 代理，如 http://127.0.0.1:7897
  --no-proxy             忽略系统代理，直接连接
  --output DIR           离线包保存目录（默认当前目录）
  -y, --yes              使用默认值，不显示交互菜单
  -h, --help             显示帮助

环境变量（可选）：
  CODEX_UPDATE_HOME          Codex 数据目录，默认沿用 CODEX_HOME 或 ~/.codex
  CODEX_UPDATE_INSTALL_DIR   新安装的命令目录，默认沿用 CODEX_INSTALL_DIR
                            或 ~/.local/bin；更新时优先沿用现有命令位置
  CODEX_UPDATE_CACHE_DIR     下载缓存目录，默认 <数据目录>/downloads

示例：
  ./codex.sh
  ./codex.sh update --proxy http://127.0.0.1:7897
  ./codex.sh install --version 0.166.0 --yes
  ./codex.sh download --platform linux-arm64 --yes
EOF
}

mode=""
requested_version="latest"
platform=""
method="auto"
proxy_mode="auto"
proxy_url=""
output_dir="$PWD"
interactive=true
task_tmp=""
stage_dir=""
partial_path=""
lock_kind=""
standalone_root=""
switch_started=false
switch_committed=false
visible_path=""
helper_path=""
had_visible=false
had_helper=false
old_current=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        update|install|download)
            [[ -z "$mode" ]] || die "只能指定一个运行模式。"
            mode="$1"; shift ;;
        --version|--platform|--method|--proxy|--output)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 需要一个值。"
            case "$1" in
                --version) requested_version="$2" ;;
                --platform) platform="$2" ;;
                --method) method="$2" ;;
                --proxy) proxy_mode="explicit"; proxy_url="$2" ;;
                --output) output_dir="$2" ;;
            esac
            shift 2 ;;
        --no-proxy) proxy_mode="direct"; shift ;;
        -y|--yes) interactive=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$1（使用 --help 查看帮助）。" ;;
    esac
done
[[ -t 0 && -t 1 ]] || interactive=false

ask() {
    local prompt="$1" default="$2" answer=""
    if [[ "$interactive" == true ]]; then
        read -r -p "$prompt" answer || true
    fi
    REPLY="${answer:-$default}"
}

if [[ -z "$mode" ]]; then
    if [[ "$interactive" == true ]]; then
        say $'\n选择运行模式：\n  1) update    更新 Codex（默认）\n  2) install   安装 Codex\n  3) download  下载离线安装包'
        ask '输入选项 [1/2/3]: ' 1
        case "$REPLY" in
            1) mode="update" ;; 2) mode="install" ;; 3) mode="download" ;;
            *) die "无效的运行模式。" ;;
        esac
    else
        mode="update"
    fi
fi

if [[ "$mode" != update && "$requested_version" == latest && "$interactive" == true ]]; then
    ask '版本 [latest，或输入指定版本号]: ' latest
    requested_version="$REPLY"
fi
requested_version="${requested_version#rust-v}"
requested_version="${requested_version#v}"
[[ "$requested_version" == latest || "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+){0,2})?$ ]] || die "版本号格式不正确。"
case "$method" in auto|standalone|npm) ;; *) die "安装方式应为 auto、standalone 或 npm。" ;; esac
[[ "$mode" == download || -z "$platform" ]] || die "--platform 仅用于下载离线包，安装时自动检测本机平台。"

need mktemp
if command -v jq >/dev/null 2>&1; then json_tool="jq"
elif command -v python3 >/dev/null 2>&1; then json_tool="python3"
else die "需要 jq 或 python3 来解析官方版本清单。"; fi
if command -v curl >/dev/null 2>&1; then downloader="curl"
elif command -v wget >/dev/null 2>&1; then downloader="wget"
else die "需要 curl 或 wget。"; fi

proxy_args=()
detected_proxy="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}"
if [[ "$proxy_mode" == auto && -n "$detected_proxy" ]]; then
    proxy_url="$detected_proxy"
    say '检测到系统代理，沿用当前设置。'
elif [[ "$proxy_mode" == auto && "$interactive" == true ]]; then
    say $'\n代理设置：\n  1) 本机 HTTP 代理（默认端口 7897）\n  2) 不使用代理（默认）\n  3) 输入代理 URL'
    ask '输入选项 [1/2/3]: ' 2
    case "$REPLY" in
        1)
            ask '代理端口 [7897]: ' 7897
            [[ "$REPLY" =~ ^[0-9]{1,5}$ ]] || die "代理端口无效。"
            (( 10#$REPLY > 0 && 10#$REPLY <= 65535 )) || die "代理端口超出范围。"
            proxy_url="http://127.0.0.1:$REPLY" ;;
        2) proxy_mode="direct" ;;
        3) ask '代理 URL: ' ''; proxy_url="$REPLY"; [[ -n "$proxy_url" ]] || die "代理 URL 不能为空。" ;;
        *) die "无效的代理选项。" ;;
    esac
fi
if [[ "$proxy_mode" == direct ]]; then
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    export npm_config_proxy='' npm_config_https_proxy=''
    if [[ "$downloader" == curl ]]; then proxy_args=(--proxy '')
    else proxy_args=(--no-proxy); fi
    say '使用直接连接。'
elif [[ -n "$proxy_url" ]]; then
    case "$proxy_url" in http://*|https://*|socks5://*|socks5h://*) ;; *) die "不支持的代理 URL。" ;; esac
    if [[ "$downloader" == wget && "$proxy_url" == socks* ]]; then die "SOCKS5 代理需要 curl。"; fi
    export http_proxy="$proxy_url" https_proxy="$proxy_url" HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url"
    if [[ "$downloader" == curl ]]; then proxy_args=(--proxy "$proxy_url"); fi
fi

fetch() {
    local url="$1" dest="$2" progress="${3:-false}"
    local timeout=30
    [[ "$progress" != true ]] || timeout=600
    if [[ "$downloader" == curl ]]; then
        local flags=(-fsSL)
        [[ "$progress" != true ]] || flags=(-fL --progress-bar --show-error)
        curl "${flags[@]}" "${proxy_args[@]}" --connect-timeout 10 --max-time "$timeout" --retry 2 -o "$dest" "$url"
    else
        local flags=(-q)
        [[ "$progress" != true ]] || flags=(--progress=bar:force)
        wget "${flags[@]}" "${proxy_args[@]}" --timeout=30 --tries=3 -O "$dest" "$url"
    fi
}

json_get() {
    local path="$1" key="$2" asset="${3:-}"
    if [[ "$json_tool" == jq ]]; then
        if [[ "$key" == digest ]]; then
            jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$path"
        else
            jq -er --arg key "$key" '.[$key] // empty' "$path"
        fi
    else
        python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
key, asset = sys.argv[2:4]
if key == "digest":
    value = next((a.get("digest") for a in data.get("assets", []) if a.get("name") == asset), None)
else:
    value = data.get(key)
if not isinstance(value, str) or not value:
    sys.exit(1)
print(value)
' "$path" "$key" "$asset"
    fi
}

sha256_file() {
    case "$hash_tool" in
        sha256sum) sha256sum "$1" | awk '{print tolower($1)}' ;;
        shasum) shasum -a 256 "$1" | awk '{print tolower($1)}' ;;
        openssl) openssl dgst -sha256 "$1" | awk '{print tolower($NF)}' ;;
    esac
}

atomic_link() {
    local target="$1" dest="$2" temp="${2}.codex-update.$$"
    [[ ! -d "$dest" || -L "$dest" ]] || return 1
    ln -s "$target" "$temp" || return 1
    if [[ "$os" == Darwin ]]; then
        mv -fh "$temp" "$dest" && return 0
    else
        mv -fT "$temp" "$dest" && return 0
    fi
    rm -f "$temp"
    return 1
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$switch_started" == true && "$switch_committed" == false ]]; then
        say '安装未完成，正在恢复原来的命令和版本选择。'
        if [[ -n "$old_current" ]]; then
            atomic_link "$old_current" "$standalone_root/current" || say '恢复版本链接失败。'
        else
            rm -f "$standalone_root/current" || true
        fi
        if [[ "$had_visible" == true ]]; then
            # 备份和命令同目录，rename 不会覆写运行中的可执行文件。
            if [[ "$os" == Darwin ]]; then mv -fh "$visible_backup" "$visible_path" || true
            else mv -fT "$visible_backup" "$visible_path" || true; fi
        else rm -f "$visible_path" || true; fi
        if [[ -n "$helper_path" ]]; then
            if [[ "$had_helper" == true ]]; then
                if [[ "$os" == Darwin ]]; then mv -fh "$helper_backup" "$helper_path" || true
                else mv -fT "$helper_backup" "$helper_path" || true; fi
            else rm -f "$helper_path" || true; fi
        fi
    fi
    [[ -z "${visible_backup:-}" ]] || rm -f "$visible_backup" || true
    [[ -z "${helper_backup:-}" ]] || rm -f "$helper_backup" || true
    [[ -z "$stage_dir" ]] || rm -rf "$stage_dir" || true
    [[ -z "$partial_path" ]] || rm -f "$partial_path" || true
    [[ -z "$task_tmp" ]] || rm -rf "$task_tmp" || true
    if [[ "$lock_kind" == mkdir ]]; then
        rm -f "$standalone_root/install.lock.d/pid" "$standalone_root/install.lock.d/started_at" || true
        rmdir "$standalone_root/install.lock.d" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

os="$(uname -s)"
arch="$(uname -m)"
case "$arch" in x86_64|amd64) arch="x64" ;; aarch64|arm64) arch="arm64" ;; *) die "不支持的架构：$arch" ;; esac
if [[ "$os" == Darwin && "$arch" == x64 && "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then arch="arm64"; fi
if [[ "$mode" == download && -z "$platform" && "$interactive" == true ]]; then
    say $'\n目标平台：\n  1) linux-x64\n  2) linux-arm64\n  3) darwin-x64\n  4) darwin-arm64\n  5) win32-x64\n  6) win32-arm64'
    ask '输入选项 [1-6，默认本机]: ' auto
    case "$REPLY" in
        1) platform="linux-x64" ;; 2) platform="linux-arm64" ;;
        3) platform="darwin-x64" ;; 4) platform="darwin-arm64" ;;
        5) platform="win32-x64" ;; 6) platform="win32-arm64" ;;
        auto) ;; *) die "无效的平台选项。" ;;
    esac
fi
if [[ -z "$platform" ]]; then
    case "$os" in Linux) platform="linux-$arch" ;; Darwin) platform="darwin-$arch" ;; *) die "本机安装仅支持 Linux 和 macOS。" ;; esac
fi
case "$platform" in
    linux-x64) target="x86_64-unknown-linux-musl" ;;
    linux-arm64) target="aarch64-unknown-linux-musl" ;;
    darwin-x64) target="x86_64-apple-darwin" ;;
    darwin-arm64) target="aarch64-apple-darwin" ;;
    win32-x64) target="x86_64-pc-windows-msvc" ;;
    win32-arm64) target="aarch64-pc-windows-msvc" ;;
    *) die "不支持的目标平台：$platform" ;;
esac

existing_path="$(command -v codex 2>/dev/null || true)"
if [[ "$mode" == update && -z "$existing_path" ]]; then die "未找到 codex，请选择 install 模式。"; fi
current_version=""
if [[ -n "$existing_path" && "$mode" != download ]]; then
    version_output="$("$existing_path" --version 2>/dev/null || true)"
    if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]]; then current_version="${BASH_REMATCH[1]}"; fi
    say "已安装位置：$existing_path"
    say "当前版本：${current_version:-未知}"
fi

# 包管理器安装沿用原方式，避免把 npm 启动器误当作原生二进制覆盖。
manager="standalone"
if [[ -n "$existing_path" && "$mode" != download ]]; then
    resolved_path="$existing_path"
    for (( link_depth=0; link_depth<40; link_depth++ )); do
        [[ -L "$resolved_path" ]] || break
        link_target="$(readlink "$resolved_path")"
        if [[ "$link_target" == /* ]]; then resolved_path="$link_target"
        else resolved_path="$(dirname "$resolved_path")/$link_target"; fi
    done
    [[ ! -L "$resolved_path" ]] || die "codex 命令的符号链接层数过多。"
    resolved_path="$(cd -P "$(dirname "$resolved_path")" && pwd)/$(basename "$resolved_path")"
    case "$resolved_path" in
        */.bun/*/node_modules/@openai/codex/*) manager="bun" ;;
        */node_modules/@openai/codex/*) manager="npm" ;;
        */Cellar/codex/*|*/Caskroom/codex/*) manager="brew" ;;
    esac
fi
if [[ "$mode" == install && -z "$existing_path" && "$method" == auto && "$interactive" == true ]]; then
    say $'\n安装方式：\n  1) 完整二进制包（默认）\n  2) npm'
    ask '输入选项 [1/2]: ' 1
    case "$REPLY" in 1) ;; 2) method="npm" ;; *) die "无效的安装方式。" ;; esac
fi
if [[ "$method" != auto ]]; then manager="$method"; fi

task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-update.XXXXXXXX")"
asset="codex-package-$target.tar.gz"
metadata="$task_tmp/release.json"
base_url="https://releases.openai.com/codex"
if [[ "$requested_version" == latest ]]; then
    primary_metadata="$base_url/channels/latest"
    fallback_metadata="https://api.github.com/repos/openai/codex/releases/latest"
else
    primary_metadata="$base_url/releases/$requested_version/release.json"
    fallback_metadata="https://api.github.com/repos/openai/codex/releases/tags/rust-v$requested_version"
fi
resolve_metadata() {
    local tag
    tag="$(json_get "$metadata" tag_name)" || return 1
    version="${tag#rust-v}"
    [[ "$tag" == rust-v* && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+){0,2})?$ ]] || return 1
    [[ "$requested_version" == latest || "$version" == "$requested_version" ]] || return 1
    if [[ "$mode" != download && "$manager" != standalone ]]; then return 0; fi
    digest="$(json_get "$metadata" digest "$asset")" || return 1
    [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || return 1
    checksum="$(printf '%s' "${digest#sha256:}" | tr 'A-F' 'a-f')"
}
say '获取官方版本清单…'
release_source="cdn"
if ! fetch "$primary_metadata" "$metadata" || ! resolve_metadata; then
    say '主下载源不可用或没有完整安装包，尝试 GitHub Releases…'
    release_source="github"
    fetch "$fallback_metadata" "$metadata" && resolve_metadata || die "无法获取版本/完整安装包的校验信息；可重试或指定较新版本。"
fi
say "目标版本：$version / $platform"
if [[ "$mode" != download && "$current_version" == "$version" ]]; then
    say "已是目标版本（$version），无需更新。"
    exit 0
fi

if [[ "$mode" != download && "$manager" != standalone ]]; then
    case "$manager" in
        npm) need npm; npm install -g "@openai/codex@$version" ;;
        bun) need bun; bun add -g "@openai/codex@$version" ;;
        brew)
            [[ "$requested_version" == latest ]] || die "Homebrew 不支持这里指定的版本，请使用 --method standalone。"
            need brew
            brew update
            brew upgrade --cask codex ;;
    esac
    actual_version="$(codex --version)"
    [[ "$actual_version" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) && "${BASH_REMATCH[1]}" == "$version" ]] || die "包管理器执行完成，但 PATH 中的 codex 版本不符：$actual_version"
    say "更新完成：${current_version:+$current_version -> }$version"
    exit 0
fi

need tar
if command -v sha256sum >/dev/null 2>&1; then hash_tool="sha256sum"
elif command -v shasum >/dev/null 2>&1; then hash_tool="shasum"
elif command -v openssl >/dev/null 2>&1; then hash_tool="openssl"
else die "需要 sha256sum、shasum 或 openssl。"; fi

codex_data_dir="${CODEX_UPDATE_HOME:-${CODEX_HOME:-$HOME/.codex}}"
cache_dir="${CODEX_UPDATE_CACHE_DIR:-$codex_data_dir/downloads}"
install_dir="${CODEX_UPDATE_INSTALL_DIR:-${CODEX_INSTALL_DIR:-$HOME/.local/bin}}"
if [[ "$mode" == download ]]; then
    mkdir -p "$output_dir"
    archive_path="$(cd "$output_dir" && pwd)/codex-$version-$platform.tar.gz"
else
    mkdir -p "$cache_dir"
    archive_path="$(cd "$cache_dir" && pwd)/codex-$version-$platform.tar.gz"
fi
primary_url="$base_url/releases/$version/$asset"
fallback_url="https://github.com/openai/codex/releases/download/rust-v$version/$asset"
if [[ "$release_source" == github ]]; then primary_url="$fallback_url"; fi

ensure_archive() {
    local url actual
    if [[ -f "$archive_path" ]]; then
        say '发现缓存，正在校验…'
        if [[ "$(sha256_file "$archive_path")" == "$checksum" ]]; then say '缓存校验通过，跳过下载。'; return 0; fi
        say '缓存校验不匹配，将重新下载。'
    fi
    partial_path="${archive_path}.part.$$"
    for url in "$primary_url" "$fallback_url"; do
        say "下载地址：$url"
        if fetch "$url" "$partial_path" true; then
            actual="$(sha256_file "$partial_path")"
            if [[ "$actual" == "$checksum" ]]; then
                mv -f "$partial_path" "$archive_path"
                partial_path=""
                say 'SHA256 校验通过。'
                return 0
            fi
            say "SHA256 不匹配（期望 $checksum，实际 $actual）。"
        fi
        rm -f "$partial_path"
        [[ "$primary_url" != "$fallback_url" ]] || break
        say '主下载源失败，尝试 GitHub Releases…'
    done
    die "下载或校验失败；当前安装未改动。"
}
ensure_archive

if [[ "$mode" == download ]]; then
    printf '%s  %s\n' "$checksum" "$(basename "$archive_path")" > "$archive_path.sha256"
    say "离线包：$archive_path"
    say "校验文件：$archive_path.sha256"
    say '复制到目标机器后，校验并解压完整目录，再运行 bin/codex（Windows 为 bin/codex.exe）。'
    say '例如：mkdir -p codex-offline && tar -xzf <离线包> -C codex-offline'
    exit 0
fi

standalone_root="$codex_data_dir/packages/standalone"
mkdir -p "$standalone_root/releases"
standalone_root="$(cd "$standalone_root" && pwd -P)"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$standalone_root/install.lock"
    flock -n 9 || die "另一个 Codex 安装进程正在运行，请稍后重试。"
    lock_kind="flock"
else
    mkdir "$standalone_root/install.lock.d" 2>/dev/null || die "安装锁已存在，请确认没有其他安装进程后重试。"
    lock_kind="mkdir"
    printf '%s\n' "$$" > "$standalone_root/install.lock.d/pid"
    date +%s > "$standalone_root/install.lock.d/started_at"
fi

release_dir="$standalone_root/releases/$version-$target"
package_complete() {
    local dir="$1" out exec_server
    [[ -f "$dir/codex-package.json" && -x "$dir/bin/codex" && -x "$dir/bin/codex-code-mode-host" && -x "$dir/codex-path/rg" ]] || return 1
    [[ "$(json_get "$dir/codex-package.json" version)" == "$version" ]] || return 1
    [[ "$(json_get "$dir/codex-package.json" target)" == "$target" ]] || return 1
    if [[ "$platform" == linux-* ]]; then [[ -x "$dir/codex-resources/bwrap" ]] || return 1; fi
    exec_server="$(json_get "$dir/codex-package.json" execServer || true)"
    if [[ -n "$exec_server" ]]; then [[ "$exec_server" == bin/codex-exec-server && -x "$dir/$exec_server" ]] || return 1; fi
    out="$("$dir/bin/codex" --version 2>/dev/null)" || return 1
    [[ "$out" == "codex-cli $version" ]]
}
if [[ -e "$release_dir" || -L "$release_dir" ]]; then
    package_complete "$release_dir" || die "版本目录已存在但不完整，请先检查：$release_dir"
    say '已存在完整的目标版本，复用安装目录。'
else
    stage_dir="$(mktemp -d "$standalone_root/releases/.staging.codex-update.XXXXXXXX")"
    tar -xzf "$archive_path" -C "$stage_dir"
    chmod 0755 "$stage_dir/bin/codex" "$stage_dir/bin/codex-code-mode-host" "$stage_dir/codex-path/rg"
    for helper in "$stage_dir/codex-resources/bwrap" "$stage_dir/bin/codex-exec-server"; do
        [[ ! -f "$helper" ]] || chmod 0755 "$helper"
    done
    ln -sf bin/codex "$stage_dir/codex"
    package_complete "$stage_dir" || die "安装包不完整、平台不符或版本验证失败。"
    mv "$stage_dir" "$release_dir"
    stage_dir=""
fi

if [[ -n "$existing_path" && -z "${CODEX_UPDATE_INSTALL_DIR:-}" ]]; then
    visible_path="$existing_path"
    install_dir="$(dirname "$visible_path")"
else
    mkdir -p "$install_dir"
    install_dir="$(cd "$install_dir" && pwd -P)"
    visible_path="$install_dir/codex"
fi
[[ ! -d "$visible_path" || -L "$visible_path" ]] || die "命令位置是目录：$visible_path"
[[ ! -e "$standalone_root/current" || -L "$standalone_root/current" ]] || die "current 不是符号链接，请检查：$standalone_root/current"
old_current="$(readlink "$standalone_root/current" 2>/dev/null || true)"
visible_backup="${visible_path}.codex-backup.$$"
if [[ -e "$visible_path" || -L "$visible_path" ]]; then
    cp -Pp "$visible_path" "$visible_backup"
    had_visible=true
fi
if [[ "$os" == Darwin ]]; then
    helper_path="$install_dir/codex-code-mode-host"
    [[ ! -d "$helper_path" || -L "$helper_path" ]] || die "辅助命令位置是目录：$helper_path"
    helper_backup="${helper_path}.codex-backup.$$"
    if [[ -e "$helper_path" || -L "$helper_path" ]]; then cp -Pp "$helper_path" "$helper_backup"; had_helper=true; fi
fi

# 只切换链接，正在运行的 Codex 及其完整旧目录保持可用。
switch_started=true
atomic_link "$release_dir" "$standalone_root/current" || die "切换版本失败。"
atomic_link "$standalone_root/current/bin/codex" "$visible_path" || die "更新命令链接失败。"
if [[ -n "$helper_path" ]]; then
    atomic_link "$standalone_root/current/bin/codex-code-mode-host" "$helper_path" || die "更新辅助命令链接失败。"
fi
[[ "$("$visible_path" --version)" == "codex-cli $version" ]] || die "更新后的命令验证失败。"

# 沿用官方自动更新标记；指定版本时取消跟随 latest。
if [[ "$requested_version" == latest ]]; then
    printf '%s' "$version-$target" > "$standalone_root/auto-update-version.tmp.$$"
    mv -f "$standalone_root/auto-update-version.tmp.$$" "$standalone_root/auto-update-version"
else
    rm -f "$standalone_root/auto-update-version"
fi
switch_committed=true
say "更新完成：${current_version:+$current_version -> }$version"
say "命令位置：$visible_path"
say "下载缓存：$archive_path"
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) printf '请将命令目录加入 PATH：export PATH=%q:"$PATH"\n' "$install_dir" >&2 ;;
esac
