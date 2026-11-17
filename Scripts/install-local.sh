#!/bin/zsh
set -euo pipefail
umask 077

PROJECT_ROOT="${0:A:h:h}"
INSTALL_APP_DIR="$HOME/Applications"
INSTALL_BIN_DIR="$HOME/.local/bin"
INSTALL_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
INSTALL_WITH_SKILL=0
INSTALL_SKIP_BUILD=0
INSTALL_OPEN_APP=0

usage() {
  cat <<'USAGE'
从源码安装 WhereKey（无需 sudo）

用法：./Scripts/install-local.sh [选项]
  --app-dir DIR             应用目录（默认 ~/Applications）
  --bin-dir DIR             CLI 链接目录（默认 ~/.local/bin）
  --with-codex-skill        同时安装仓库内的 Codex Skill
  --codex-skills-dir DIR    Skill 父目录（默认 $CODEX_HOME/skills 或 ~/.codex/skills）
  --skip-build             复用 .build/WhereKey.app，仍执行签名与身份检查
  --open                   安装成功后打开应用
  -h, --help               显示帮助

升级前请退出目标 WhereKey。应用、CLI 和可选 Skill 会先备份；
不会读取或修改 metadata、现有 Key、Keychain ACL 或系统安全设置。
USAGE
}

while (( $# )); do
  case "$1" in
    --app-dir|--bin-dir|--codex-skills-dir)
      (( $# >= 2 )) || { print -u2 -- "$1 缺少目录"; exit 2; }
      [[ -n "$2" ]] || { print -u2 -- "目录不能为空"; exit 2; }
      case "$1" in
        --app-dir) INSTALL_APP_DIR="$2" ;;
        --bin-dir) INSTALL_BIN_DIR="$2" ;;
        --codex-skills-dir) INSTALL_SKILLS_DIR="$2" ;;
      esac
      shift 2 ;;
    --with-codex-skill) INSTALL_WITH_SKILL=1; shift ;;
    --skip-build) INSTALL_SKIP_BUILD=1; shift ;;
    --open) INSTALL_OPEN_APP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知选项：$1"; usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || { print -u2 -- "WhereKey 仅支持 macOS。"; exit 1; }
(( EUID != 0 )) || { print -u2 -- "请以当前用户运行，不要使用 sudo。"; exit 1; }
command -v python3 >/dev/null || { print -u2 -- "需要 python3。"; exit 1; }

# Normalize user-selected paths without evaluating their text as shell code.
INSTALL_APP_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$INSTALL_APP_DIR")"
INSTALL_BIN_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$INSTALL_BIN_DIR")"
INSTALL_SKILLS_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$INSTALL_SKILLS_DIR")"
INSTALL_APP="$INSTALL_APP_DIR/WhereKey.app"
INSTALL_CLI="$INSTALL_BIN_DIR/wherekey"
INSTALL_SKILL="$INSTALL_SKILLS_DIR/wherekey"
INSTALL_SOURCE="$PROJECT_ROOT/.build/WhereKey.app"
INSTALL_HELPER="$INSTALL_APP/Contents/Helpers/wherekey"

# Destinations may not contain each other: that would break the bundle seal or
# move the installer's own staging/backup directory into a Skill backup.
python3 - "$INSTALL_APP" "$INSTALL_CLI" "$INSTALL_SKILL" "$INSTALL_WITH_SKILL" <<'PY_PATHS'
import os, sys
def destination(value):
    return os.path.join(os.path.realpath(os.path.dirname(value)), os.path.basename(value))
paths = [destination(value) for value in sys.argv[1:3]]
if sys.argv[4] == '1':
    paths.append(destination(sys.argv[3]))
for index, first in enumerate(paths):
    for second in paths[index + 1:]:
        if os.path.commonpath([first, second]) in (first, second):
            print('App、CLI 和 Skill 目标不能相互包含或指向同一路径。', file=sys.stderr)
            raise SystemExit(1)
PY_PATHS

refuse_running_target() {
  python3 - "$INSTALL_APP/Contents/MacOS/WhereKeyApp" <<'PY'
import os, subprocess, sys
expected = os.path.realpath(sys.argv[1])
for line in subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and os.path.realpath(fields[1]) == expected:
        print('目标 WhereKey 仍在运行。请正常退出应用后重新安装；安装器不会强制结束进程。', file=sys.stderr)
        raise SystemExit(1)
PY
}

