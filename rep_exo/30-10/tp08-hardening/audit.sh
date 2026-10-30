#!/usr/bin/env bash
# audit.sh [compose-project] - hardening audit of the running containers (all of them by default).
# One line per container, deviations in red; exit code 1 if at least one deviation.
# Containers allowed to mount the Docker socket: AUDIT_SOCKET_OK="name1 name2" (e.g. the socket proxy).
set -euo pipefail
PROJECT=${1:-}
filter=()
[ -n "$PROJECT" ] && filter=(--filter "label=com.docker.compose.project=$PROJECT")

ids=$(docker ps -q "${filter[@]}")
[ -n "$ids" ] || { echo "no running container"; exit 0; }

total=0
printf '%-26s %-8s %-5s %-14s %-12s %-3s %-9s %-6s %-4s %-6s %s\n' \
  CONTAINER USER PRIV CAP_ADD CAP_DROP RO MEMORY PIDS NNP SOCKET DEVIATIONS
for id in $ids; do
  j=$(docker inspect "$id")
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<< "$j")
  user=$(jq -r '.[0].Config.User // ""' <<< "$j")
  priv=$(jq -r '.[0].HostConfig.Privileged' <<< "$j")
  capadd=$(jq -r '(.[0].HostConfig.CapAdd // []) | join(",")' <<< "$j")
  capdrop=$(jq -r '(.[0].HostConfig.CapDrop // []) | join(",")' <<< "$j")
  ro=$(jq -r '.[0].HostConfig.ReadonlyRootfs' <<< "$j")
  mem=$(jq -r '.[0].HostConfig.Memory' <<< "$j")
  pids=$(jq -r '.[0].HostConfig.PidsLimit // 0' <<< "$j")
  nnp=$(jq -r '[.[0].HostConfig.SecurityOpt // [] | .[] | select(test("no-new-privileges(:true|=true)?$"))] | length > 0' <<< "$j")
  sock=$(jq -r '[.[0].Mounts[] | select(.Source | test("docker\\.sock$"))] | length > 0' <<< "$j")

  dev=()
  [[ -z "$user" || "$user" =~ ^(root|0)(:.*)?$ ]] && dev+=(root)
  [ "$priv" = true ] && dev+=(privileged)
  [[ ",$capdrop," == *",ALL,"* ]] || dev+=(no-cap-drop-all)
  [ "$ro" = true ] || dev+=(rootfs-rw)
  [ "$mem" -gt 0 ] || dev+=(no-mem-limit)
  [ "$pids" -gt 0 ] || dev+=(no-pids-limit)
  [ "$nnp" = true ] || dev+=(no-nnp)
  if [ "$sock" = true ] && [[ " ${AUDIT_SOCKET_OK:-} " != *" $name "* ]]; then dev+=(docker-socket); fi

  total=$((total + ${#dev[@]}))
  status=$([ ${#dev[@]} -eq 0 ] && printf '\e[32mOK\e[0m' || printf '\e[31m%s\e[0m' "$(IFS=,; echo "${dev[*]}")")
  printf '%-26s %-8s %-5s %-14s %-12s %-3s %-9s %-6s %-4s %-6s %b\n' \
    "${name:0:26}" "${user:-root}" "$priv" "${capadd:--}" "${capdrop:--}" \
    "$([ "$ro" = true ] && echo y || echo n)" "$([ "$mem" -gt 0 ] && echo "$((mem / 1048576))M" || echo none)" \
    "$([ "$pids" -gt 0 ] && echo "$pids" || echo none)" "$([ "$nnp" = true ] && echo y || echo n)" \
    "$([ "$sock" = true ] && echo YES || echo no)" "$status"
done
echo "total deviations: $total"
[ "$total" -eq 0 ]
