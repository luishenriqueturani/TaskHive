#!/usr/bin/env bash
# Restaura origin + upstream quando .git/config ficar vazio (0 bytes).
# TaskHive — 3 repos Git independentes.
#
# Após restaurar, grava backup em .git/config.taskhive-backup (usado pelo hook pre-push).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

write_config() {
  local cfg="$1" url="$2" branch="$3"
  cat > "$cfg" <<EOF
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
[remote "origin"]
	url = $url
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "$branch"]
	remote = origin
	merge = refs/heads/$branch
EOF
}

restore() {
  local dir="$1" url="$2" branch="$3"
  local cfg="$dir/.git/config"
  local backup="$dir/.git/config.taskhive-backup"

  if [[ ! -d "$dir/.git" ]]; then
    echo "SKIP: $dir (sem .git)"
    return
  fi

  local size
  size="$(wc -c < "$cfg" 2>/dev/null || echo 0)"
  if [[ "$size" -gt 0 ]]; then
    echo "OK (já válido): $dir ($(wc -c < "$cfg") bytes)"
    cp "$cfg" "$backup"
    git -C "$dir" status -sb
    echo
    return
  fi

  if [[ -s "$backup" ]]; then
    cp "$backup" "$cfg"
    echo "RESTAURADO do backup: $dir"
  else
    write_config "$cfg" "$url" "$branch"
    echo "RESTAURADO do template: $dir → $url ($branch)"
  fi

  cp "$cfg" "$backup"
  git -C "$dir" status -sb
  echo
}

restore "$ROOT" "https://github.com/luishenriqueturani/TaskHive.git" "master"
restore "$ROOT/backend" "https://github.com/luishenriqueturani/task-hive.git" "master"
restore "$ROOT/FrontEnd" "https://github.com/luishenriqueturani/task-hive-front.git" "main"

echo "Feito. Verifique: wc -c .git/config (deve ser > 0 em cada repo)."
echo "Opcional: ./scripts/install-git-hooks.sh (auto-restaura antes de push)"