validate_source() {
  [[ -d "$INSTALL_SOURCE" && ! -L "$INSTALL_SOURCE" ]] || { print -u2 -- "找不到构建产物，请先运行 ./Scripts/build-local.sh。"; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_SOURCE/Contents/Info.plist")" == com.wherekey.mac ]] || return 1
  [[ -x "$INSTALL_SOURCE/Contents/MacOS/WhereKeyApp" && -x "$INSTALL_SOURCE/Contents/Helpers/wherekey" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$INSTALL_SOURCE"
  /usr/bin/codesign --verify --strict -R '=identifier "com.wherekey.cli"' "$INSTALL_SOURCE/Contents/Helpers/wherekey"
  /usr/bin/codesign --verify --strict -R '=identifier "com.wherekey.mac"' "$INSTALL_SOURCE"
}

refuse_running_target
if (( ! INSTALL_SKIP_BUILD )); then
  "$PROJECT_ROOT/Scripts/build-local.sh"
fi
validate_source

# Never overwrite an unrelated app, arbitrary executable, or unknown broken link.
if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
  [[ -d "$INSTALL_APP" && ! -L "$INSTALL_APP" ]] || { print -u2 -- "应用目标不是普通 WhereKey.app 目录，已停止。"; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALL_APP/Contents/Info.plist" 2>/dev/null)" == com.wherekey.mac ]] || { print -u2 -- "应用目标不属于 WhereKey，已停止。"; exit 1; }
fi
if [[ -e "$INSTALL_CLI" || -L "$INSTALL_CLI" ]]; then
  if [[ -L "$INSTALL_CLI" && ! -e "$INSTALL_CLI" ]]; then
    [[ "$(/usr/bin/readlink "$INSTALL_CLI")" == "$INSTALL_HELPER" ]] || { print -u2 -- "CLI 目标是未知的失效链接，已停止。"; exit 1; }
  else
    [[ -f "$INSTALL_CLI" ]] && /usr/bin/codesign --verify --strict -R '=identifier "com.wherekey.cli"' "$INSTALL_CLI" 2>/dev/null || { print -u2 -- "CLI 目标不是已签名的 WhereKey CLI，已停止。"; exit 1; }
  fi
fi
if (( INSTALL_WITH_SKILL )); then
  [[ -f "$INSTALL_SOURCE/Contents/Resources/Integrations/codex/wherekey/SKILL.md" ]] || { print -u2 -- "构建产物缺少 Codex Skill。"; exit 1; }
fi

mkdir -p "$INSTALL_APP_DIR" "$INSTALL_BIN_DIR"
[[ -w "$INSTALL_APP_DIR" && -w "$INSTALL_BIN_DIR" ]] || { print -u2 -- "目标目录不可写；请选择当前用户可写的目录。"; exit 1; }
if (( INSTALL_WITH_SKILL )); then
  mkdir -p "$INSTALL_SKILLS_DIR"
  [[ -w "$INSTALL_SKILLS_DIR" ]] || { print -u2 -- "Skill 目录不可写。"; exit 1; }
fi

# Serialize cooperating installers. Keep the lock file to avoid inode races.
zmodload zsh/system
INSTALL_LOCK="$INSTALL_APP_DIR/.wherekey-install.lock"
[[ ! -L "$INSTALL_LOCK" ]] || { print -u2 -- "安装锁不能是符号链接。"; exit 1; }
: >> "$INSTALL_LOCK"
zsystem flock -t 0 -f install_lock_fd "$INSTALL_LOCK" || { print -u2 -- "另一个安装器正在使用此应用目录。"; exit 1; }

