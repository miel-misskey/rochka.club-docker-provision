#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Stage 1: 旧DBを pg_dump(-Fc)し、新サーバの db コンテナ(postgres:15)へ restore
#   前提: 旧サーバはメンテナンスモードでDB静止 / 新サーバに本リポジトリclone済
#   実行: ローカル(手元Mac)から。ダンプは手元経由で中継
# ─────────────────────────────────────────────────────────────
set -euo pipefail

OLD_SSH="${OLD_SSH:-ssh -i $HOME/.ssh/miel-servers -o StrictHostKeyChecking=accept-new root@118.27.110.132}"
NEW_SSH="${NEW_SSH:-ssh -i /Users/mq1/miel-misskey/miel-kagoya-misskey.key -o IdentitiesOnly=yes -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new root@133.18.121.183}"
OLD_DB="${OLD_DB:-mk1}"
NEW_DB="${NEW_DB:-mk1}"
NEW_DB_USER="${NEW_DB_USER:-misskey}"
REMOTE_DIR="${REMOTE_DIR:-/opt/rochka.club-docker-provision}"
DUMP="${DUMP:-$(dirname "$0")/tmp/mk1-$(date +%Y%m%d).dump}"
mkdir -p "$(dirname "$DUMP")"

echo "==> [old] pg_dump -Fc $OLD_DB -> $DUMP"
$OLD_SSH "sudo -u postgres pg_dump -Fc '$OLD_DB'" > "$DUMP"
ls -lh "$DUMP"

echo "==> [new] start db container"
$NEW_SSH "cd '$REMOTE_DIR' && docker compose up -d db && \
  until docker compose exec -T db pg_isready -U '$NEW_DB_USER' -d '$NEW_DB' >/dev/null 2>&1; do sleep 2; done && echo db-ready"

echo "==> [new] pg_restore (--no-owner --no-privileges)"
# ダンプを新サーバへ転送しつつコンテナへ流し込む
cat "$DUMP" | $NEW_SSH "cd '$REMOTE_DIR' && docker compose exec -T db \
  pg_restore -U '$NEW_DB_USER' -d '$NEW_DB' --no-owner --no-privileges --exit-on-error -v" 2>&1 | tail -20 || {
    echo '!! restore failed: check empty DB / privileges / version'; exit 1; }

echo "==> [new] row-count sanity check"
$NEW_SSH "cd '$REMOTE_DIR' && docker compose exec -T db psql -U '$NEW_DB_USER' -d '$NEW_DB' -tAc \
  \"select 'notes='||count(*) from note\" ; docker compose exec -T db psql -U '$NEW_DB_USER' -d '$NEW_DB' -tAc \
  \"select 'users='||count(*) from \\\"user\\\"\""

echo "done: DB now at v12.119.2 schema; next run 20-upgrade-chain.sh"
