#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# demo-cleanup.sh — supprime les comptes de démo créés il y a plus de TTL_HOURS.
#
# Passe par l'API admin (DELETE /admin/users/:id) → émet UserDeleted → les modules
# nettoient les fichiers de l'utilisateur (libère le disque). Garde l'admin et
# tout compte de rôle ≠ 'user'. Idéal en cron horaire.
#
#   TTL_HOURS=24 KUBUNO_BASE=http://127.0.0.1:8090 bash demo-cleanup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
BASE="${KUBUNO_BASE:-http://127.0.0.1:8090}"
TTL_HOURS="${TTL_HOURS:-24}"
ADMIN_LOGIN="${KUBUNO_ADMIN_USER:-admin}"
ADMIN_PASS="${KUBUNO_ADMIN_PASSWORD:-kubuno}"

tok=$(curl -fsS -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
        -d "{\"login\":\"${ADMIN_LOGIN}\",\"password\":\"${ADMIN_PASS}\"}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# IDs des comptes 'user' trop vieux. Script via `python3 -c` pour que stdin
# reste le flux de curl (un heredoc volerait stdin).
ids=$(curl -fsS "$BASE/api/v1/admin/users" -H "Authorization: Bearer $tok" \
      | TTL_HOURS="$TTL_HOURS" python3 -c '
import sys, json, os, datetime
ttl = int(os.environ["TTL_HOURS"]) * 3600
d = json.load(sys.stdin)
users = d.get("users", d) if isinstance(d, dict) else d
now = datetime.datetime.now(datetime.timezone.utc)
for u in users:
    if u.get("role") == "admin":
        continue
    ca = u.get("created_at")
    if not ca:
        continue
    t = datetime.datetime.fromisoformat(ca.replace("Z", "+00:00"))
    if (now - t).total_seconds() > ttl:
        print(u["id"])
')

n=0
for id in $ids; do
  if curl -fsS -X DELETE "$BASE/api/v1/admin/users/$id" -H "Authorization: Bearer $tok" >/dev/null; then
    echo "supprimé $id"; n=$((n+1))
  else
    echo "échec $id" >&2
  fi
done
echo "purge terminée : $n compte(s) supprimé(s) (TTL ${TTL_HOURS}h)"