INSTALL_STAGE="$(mktemp -d "$INSTALL_APP_DIR/.WhereKey-stage.XXXXXXXX")"
INSTALL_BACKUP="$(mktemp -d "$INSTALL_APP_DIR/.WhereKey-backup.XXXXXXXX")"
INSTALL_COMPLETE=0
INSTALL_APP_BACKED_UP=0
INSTALL_CLI_BACKED_UP=0
INSTALL_SKILL_BACKED_UP=0
INSTALL_APP_PLACED=0
INSTALL_CLI_PLACED=0
INSTALL_SKILL_PLACED=0
cleanup() {
  local install_exit_code=$?
  set +e
  if (( ! INSTALL_COMPLETE )); then
    (( ! INSTALL_SKILL_PLACED )) || rm -rf "$INSTALL_SKILL"
    (( ! INSTALL_CLI_PLACED )) || rm -f "$INSTALL_CLI"
    (( ! INSTALL_APP_PLACED )) || rm -rf "$INSTALL_APP"
    (( ! INSTALL_APP_BACKED_UP )) || mv "$INSTALL_BACKUP/WhereKey.app" "$INSTALL_APP"
    (( ! INSTALL_CLI_BACKED_UP )) || mv "$INSTALL_BACKUP/wherekey-cli" "$INSTALL_CLI"
    (( ! INSTALL_SKILL_BACKED_UP )) || mv "$INSTALL_BACKUP/wherekey-skill" "$INSTALL_SKILL"
    print -u2 -- "安装未完成，已尝试恢复原文件。备份：$INSTALL_BACKUP"
  fi
  rm -rf "$INSTALL_STAGE"
  return "$install_exit_code"
}
trap cleanup EXIT

/usr/bin/ditto "$INSTALL_SOURCE" "$INSTALL_STAGE/WhereKey.app"
/usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE/WhereKey.app"
ln -s "$INSTALL_HELPER" "$INSTALL_STAGE/wherekey"
if (( INSTALL_WITH_SKILL )); then
  /usr/bin/ditto "$INSTALL_STAGE/WhereKey.app/Contents/Resources/Integrations/codex/wherekey" "$INSTALL_STAGE/wherekey-skill"
fi
refuse_running_target

if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then mv "$INSTALL_APP" "$INSTALL_BACKUP/WhereKey.app"; INSTALL_APP_BACKED_UP=1; fi
if [[ -e "$INSTALL_CLI" || -L "$INSTALL_CLI" ]]; then mv "$INSTALL_CLI" "$INSTALL_BACKUP/wherekey-cli"; INSTALL_CLI_BACKED_UP=1; fi
if (( INSTALL_WITH_SKILL )) && [[ -e "$INSTALL_SKILL" || -L "$INSTALL_SKILL" ]]; then mv "$INSTALL_SKILL" "$INSTALL_BACKUP/wherekey-skill"; INSTALL_SKILL_BACKED_UP=1; fi
mv "$INSTALL_STAGE/WhereKey.app" "$INSTALL_APP"; INSTALL_APP_PLACED=1
mv "$INSTALL_STAGE/wherekey" "$INSTALL_CLI"; INSTALL_CLI_PLACED=1
if (( INSTALL_WITH_SKILL )); then mv "$INSTALL_STAGE/wherekey-skill" "$INSTALL_SKILL"; INSTALL_SKILL_PLACED=1; fi
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
"$INSTALL_CLI" --help >/dev/null
INSTALL_COMPLETE=1

print -r -- "安装完成：$INSTALL_APP"
print -r -- "CLI：$INSTALL_CLI"
print -r -- "备份：$INSTALL_BACKUP"
if (( INSTALL_WITH_SKILL )); then print -r -- "Codex Skill：$INSTALL_SKILL"; fi
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
  print -r -- "请把 $INSTALL_BIN_DIR 放在 PATH 前面，再运行 rehash 和 command -v wherekey。"
fi
INSTALL_RESOLVED_CLI="$(command -v wherekey || true)"
if [[ -n "$INSTALL_RESOLVED_CLI" && "$INSTALL_RESOLVED_CLI" != "$INSTALL_CLI" ]]; then
  print -r -- "注意：当前 shell 仍优先找到 $INSTALL_RESOLVED_CLI；请检查 PATH，避免使用旧 CLI。"
fi

if (( INSTALL_OPEN_APP )); then
  if /bin/ps -ww -axo comm= | /usr/bin/grep -E '/WhereKeyApp$' >/dev/null; then
    print -r -- "另一个 WhereKey 实例正在运行。请先退出它，再打开 $INSTALL_APP。"
  else
    /usr/bin/open "$INSTALL_APP"
  fi
fi
