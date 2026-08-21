#!/usr/bin/env bash
# Instala hook pre-push nos 3 repos TaskHive — restaura .git/config se estiver vazio.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOOK_BODY='#!/usr/bin/env bash
set -euo pipefail
GIT_DIR="$(git rev-parse --git-dir)"
CFG="$GIT_DIR/config"
BACKUP="$GIT_DIR/config.taskhive-backup"
if [[ -s "$CFG" ]]; then
  exit 0
fi
if [[ -s "$BACKUP" ]]; then
  cp "$BACKUP" "$CFG"
  echo "TaskHive: .git/config estava vazio — restaurado do backup local." >&2
  exit 0
fi
echo "TaskHive: .git/config vazio e sem backup. Corre: ./scripts/restore-git-remotes.sh" >&2
exit 1
'

install_hook() {
  local dir="$1"
  [[ -d "$dir/.git" ]] || return 0
  local hooks="$dir/.git/hooks"
  mkdir -p "$hooks"
  printf '%s\n' "$HOOK_BODY" > "$hooks/pre-push"
  chmod +x "$hooks/pre-push"
  echo "OK: $dir/.git/hooks/pre-push"
}

install_hook "$ROOT"
install_hook "$ROOT/backend"
install_hook "$ROOT/FrontEnd"

echo "Hooks instalados nos 3 repos."
