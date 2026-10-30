#!/usr/bin/env bash
# audit.sh : audit de durcissement des conteneurs en cours d'exécution (inspiré du CIS Docker Benchmark, section 5)
#
#   ./audit.sh            tous les conteneurs en cours d'exécution
#   ./audit.sh shop       uniquement ceux du projet Compose "shop"
#
# Contrôles (un échec = un écart) :
#   user        processus principal en root (USER vide, 0 ou root)            CIS 4.1
#   privileged  conteneur --privileged                                         CIS 5.4
#   capdrop     capabilities par défaut non retirées (pas de cap_drop: ALL)    CIS 5.3
#   readonly    système de fichiers racine inscriptible                        CIS 5.12
#   memory      aucune limite mémoire                                          CIS 5.10
#   pids        aucune limite de processus                                     CIS 5.28
#   nnp         no-new-privileges absent                                       CIS 5.25
#   socket      socket Docker montée dans le conteneur                         CIS 5.31
#
# Un conteneur peut déclarer des exceptions justifiées par un label, visible dans le compose :
#   labels: { audit.exceptions: "user,socket" }
# Elles sont affichées comme "acceptées" et ne comptent pas dans le code retour.
#
# Code retour : 0 si aucun écart, 1 sinon, 2 si aucun conteneur.
set -uo pipefail

command -v jq >/dev/null || { echo "jq est requis"; exit 2; }

filter=()
[ -n "${1:-}" ] && filter=(--filter "label=com.docker.compose.project=$1")
ids=$(docker ps -q "${filter[@]}")
if [ -z "$ids" ]; then echo "aucun conteneur en cours d'exécution${1:+ pour le projet $1}"; exit 2; fi

# shellcheck disable=SC2086
rows=$(docker inspect $ids | jq -r '
  .[]
  | (.Config.User // "") as $u
  | ((.Config.Labels // {})["audit.exceptions"] // "" | split(",") | map(gsub(" "; "")) | map(select(. != ""))) as $exc
  | ((.HostConfig.CapDrop // []) | map(ascii_upcase | ltrimstr("CAP_"))) as $drop
  | ((.HostConfig.CapAdd  // []) | map(ascii_upcase | ltrimstr("CAP_"))) as $add
  | ((.HostConfig.SecurityOpt // []) | any(test("^no-new-privileges(:true|=true)?$"))) as $nnp
  | ((.Mounts // []) | any(.Source | test("docker\\.sock$"))) as $sock
  | (.HostConfig.Memory // 0) as $mem
  | (.HostConfig.PidsLimit // 0) as $pids
  | ([ (if ($u == "" or $u == "0" or $u == "root" or ($u | test("^(0|root):"))) then "user" else empty end),
       (if .HostConfig.Privileged then "privileged" else empty end),
       (if ($drop | index("ALL")) == null then "capdrop" else empty end),
       (if .HostConfig.ReadonlyRootfs | not then "readonly" else empty end),
       (if $mem == 0 then "memory" else empty end),
       (if $pids <= 0 then "pids" else empty end),
       (if $nnp | not then "nnp" else empty end),
       (if $sock then "socket" else empty end)
     ]) as $fail
  | ($fail - $exc) as $ecarts
  | ($fail - $ecarts) as $acceptes
  | [ (.Name | ltrimstr("/")),
      (if $u == "" then "root(vide)" else $u end),
      (if .HostConfig.Privileged then "oui" else "non" end),
      (if ($drop | length) == 0 then "-" else ($drop | join(",")) end),
      (if ($add | length) == 0 then "-" else ($add | join(",")) end),
      (if .HostConfig.ReadonlyRootfs then "oui" else "non" end),
      (if $mem == 0 then "aucune" else "\($mem / 1048576 | floor)M" end),
      (if $pids <= 0 then "aucune" else "\($pids)" end),
      (if $nnp then "oui" else "non" end),
      (if $sock then "OUI" else "non" end),
      ($ecarts | length | tostring),
      (if ($ecarts | length) == 0 then "-" else ($ecarts | join(",")) end),
      (if ($acceptes | length) == 0 then "-" else ($acceptes | join(",")) end)
    ] | @tsv' | sort)

{
  printf 'CONTENEUR\tUSER\tPRIVIL.\tCAP_DROP\tCAP_ADD\tRO\tMEMOIRE\tPIDS\tNNP\tSOCKET\tNB\tECARTS\tACCEPTES\n'
  printf '%s\n' "$rows"
} | awk -F'\t' '
  { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; if (NF > nf) nf = NF }
  END { for (r = 1; r <= n; r++) { line = ""; for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] + 2 "s", cell[r, i]); sub(/ +$/, "", line); print line } }'

total=$(printf '%s\n' "$rows" | awk -F'\t' '{s += $11} END {print s + 0}')
nb=$(printf '%s\n' "$rows" | grep -c .)
acc=$(printf '%s\n' "$rows" | awk -F'\t' '$13 != "-" {n += split($13, a, ",")} END {print n + 0}')
echo
echo "Total : $total écart(s) sur $nb conteneur(s), $acc exception(s) acceptée(s)"
[ "$total" -eq 0 ]
