#!/usr/bin/env bash
# Spin up a local Redis container for the agent's history tracking.
# The agents work fine WITHOUT Redis (history is decorative) — this is for users
# who want full feature parity with production.
set -euo pipefail

ACTION="${1:-up}"

case "${ACTION}" in
  up)
    if ! command -v docker >/dev/null; then
      echo "✗ Docker not installed. Install Docker Desktop or run: brew install redis"
      exit 1
    fi
    if ! docker ps >/dev/null 2>&1; then
      echo "✗ Docker daemon not running. Open Docker Desktop."
      exit 1
    fi
    if docker ps --filter "name=mirv-redis" --format '{{.Names}}' | grep -q mirv-redis; then
      echo "✓ Already running"
    else
      docker run -d --name mirv-redis -p 6379:6379 redis:7-alpine >/dev/null
      sleep 1
      echo "✓ Started Redis container 'mirv-redis' on localhost:6379"
    fi
    echo ""
    echo "Add to .env:"
    echo "  REDIS_URL=redis://localhost:6379"
    ;;
  down)
    docker rm -f mirv-redis 2>/dev/null && echo "✓ Stopped mirv-redis" || echo "Not running"
    ;;
  status)
    docker ps --filter "name=mirv-redis" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  *)
    echo "Usage: $0 [up|down|status]"
    exit 1
    ;;
esac
