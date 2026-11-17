#!/bin/sh
# azure-runcommand-jdk-8392044.sh -- run the JDK-8392044 detector on Azure VMs.
#
# Uses `az vm run-command invoke` (synchronous), no SSH, no install: the detector
# is sent as the script and run on the VM by the VM agent. Linux VMs
# (RunShellScript); for Windows VMs use RunPowerShellScript with
# Detect-Jdk8392044.ps1 (see the note at the bottom).
#
# Needs: Azure CLI logged in (`az login`), "Virtual Machine Contributor" on the
# targets, and the VM agent running on each VM.
#
# Usage:
#   sh azure-runcommand-jdk-8392044.sh -g myResourceGroup [results_dir]
#   sh azure-runcommand-jdk-8392044.sh -g myRg --name vm1 [results_dir]
#
# Each VM's output goes to results_dir/<vm>.txt. The verdict is the detector's
# last verdict line found in the run-command message. An impacted/unknown/not
# impacted/error roll-up prints; exit 1 if any impacted, else 2 if any
# unknown/error, else 0.
set -u

SCRIPT=${DETECT:-$(dirname "$0")/detect-jdk-8392044.sh}
RG=""; NAME=""; OUT="results"

while [ $# -gt 0 ]; do
    case "$1" in
        -g|--resource-group) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 3; }; RG=$2; shift ;;
        --name) [ $# -ge 2 ] || { echo "--name needs a value" >&2; exit 3; }; NAME=$2; shift ;;
        -*) echo "unknown option: $1" >&2; exit 3 ;;
        *) OUT=$1 ;;
    esac
    shift
done

[ -n "$RG" ] || { echo "specify -g RESOURCE_GROUP" >&2; exit 3; }
[ -f "$SCRIPT" ] || { echo "detector not found at $SCRIPT (set DETECT=...)" >&2; exit 3; }
command -v az >/dev/null 2>&1 || { echo "az CLI not found" >&2; exit 3; }
mkdir -p "$OUT" || exit 3

if [ -n "$NAME" ]; then
    VMS=$NAME
else
    VMS=$(az vm list -g "$RG" --query '[].name' -o tsv) || { echo "az vm list failed" >&2; exit 3; }
fi
[ -n "$VMS" ] || { echo "no VMs found in resource group $RG" >&2; exit 2; }

imp=0; unk=0; ok=0; err=0
for vm in $VMS; do
    msg=$(az vm run-command invoke -g "$RG" -n "$vm" \
            --command-id RunShellScript --scripts @"$SCRIPT" \
            --query 'value[0].message' -o tsv 2>"$OUT/$vm.err")
    printf '%s\n' "$msg" > "$OUT/$vm.txt"
    [ -s "$OUT/$vm.err" ] || rm -f "$OUT/$vm.err"
    v=$(printf '%s\n' "$msg" | grep -E '^(impacted|not impacted|unknown)$' | tail -1)
    case "$v" in
        impacted) imp=$((imp + 1)); echo "  impacted:     $vm" ;;
        "not impacted") ok=$((ok + 1)) ;;
        unknown) unk=$((unk + 1)); echo "  unknown:      $vm" ;;
        *) err=$((err + 1)); echo "  error:        $vm (no verdict; see $OUT/$vm.txt)" ;;
    esac
done

echo "JDK-8392044 via Azure Run Command: $imp impacted, $unk unknown, $ok not impacted, $err error"
echo "per-VM output in $OUT/"
[ "$imp" -gt 0 ] && exit 1
{ [ "$unk" -gt 0 ] || [ "$err" -gt 0 ]; } && exit 2
exit 0
