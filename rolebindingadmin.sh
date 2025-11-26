#!/usr/bin/env bash
set -euo pipefail

# Konfiguracja – jakie grupy chcemy obsługiwać
GROUPS=("" "")


# DRY_RUN=true -> tylko loguje co BY zrobił, ale NIC nie zmienia
DRY_RUN=true

echo "==> Grupy do obsługi: ${GROUPS[*]}"
echo

# Mała funkcja pomocnicza: sprawdza, czy user jest w grupie
user_in_group() {
  local user="$1"
  local group="$2"

  echo "      [DEBUG] sprawdzam czy ${user} jest w grupie ${group}..."

  # Pobieramy listę userów z grupy
  local users
  users=$(oc get group "${group}" -o jsonpath='{.users[*]}' 2>/dev/null || true)

  echo "      [DEBUG] users w grupie ${group}: ${users}"

  # Dopasowanie "na całe słowo"
  if grep -qw "${user}" <<< "${users}"; then
    return 0
  else
    return 1
  fi
}

echo "==> Przetwarzanie projektów..."
echo

# Bierzemy wszystkie projekty (bez nagłówka)
oc get projects --no-headers -o custom-columns=:metadata.name | while read -r ns; do
  [[ -z "$ns" ]] && continue

  # Pomijamy systemowe, jeśli nie chcesz ich ruszać
  if [[ "$ns" == kube-* || "$ns" == openshift-* || "$ns" == default ]]; then
    echo "[${ns}] projekt systemowy – pomijam"
    continue
  fi

  # Kto stworzył projekt?
  requester=$(oc get project "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/requester}' 2>/dev/null || echo "")

  if [[ -z "$requester" ]]; then
    echo "[${ns}] brak anotacji openshift.io/requester – pomijam"
    continue
  fi

  echo "[${ns}] requester: ${requester}"

  # Sprawdzamy każdą z naszych grup
  for grp in "${GROUPS[@]}"; do
    if user_in_group "${requester}" "${grp}"; then
      rb_name="${grp}-admin"

      echo "   -> requester jest w grupie ${grp}"

      # Czy RoleBinding już istnieje?
      if oc get rolebinding "${rb_name}" -n "${ns}" >/dev/null 2>&1; then
        echo "      RoleBinding ${rb_name} już istnieje – OK"
      else
        echo "      Brak RoleBinding ${rb_name} – trzeba dodać"

        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "      (DRY_RUN) oc create rolebinding ${rb_name} --clusterrole=admin --group=${grp} -n ${ns}"
        else
          oc create rolebinding "${rb_name}" \
            --clusterrole=admin \
            --group="${grp}" \
            -n "${ns}"
        fi
      fi
    else
      echo "   -> requester NIE jest w grupie ${grp}"
    fi
  done

  echo
done