#!/usr/bin/env bash
# Stage 3: ローカルメディアをR2へ移行し drive_file を再パス(最新スキーマ上で実施)
# アップロードは追記型で安全。DB再パスは破壊的なため DRY_RUN=1 が既定
# 本番前に必ずDBコピーで検証すること
set -euo pipefail

OLD_SSH="${OLD_SSH:-ssh -i $HOME/.ssh/miel-servers -o StrictHostKeyChecking=accept-new root@118.27.110.132}"
NEW_SSH="${NEW_SSH:-ssh -i /Users/mq1/miel-misskey/miel-kagoya-misskey.key -o IdentitiesOnly=yes -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new root@133.18.121.183}"
REMOTE_DIR="${REMOTE_DIR:-/opt/rochka.club-docker-provision}"
OLD_FILES="${OLD_FILES:-/home/misskey/misskey/files/}"

# R2 / S3互換。要設定
R2_ENDPOINT="${R2_ENDPOINT:?set R2_ENDPOINT}"
R2_BUCKET="${R2_BUCKET:?set R2_BUCKET}"
R2_PREFIX="${R2_PREFIX:-}"
BASE_URL="${BASE_URL:?set BASE_URL, e.g. https://media.rochka.club}"
NEW_DB="${NEW_DB:-mk1}"
NEW_DB_USER="${NEW_DB_USER:-misskey}"
DRY_RUN="${DRY_RUN:-1}"

run_remote() { $NEW_SSH "cd '$REMOTE_DIR' && $*"; }

echo "==> [1/3] rsync old media -> new:${REMOTE_DIR}/data/files"
# 旧→新へ直接rsync(新側の公開鍵を旧のknown_hostsに要登録、または手元中継)
run_remote "mkdir -p data/files"
$OLD_SSH "rsync -a --info=progress2 '$OLD_FILES' -e 'ssh -o StrictHostKeyChecking=accept-new' \
  root@133.18.121.183:'$REMOTE_DIR/data/files/'" || \
  echo "note: direct old->new rsync failed; relay via local host instead"

echo "==> [2/3] upload to R2 (additive; key = accessKey)"
run_remote "docker run --rm -v '$REMOTE_DIR/data/files':/src -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  amazon/aws-cli s3 sync /src 's3://${R2_BUCKET}/${R2_PREFIX}' --endpoint-url '$R2_ENDPOINT' --only-show-errors"

echo "==> [3/3] re-path drive_file (DRY_RUN=${DRY_RUN})"
# 既存の内部ファイルをR2参照へ切替。列は最新スキーマに合わせて要確認
SQL=$(cat <<SQL
UPDATE drive_file
SET "storedInternal" = false,
    "isLink" = false,
    "url"          = '${BASE_URL}/${R2_PREFIX}' || "accessKey",
    "thumbnailUrl" = CASE WHEN "thumbnailAccessKey" IS NOT NULL THEN '${BASE_URL}/${R2_PREFIX}' || "thumbnailAccessKey" ELSE "thumbnailUrl" END,
    "webpublicUrl" = CASE WHEN "webpublicAccessKey" IS NOT NULL THEN '${BASE_URL}/${R2_PREFIX}' || "webpublicAccessKey" ELSE "webpublicUrl" END
WHERE "storedInternal" = true;
SQL
)

if [ "$DRY_RUN" = "1" ]; then
  echo "---- SQL (not executed) ----"
  echo "$SQL"
  echo "---- set DRY_RUN=0 to apply (after testing on a DB copy) ----"
else
  echo "$SQL" | run_remote "docker compose exec -T db psql -U '$NEW_DB_USER' -d '$NEW_DB' -v ON_ERROR_STOP=1 -f -"
  echo "done: drive_file re-pathed to R2"
fi

echo "note: also enable object storage in admin panel (meta): endpoint/bucket/prefix/baseUrl/keys so NEW uploads go to R2"
