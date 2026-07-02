#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Stage 2: バニラ・アップグレード連鎖(v12.119.2 → 最新)
#   app イメージ tag を段階的に上げ、都度起動して TypeORM マイグレーション
#   完走(= :3000 が応答)を待って停止、を繰り返す。
#   最大の難所は v12 → v13(全面書き換え)。まず 13.x で壁を越える。
#
#   ★必ず本番DBのコピーでdry-runしてから本番適用すること★
# ─────────────────────────────────────────────────────────────
set -euo pipefail

NEW_SSH="${NEW_SSH:-ssh -i /Users/mq1/miel-misskey/miel-kagoya-misskey.key -o IdentitiesOnly=yes -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new root@133.18.121.183}"
REMOTE_DIR="${REMOTE_DIR:-/opt/rochka.club-docker-provision}"
TIMEOUT="${TIMEOUT:-1800}"   # 1バージョンあたり最大待機秒(v13移行は長め)

# チェックポイント。v13で壁を越えてから最終版へ。
# 大ジャンプで失敗する場合は 2023.x / 2024.x / 2025.x を間に挿入する。
TAGS=(${TAGS:-13.14.2 2026.6.0})

run_remote() { $NEW_SSH "cd '$REMOTE_DIR' && $*"; }

for tag in "${TAGS[@]}"; do
  echo "════════════════════════════════════════════"
  echo " migrating with misskey/misskey:${tag}"
  echo "════════════════════════════════════════════"
  # image を上書きする override を都度生成
  run_remote "printf 'services:\n  app:\n    image: misskey/misskey:%s\n' '$tag' > data/upgrade-override.yaml"
  run_remote "docker pull misskey/misskey:'$tag'" || { echo "!! cannot pull tag $tag; adjust TAGS to existing tags"; exit 1; }
  run_remote "docker compose -f compose.yaml -f data/upgrade-override.yaml up -d db redis app"

  echo "  waiting for migration (:3000 responds), up to ${TIMEOUT}s"
  run_remote "
    for i in \$(seq 1 $((TIMEOUT/5))); do
      if ! docker compose ps app | grep -q ' Up\\| running'; then
        if docker compose ps -a app | grep -qi 'exit'; then echo MIGRATION_FAILED; docker compose logs --tail=40 app; exit 2; fi
      fi
      if curl -sf -o /dev/null http://127.0.0.1:3000/; then echo READY; exit 0; fi
      sleep 5
    done
    echo TIMEOUT; docker compose logs --tail=40 app; exit 3
  "
  echo "  ok: ${tag} done"
  run_remote "docker compose stop app"
done

echo "==> chain done; removing override and starting pinned app"
run_remote "rm -f data/upgrade-override.yaml && docker compose up -d db redis app"
echo "latest schema reached; next run 30-media-to-r2.sh"
