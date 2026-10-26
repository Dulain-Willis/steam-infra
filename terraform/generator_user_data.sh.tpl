#!/bin/bash
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

mkdir -p /opt/generator

cat > /opt/generator/Dockerfile <<'DOCKERFILE_EOF'
${dockerfile}
DOCKERFILE_EOF

cat > /opt/generator/requirements.txt <<'REQUIREMENTS_EOF'
${requirements}
REQUIREMENTS_EOF

cat > /opt/generator/generator.py <<'GENERATOR_EOF'
${generator_py}
GENERATOR_EOF

cat > /opt/generator/dirty.py <<'DIRTY_EOF'
${dirty_py}
DIRTY_EOF

docker build -t steam-generator /opt/generator

docker run -d \
  --name steam-generator \
  --restart unless-stopped \
  -e DB_HOST="${db_host}" \
  -e DB_PORT="${db_port}" \
  -e DB_NAME="${db_name}" \
  -e DB_USER="${db_user}" \
  -e DB_PASSWORD="${db_password}" \
  -e TICK_MIN_SECONDS="${tick_min_seconds}" \
  -e TICK_MAX_SECONDS="${tick_max_seconds}" \
  -e REFUND_REASON_NULL_RATE="${refund_reason_null_rate}" \
  -e DUPLICATE_RATE_WISHLIST_ITEMS="${duplicate_rate_wishlist_items}" \
  -e DUPLICATE_RATE_PLAYTIME_SESSIONS="${duplicate_rate_playtime_sessions}" \
  -e DUPLICATE_RATE_PURCHASES="${duplicate_rate_purchases}" \
  -e PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS="${purchase_recorded_at_jitter_max_seconds}" \
  -e REVIEW_RECORDED_AT_JITTER_MAX_SECONDS="${review_recorded_at_jitter_max_seconds}" \
  -e SNAPSHOT_RECORDED_AT_JITTER_MAX_SECONDS="${snapshot_recorded_at_jitter_max_seconds}" \
  -e ORPHAN_NEVER_ARRIVES_RATE="${orphan_never_arrives_rate}" \
  -e ORPHAN_LATE_ARRIVAL_RATE="${orphan_late_arrival_rate}" \
  -e ORPHAN_LATE_ARRIVAL_DELAY_SECONDS="${orphan_late_arrival_delay_seconds}" \
  -e LATE_ARRIVAL_RATE="${late_arrival_rate}" \
  -e LATE_ARRIVAL_MAX_DAYS="${late_arrival_max_days}" \
  -e PAYMENT_METHOD_NEW_ONSET_DATE="${payment_method_new_onset_date}" \
  -e RESTATEMENT_WEIGHT="${restatement_weight}" \
  steam-generator
