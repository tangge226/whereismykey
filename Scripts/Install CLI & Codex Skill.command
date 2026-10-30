#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
SOURCE_APP="$SCRIPT_ROOT/WhereKey.app"
APP_DESTINATION="/Applications/WhereKey.app"
CLI_DESTINATION="/usr/local/bin/wherekey"
SKILL_SOURCE="$APP_DESTINATION/Contents/Resources/Integrations/codex/wherekey"
SKILL_DESTINATION="$HOME/.codex/skills/wherekey"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "找不到 WhereKey.app，请直接从 WhereKey DMG 中运行此安装器。"
  read -k 1 "?按任意键退出…"
  exit 1
fi

echo "正在安装 WhereKey.app…"
sudo /usr/bin/ditto "$SOURCE_APP" "$APP_DESTINATION"
sudo /bin/mkdir -p /usr/local/bin
sudo /bin/ln -sfn "$APP_DESTINATION/Contents/Helpers/wherekey" "$CLI_DESTINATION"

/bin/mkdir -p "$HOME/.codex/skills"
if [[ -d "$SKILL_DESTINATION" ]]; then
  BACKUP_SUFFIX="$(/bin/date +%Y%m%d-%H%M%S)"
  /usr/bin/ditto "$SKILL_DESTINATION" "$SKILL_DESTINATION.backup-$BACKUP_SUFFIX"
fi
/usr/bin/ditto "$SKILL_SOURCE" "$SKILL_DESTINATION"

/usr/bin/open "$APP_DESTINATION"
echo "安装完成：WhereKey、wherekey CLI 和 Codex Skill 已就绪。"
read -k 1 "?按任意键关闭…"
