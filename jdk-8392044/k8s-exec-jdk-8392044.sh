#!/bin/sh
# k8s-exec-jdk-8392044.sh -- kubectl exec the JDK-8392044 detector into every
# running container. For clusters that forbid the privileged DaemonSet.
#
# Needs only the right to list pods and to exec into them. The detector is piped
# in over stdin and run in memory; nothing is copied into the container. It needs
# bash IN the container; containers without bash (distroless, some Alpine) are
# reported unknown -- use the DaemonSet (k8s-jdk-8392044.yaml) for those.
#
# Usage:
#   sh k8s-exec-jdk-8392044.sh > results.txt                 # all namespaces
#   sh k8s-exec-jdk-8392044.sh -n payments > results.txt     # one namespace (any kubectl get pods opts)
#
# Prints a per-container block (the detector's output) and a roll-up. Exits 1 if
# any container is impacted, else 2 if any unknown, else 0.
set -u

SCRIPT=${DETECT:-$(dirname "$0")/detect-jdk-8392044.sh}
[ -f "$SCRIPT" ] || { echo "detector not found at $SCRIPT (set DETECT=/path/to/detect-jdk-8392044.sh)" >&2; exit 3; }
[ $# -gt 0 ] || set -- -A

NL='
'
LIST=$(kubectl get pods "$@" --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$pod := .metadata.name}}{{$node := .spec.nodeName}}{{range .spec.containers}}{{$ns}} {{$pod}} {{.name}} {{$node}}{{"\n"}}{{end}}{{end}}') || exit 3

imp=0; unk=0; ok=0
IFS=$NL
for line in $LIST; do
    IFS=' '
    # shellcheck disable=SC2086
    set -- $line
    ns=$1; pod=$2; ctr=$3; node=$4
    printf '=== %s/%s/%s (node %s) ===\n' "$ns" "$pod" "$ctr" "$node"
    if kubectl exec -n "$ns" "$pod" -c "$ctr" -- sh -c 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
        out=$(kubectl exec -i -n "$ns" "$pod" -c "$ctr" -- bash -s -- -q < "$SCRIPT" 2>/dev/null)
        printf '%s\n' "$out"
        case "$(printf '%s\n' "$out" | tail -1)" in
            impacted) imp=$((imp + 1)) ;;
            "not impacted") ok=$((ok + 1)) ;;
            *) unk=$((unk + 1)) ;;
        esac
    else
        echo "unknown: no bash in this container; use the DaemonSet (k8s-jdk-8392044.yaml)"
        unk=$((unk + 1))
    fi
    IFS=$NL
done
IFS=' '

echo "---"
echo "JDK-8392044 containers: $imp impacted, $unk unknown, $ok not impacted"
[ "$imp" -gt 0 ] && exit 1
[ "$unk" -gt 0 ] && exit 2
exit 0
