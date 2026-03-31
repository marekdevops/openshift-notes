#!/bin/bash

# Nagłówek tabeli
printf "%-25s %-35s %-20s %-30s\n" "NAMESPACE" "PVC NAME" "NFS SERVER" "NFS PATH"
printf "%-25s %-35s %-20s %-30s\n" "---------" "--------" "----------" "--------"

# Pobieranie danych o PV, które mają zdefiniowaną sekcję NFS
oc get pv -o json | jq -r '
  .items[] 
  | select(.spec.nfs != null) 
  | [
      (.spec.claimRef.namespace // "N/A"), 
      (.spec.claimRef.name // "N/A"), 
      .spec.nfs.server, 
      .spec.nfs.path
    ] 
  | @tsv' | while IFS=$'\t' read -r ns pvc server path; do
    printf "%-25s %-35s %-20s %-30s\n" "$ns" "$pvc" "$server" "$path"
done