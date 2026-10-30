#!/usr/bin/env bash
# release-gate.sh <registre/image@sha256:...> : porte de release appelée par la CI après le push
#   1. scan trivy de chaque plateforme : BLOQUE si une vulnérabilité CRITICAL a un correctif disponible
#      (les HIGH et les CRITICAL sans correctif sont comptés et affichés, sans bloquer)
#   2. signature cosign du digest (clé locale ici ; keyless OIDC dans le pipeline GitHub)
# La référence doit être un digest : on signe exactement ce qui a été scanné.
set -euo pipefail
cd "$(dirname "$0")"

REF="${1:?usage : ./release-gate.sh registre/image@sha256:...}"
case "$REF" in *@sha256:*) ;; *) echo "référence par digest obligatoire (image@sha256:...)"; exit 2 ;; esac

PLATFORMS="${GATE_PLATFORMS:-linux/amd64 linux/arm64}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.56.2}"
COSIGN_IMAGE="${COSIGN_IMAGE:-ghcr.io/sigstore/cosign/cosign:v2.4.1}"
KEYDIR="$PWD/ci/keys"
mkdir -p .ci "$KEYDIR"
name="$(basename "${REF%@*}")"

# ---- 1. scan
blocked=0
for p in $PLATFORMS; do
  out=".ci/trivy-$name-${p//\//-}.json"
  docker run --rm --network host -v trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" \
    image --quiet --insecure --platform "$p" --severity HIGH,CRITICAL --format json "$REF" > "$out"
  q='[.Results[]?.Vulnerabilities[]?'
  crit=$(jq "$q | select(.Severity==\"CRITICAL\")] | length" "$out")
  crit_fix=$(jq "$q | select(.Severity==\"CRITICAL\" and (.FixedVersion // \"\") != \"\")] | length" "$out")
  high=$(jq "$q | select(.Severity==\"HIGH\")] | length" "$out")
  high_fix=$(jq "$q | select(.Severity==\"HIGH\" and (.FixedVersion // \"\") != \"\")] | length" "$out")
  echo "trivy $name $p : CRITICAL=$crit (corrigibles : $crit_fix)  HIGH=$high (corrigibles : $high_fix)"
  if [ "$crit_fix" -gt 0 ]; then
    blocked=1
    jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
           | select(.Severity=="CRITICAL" and (.FixedVersion // "") != "")
           | "    \(.VulnerabilityID)  \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)  [\($t)]"' "$out" | sort -u
  fi
done
if [ "$blocked" -ne 0 ]; then
  echo "RELEASE GATE : BLOQUÉE ($name contient des vulnérabilités CRITICAL corrigibles)"
  exit 1
fi

# ---- 2. signature
if [ -n "${COSIGN_KEYLESS:-}" ]; then
  # pipeline GitHub : certificat éphémère émis pour l'identité OIDC du workflow, inscrit dans Rekor
  cosign sign --yes "$REF"
else
  if [ ! -f "$KEYDIR/cosign.key" ]; then
    [ -f "$KEYDIR/cosign.password" ] || (umask 077 && openssl rand -hex 16 > "$KEYDIR/cosign.password")
    docker run --rm -v "$KEYDIR":/keys -w /keys -e COSIGN_PASSWORD="$(cat "$KEYDIR/cosign.password")" \
      "$COSIGN_IMAGE" generate-key-pair >/dev/null
    echo "paire de clés cosign générée dans ci/keys (cosign.key non versionnée)"
  fi
  # registre local sans TLS et sans journal de transparence (Rekor) : options --allow-* / --tlog-upload=false
  docker run --rm --network host -v "$KEYDIR":/keys:ro -e COSIGN_PASSWORD="$(cat "$KEYDIR/cosign.password")" \
    "$COSIGN_IMAGE" sign --yes --key /keys/cosign.key --tlog-upload=false \
    --allow-insecure-registry --allow-http-registry "$REF"
fi
echo "RELEASE GATE : OK ($name scanné et signé)"
