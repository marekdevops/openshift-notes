#!/bin/bash

echo -e "NAMESPACE\tPOD\tNODE\tPVC\tMOUNT_PATH"

oc get pods -A -o json | jq -r '
  .items[]
  | select(.spec.volumes[]? | has("persistentVolumeClaim"))
  | . as $pod
  | $pod.spec.volumes[]
  | select(.persistentVolumeClaim)
  | {
      namespace: $pod.metadata.namespace,
      pod: $pod.metadata.name,
      node: ($pod.spec.nodeName // "NotScheduled"),
      pvc: .persistentVolumeClaim.claimName,
      path: (
        $pod.spec.containers[]
        | .volumeMounts[]
        | select(.name == .name)
        | .mountPath
      )
    }
  | [.namespace, .pod, .node, .pvc, .path]
  | @tsv'
