#!/usr/bin/env bash
# Start 智研工坊 by building this checkout (default, compose.dev.yaml).
# Pulling a published image still works when ZHIYAN_IMAGE points at a registry.
#
# Usage:
#   ./start.sh            build this checkout and start it in the background
#   ./start.sh dev        same as above
#   ./start.sh -d         install/start using the image pinned in compose.yaml
#   ./start.sh logs       follow platform logs
#   ./start.sh stop       stop containers, keep them and their data
#   ./start.sh down       remove containers, keep data volumes
#   ./start.sh restart    restart the platform container
#   ./start.sh pull       refresh images and recreate changed containers
#   ./start.sh release    drop the source-build override and use ZHIYAN_IMAGE
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source scripts/docker-access.sh
source scripts/ghcr-mirror.sh

compose() {
  [[ -f .env ]] || docker_access_fail 'Not installed yet. Run ./start.sh first.'
  select_docker_access || docker_access_fail 'Docker is not running, or this user cannot access it.'
  docker_access compose --profile platform "$@"
}

cmd="${1:-dev}"
shift || true
case "$cmd" in
  up|-d|detach) bash scripts/install.sh ;;
  dev) ZHIYAN_BUILD_FROM_SOURCE=1 bash scripts/install.sh ;;
  release)
    [[ -f .env ]] && python3 - <<'PY'
import pathlib,re
p=pathlib.Path('.env')
p.write_text(re.sub(r'(?m)^COMPOSE_FILE=.*\n?','',p.read_text()))
PY
    COMPOSE_FILE=compose.yaml bash scripts/install.sh
    ;;
  pull)
    # Docker is selected before the speed test: a faster Nanjing mirror pulls
    # immediately, and the direct ghcr.io path needs it too.
    [[ -f .env ]] || docker_access_fail 'Not installed yet. Run ./start.sh first.'
    select_docker_access || docker_access_fail 'Docker is not running, or this user cannot access it.'
    if mirror_published_ghcr always; then
      compose pull --policy always mysql
    else
      compose pull --ignore-buildable --policy always
    fi
    compose up -d --no-build --wait --wait-timeout 180
    # A newer image may read generated columns the old volume never got.
    bash scripts/install-schema-extensions.sh
    ;;
  logs) compose logs -f "${@:-platform}" ;;
  stop) compose stop ;;
  down) compose down --remove-orphans ;;
  restart) compose restart platform ;;
  build)
    echo 'The default start uses the published GHCR image (no local build).' >&2
    echo 'For a source build: ./start.sh dev' >&2
    exit 1
    ;;
  *)
    echo "unknown: $cmd" >&2
    echo 'usage: ./start.sh [-d|logs|stop|down|restart|pull|dev|release]' >&2
    exit 1
    ;;
esac
