apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-secrets-developer
rules:
- apiGroups: ["external-secrets.io"]
  resources: ["externalsecrets", "secretstores", "pushsecrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"] # Pozwala podglądać wygenerowane sekrety

  oc adm policy add-role-to-user external-secrets-developer <USER_NAME> -n <MY_APP_PROJECT>