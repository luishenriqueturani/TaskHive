#!/usr/bin/env bash
# Restaura origin + upstream quando .git/config ficar vazio (0 bytes).
# TaskHive — 3 repos Git independentes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

restore() {
  local dir="$1" url="$2" branch="$3"
  local cfg="$dir/.git/config"

  if [[ ! -d "$dir/.git" ]]; then
    echo "SKIP: $dir (sem .git)"
    return
  fi

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

  echo "OK: $dir → $url ($branch)"
  git -C "$dir" status -sb
  echo
}

restore "$ROOT" "https://github.com/luishenriqueturani/TaskHive.git" "master"
restore "$ROOT/backend" "https://github.com/luishenriqueturani/task-hive.git" "master"
restore "$ROOT/FrontEnd" "https://github.com/luishenriqueturani/task-hive-front.git" "main"

echo "Feito. Verifique: wc -c .git/config (deve ser > 0 em cada repo)."
