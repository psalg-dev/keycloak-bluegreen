# Probe helpers. Source from repo root after kc.sh: `. scripts/lib/kc.sh; . scripts/security/lib.sh`
# Contract: a probe prints `PASS|WARN|FAIL <probe>: <evidence>` lines on stdout (logs go to stderr) and exits 1 on any FAIL.
# shellcheck shell=bash
# shellcheck source=security/tools.env
. security/tools.env

PROBE=$(basename "$0" .sh); PROBE=${PROBE#probe-}
OUT=out/security; mkdir -p "$OUT"
FAILED=0 WARNED=0
pass() { echo "PASS $PROBE: $*"; }
warn() { echo "WARN $PROBE: $*"; WARNED=1; }
fail() { echo "FAIL $PROBE: $*"; FAILED=1; }
# finish <evidence>: PASS line if nothing failed or warned, then exit 0/1
finish() { ((FAILED || WARNED)) || pass "$*"; exit "$FAILED"; }

KC_HOSTS=(kc-net1.localtest.me kc-net2.localtest.me)
LEGACY_HOSTS=(legacy-net1.localtest.me legacy-net2.localtest.me)
# The public hostnames resolve to 127.0.0.1; from the kind network the ingress is the control-plane node's :443.
NODE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$CLUSTER-control-plane")
RESOLVE=() ADD_HOSTS=()
for h in "${KC_HOSTS[@]}" "${LEGACY_HOSTS[@]}"; do RESOLVE+=(--resolve "$h:443:$NODE_IP"); ADD_HOSTS+=(--add-host "$h:$NODE_IP"); done
ca_file >/dev/null # sets CA_FILE

# pub [curl args...]: curl to the public URLs through the ingress, TLS verified against the demo CA
pub() { curl -s --max-time 20 --cacert "$CA_FILE" "${RESOLVE[@]}" "$@"; }

# tool [docker run args...]: throwaway tool container on the kind network that resolves the public hostnames.
# No bind mounts: paths in this container (launcher or Jenkins workspace) are not paths on the docker host.
# Feed files on stdin, read results from stdout.
tool() { docker run --rm -i --network kind "${ADD_HOSTS[@]}" "$@"; }

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
jwt_part() { local p; p=$(cut -d. -f"$2" <<<"$1" | tr '_-' '/+'); while ((${#p} % 4)); do p+="="; done; base64 -d <<<"$p"; }

# tmp_realm: throwaway realm (user `probe`, confidential client `probe` with direct grants) for probes that need a
# real session without touching realm demo or its users. Deleted on exit. Sets TMP_REALM, TMP_PW, TMP_SECRET.
tmp_realm() {
  TMP_REALM=secprobe-$RANDOM$RANDOM TMP_PW=$(openssl rand -hex 16) TMP_SECRET=$(openssl rand -hex 16)
  R=$TMP_REALM P=$TMP_PW S=$TMP_SECRET jq -n '{realm: env.R, enabled: true,
    users: [{username: "probe", enabled: true, email: "probe@secprobe.invalid", emailVerified: true, firstName: "Sec",
      lastName: "Probe", credentials: [{type: "password", value: env.P, temporary: false}]}],
    clients: [{clientId: "probe", publicClient: false, secret: env.S, standardFlowEnabled: true,
      directAccessGrantsEnabled: true, redirectUris: ["https://app.localtest.me/cb"]}]}' \
    | admin_api POST /realms -d @- >/dev/null || die "could not create realm $TMP_REALM"
  # Fresh admin token in the trap: the cached one lives 60 s.
  trap 'ADMIN_TOKEN="" admin_api DELETE "/realms/$TMP_REALM" >/dev/null || log "could not delete realm $TMP_REALM"' EXIT
  log "throwaway realm $TMP_REALM"
}
