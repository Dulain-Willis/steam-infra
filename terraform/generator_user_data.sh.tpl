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
  steam-generator
