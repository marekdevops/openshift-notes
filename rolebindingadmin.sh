#!/usr/bin/env bash
set -euo pipefail

# Konfiguracja – jakie grupy chcemy obsługiwać
GROUPS=("" "")

# DRY_RUN=true -> tylko pokazuje co by zrobił, ale NIC nie zmienia
DRY_RUN=true

echo "==> Ładowanie użytkowników z grup LDAP/OS: ${GROUPS[*]}"

declare -A GROUP_USERS

for grp in "${GROUPS[@]}"; do
  echo "   - grupa: $grp"
  # Pobieramy listę userów z grupy (jako proste stringi)
  users=$(oc get group "$grp" -o json 2>/dev/null | jq -r '.users[]?' || true)

  if [[ -z "${users}" ]]; then
    echo "     (brak użytkowników albo grupa nie istnieje)"
  fi

  # Zapisujemy w asocjacyjnej tablicy (lista rozdzielona spacjami)
  GROUP_USERS["$grp"]="$users"
done

echo
echo "==> Przetwarzanie projektów..."

# Lista wszystkich projektów
oc get projects -o json | jq -r '.items[].metadata.name' | while read -r ns; do
  [[ -z "$ns" ]] && continue

  # Odczytujemy kto stworzył projekt
  requester=$(oc get project "$ns" -o json \
    | jq -r '.metadata.annotations["openshift.io/requester"] // empty')

  if [[ -z "$requester" ]]; then
    # np. stary projekt systemowy
    echo "[${ns}] brak anotacji openshift.io/requester – pomijam"
    continue
  fi

  echo "[${ns}] requester: ${requester}"

  # Sprawdzamy w jakich z naszych grup jest requester
  for grp in "${GROUPS[@]}"; do
    users="${GROUP_USERS[$grp]:-}"

    if grep -qx "$requester" <<< "$users"; then
      rb_name="${grp}-admin"

      # Sprawdzamy, czy RoleBinding już istnieje
      if oc get rolebinding "$rb_name" -n "$ns" >/dev/null 2>&1; then
        echo "   -> requester jest w grupie ${grp}, ale RoleBinding ${rb_name} już istnieje – OK"
      else
        echo "   -> requester jest w grupie ${grp}, brak RoleBinding ${rb_name} – TRZEBA DODAĆ"

        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "      (DRY_RUN) oc create rolebinding ${rb_name} --clusterrole=admin --group=${grp} -n ${ns}"
        else
          oc create rolebinding "${rb_name}" \
            --clusterrole=admin \
            --group="${grp}" \
            -n "${ns}"
        fi
      fi
    fi
  done

done
