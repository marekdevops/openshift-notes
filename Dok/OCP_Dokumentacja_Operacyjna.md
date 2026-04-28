# Infrastruktura OpenShift — Dokumentacja Operacyjna

> **Przeznaczenie:** Dokumentacja dla operatorów infrastruktury. Nie wymaga głębokiej znajomości OpenShift.
> **Zakres:** Klastry baremetal (TEST i PROD) + zagnieżdżone klastry aplikacyjne w OpenShift Virtualization.
> **Ostatnia aktualizacja:** `[DATA]` | **Autor:** `[IMIĘ NAZWISKO]`

---

## Spis treści

1. [Przegląd architektury](#1-przegląd-architektury)
2. [Dostęp do środowisk](#2-dostęp-do-środowisk)
3. [Codzienny monitoring — co sprawdzać](#3-codzienny-monitoring)
4. [OpenShift Virtualization — zarządzanie maszynami wirtualnymi](#4-openshift-virtualization--zarządzanie-maszynami-wirtualnymi)
5. [Namespacy i aplikacje](#5-namespacy-i-aplikacje)
6. [Storage — Portworx + Pure Storage](#6-storage--portworx--pure-storage)
7. [Procedury awaryjne — drzewo decyzyjne](#7-procedury-awaryjne)
8. [Ściągawka komend `oc`](#8-ściągawka-komend-oc)

---

---

# 1. Przegląd architektury

## 1.1 Diagram ogólny

```
┌─────────────────────────────────────────────────────────────┐
│                    INFRASTRUKTURA FIZYCZNA                  │
│                                                             │
│   ┌──────────────────────┐   ┌──────────────────────────┐  │
│   │  Klaster BAREMETAL   │   │  Klaster BAREMETAL       │  │
│   │       TEST           │   │       PROD               │  │
│   │                      │   │                          │  │
│   │  ┌────────────────┐  │   │  ┌────────────────────┐  │  │
│   │  │ OCP Virt (VM)  │  │   │  │  OCP Virt (VM)     │  │  │
│   │  │ ┌────────────┐ │  │   │  │ ┌────────────────┐ │  │  │
│   │  │ │Klaster OCP │ │  │   │  │ │ Klaster OCP    │ │  │  │
│   │  │ │  test-app1 │ │  │   │  │ │  prod-app1     │ │  │  │
│   │  │ └────────────┘ │  │   │  │ └────────────────┘ │  │  │
│   │  │ ┌────────────┐ │  │   │  │ ┌────────────────┐ │  │  │
│   │  │ │Klaster OCP │ │  │   │  │ │ Klaster OCP    │ │  │  │
│   │  │ │  test-app2 │ │  │   │  │ │  prod-app2     │ │  │  │
│   │  │ └────────────┘ │  │   │  │ └────────────────┘ │  │  │
│   │  │     ...        │  │   │  │      ...           │  │  │
│   │  └────────────────┘  │   │  └────────────────────┘  │  │
│   │                      │   │                          │  │
│   │  Storage: Portworx   │   │  Storage: Portworx       │  │
│   └──────────┬───────────┘   └───────────┬──────────────┘  │
│              │                           │                  │
│              └─────────────┬─────────────┘                  │
│                            │                                │
│                  ┌─────────▼──────────┐                     │
│                  │  Pure Storage      │                     │
│                  │  (macierz SAN)     │                     │
│                  └────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

## 1.2 Tabela środowisk

| Środowisko | Typ klastra | URL Web Console | URL API | Przeznaczenie |
|---|---|---|---|---|
| Baremetal TEST | OCP (host) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Hosting VM testowych |
| Baremetal PROD | OCP (host) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Hosting VM produkcyjnych |
| test-app1 | OCP (VM) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Środowisko testowe aplikacji 1 |
| test-app2 | OCP (VM) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Środowisko testowe aplikacji 2 |
| prod-app1 | OCP (VM) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Środowisko produkcyjne aplikacji 1 |
| prod-app2 | OCP (VM) | `https://[UZUPEŁNIJ]` | `https://api.[UZUPEŁNIJ]:6443` | Środowisko produkcyjne aplikacji 2 |

> 📝 **Uwaga:** Klastry "OCP (VM)" to pełnoprawne klastry OpenShift uruchomione jako maszyny wirtualne wewnątrz klastrów baremetal. Każdy z nich jest niezależny i posiada własną konsolę oraz API.

## 1.3 Dane dostępowe — vault / keepass

| Zasób | Lokalizacja danych dostępowych |
|---|---|
| Konta kubeadmin / service account | `[UZUPEŁNIJ — np. link do Vault / KeePass]` |
| Certyfikaty TLS | `[UZUPEŁNIJ]` |
| Klucze SSH do node'ów | `[UZUPEŁNIJ]` |

---

---

# 2. Dostęp do środowisk

## 2.1 Logowanie przez Web Console (przeglądarka)

Web Console to graficzny interfejs OpenShift — tutaj operator spędza większość czasu.

**Kroki:**

1. Otwórz przeglądarkę i wejdź na adres odpowiedniej konsoli (tabela w sekcji 1.2)
2. Na stronie logowania wybierz metodę uwierzytelniania: `[UZUPEŁNIJ — np. htpasswd / LDAP / SSO]`
3. Wprowadź login i hasło

> 📸 **[SCREENSHOT: Strona logowania Web Console — widok wyboru metody uwierzytelniania]**

4. Po zalogowaniu pojawi się strona główna — **"Administrator"** lub **"Developer"**. Operator powinien pracować w widoku **Administrator**.

> 📸 **[SCREENSHOT: Strona główna Web Console — widok Administrator, zaznacz przełącznik perspektywy w lewym górnym rogu]**

> ⚠️ **Ważne:** Klaster baremetal TEST i PROD oraz każdy zagnieżdżony klaster aplikacyjny mają **osobne** konsole i osobne dane logowania. Upewnij się, że logujesz się do właściwego środowiska.

---

## 2.2 Logowanie przez CLI (`oc`)

Narzędzie `oc` pozwala zarządzać klastrem z wiersza poleceń. Jest wymagane do bardziej zaawansowanych operacji.

### Wymagania wstępne

- Zainstalowane narzędzie `oc` (pobierz z: Web Console → znak `?` → Command Line Tools)
- Dostęp sieciowy do API klastra (port 6443)

### Logowanie

```bash
# Składnia ogólna
oc login https://api.[NAZWA_KLASTRA]:6443 --username=[TWÓJ_LOGIN]

# Przykład dla klastra baremetal TEST
oc login https://api.[BM-TEST]:6443 --username=operator

# Logowanie tokenem (zalecane dla automatyzacji)
oc login https://api.[NAZWA_KLASTRA]:6443 --token=[TOKEN]
```

> 📝 **Skąd wziąć token?** Web Console → kliknij swój login (prawy górny róg) → **"Copy login command"** → wklej w terminalu

> 📸 **[SCREENSHOT: Web Console — menu użytkownika w prawym górnym rogu, zaznaczona opcja "Copy login command"]**

### Sprawdzenie aktualnego klastra

```bash
# Który klaster jest aktualnie aktywny?
oc whoami --show-server

# Pełne informacje o kontekście
oc config current-context
```

### Przełączanie między klastrami (kubeconfig)

Jeśli masz skonfigurowane dostępy do wielu klastrów:

```bash
# Lista dostępnych kontekstów
oc config get-contexts

# Przełączenie na inny klaster
oc config use-context [NAZWA_KONTEKSTU]
```

---

---

# 3. Codzienny monitoring

> 🎯 **Cel:** Operator powinien codziennie (lub przy każdej zmianie) sprawdzić poniższe punkty. Zajmuje to ~5–10 minut.

## 3.1 Zdrowie klastra — widok ogólny

### W Web Console

1. Zaloguj się do konsoli wybranego klastra
2. Przejdź do: **Home → Overview**
3. Sprawdź sekcję **"Cluster status"** — wszystko powinno być zielone

> 📸 **[SCREENSHOT: Home → Overview — widok "Cluster status" z zielonymi statusami komponentów]**

4. Zwróć uwagę na sekcję **"Alerts"** — aktywne alerty wymagają reakcji

> 📸 **[SCREENSHOT: Home → Overview — sekcja "Alerts", zaznacz gdzie widać liczbę aktywnych alertów]**

### Przez CLI

```bash
# Ogólny status klastra
oc get clusteroperators

# Wszystkie operatory powinny mieć: AVAILABLE=True, PROGRESSING=False, DEGRADED=False
# Jeśli któryś ma DEGRADED=True — wymaga uwagi
```

**Przykład prawidłowego output:**
```
NAME                         AVAILABLE   PROGRESSING   DEGRADED
authentication               True        False         False
console                      True        False         False
dns                          True        False         False
etcd                         True        False         False
...
```

---

## 3.2 Zużycie zasobów — CPU i RAM

### W Web Console

1. Przejdź do: **Observe → Dashboards**
2. Wybierz dashboard: **"Kubernetes / Compute Resources / Cluster"**

> 📸 **[SCREENSHOT: Observe → Dashboards — widok wyboru dashboardu, zaznacz "Kubernetes / Compute Resources / Cluster"]**

3. Kluczowe metryki do sprawdzenia:

| Metryka | Co oznacza | Alarm gdy |
|---|---|---|
| CPU Usage | Aktualne zużycie CPU | >80% przez dłużej niż 15 min |
| CPU Requests Commitment | % przydzielonego CPU do pojemności | >90% |
| Memory Usage | Aktualne zużycie RAM | >85% przez dłużej niż 15 min |
| Memory Requests Commitment | % przydzielonego RAM do pojemności | >90% |

> 📸 **[SCREENSHOT: Dashboard "Kubernetes / Compute Resources / Cluster" — widok z wykresami CPU i Memory]**

### Przez CLI

```bash
# Zużycie zasobów node'ów (fizycznych serwerów w klastrze)
oc adm top nodes

# Przykładowy output:
# NAME       CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# master-1   823m         10%    12456Mi          39%
# worker-1   2341m        29%    28123Mi          87%   ← wysoki RAM!
# worker-2   1102m        13%    15234Mi          47%

# Zużycie zasobów podów (aplikacji) w danym namespace
oc adm top pods -n [NAMESPACE]
```

---

## 3.3 Status node'ów (serwerów)

```bash
# Lista wszystkich node'ów i ich status
oc get nodes

# Wszystkie powinny mieć STATUS = Ready
# Przykład:
# NAME       STATUS   ROLES           AGE   VERSION
# master-1   Ready    master,worker   45d   v1.28.x
# master-2   Ready    master,worker   45d   v1.28.x
# worker-1   Ready    worker          45d   v1.28.x

# Szczegóły konkretnego node'a (gdy coś jest nie tak)
oc describe node [NAZWA_NODE'A]
```

> 📸 **[SCREENSHOT: Web Console — Compute → Nodes — tabela node'ów z kolumną Status]**

---

## 3.4 Alerty — gdzie patrzeć

### W Web Console

1. Przejdź do: **Observe → Alerting**
2. Zakładka **"Alerts"** — lista wszystkich aktywnych alertów
3. Zakładka **"Silences"** — alerty tymczasowo wyciszone (sprawdź czy nie przeterminowane)

> 📸 **[SCREENSHOT: Observe → Alerting — zakładka "Alerts", widok tabeli z alertami i ich severity]**

**Priorytety alertów:**

| Severity | Kolor | Co robić |
|---|---|---|
| Critical | 🔴 Czerwony | Natychmiastowa reakcja, eskalacja |
| Warning | 🟡 Żółty | Sprawdzić przyczynę w ciągu 24h |
| Info | 🔵 Niebieski | Informacyjny, monitorować |

---

---

# 4. OpenShift Virtualization — zarządzanie maszynami wirtualnymi

> 📝 **Kontekst:** Wewnątrz klastrów baremetal (TEST i PROD) działają maszyny wirtualne. Każda VM to zazwyczaj cały klaster OpenShift uruchomiony "w środku". Do zarządzania VM-ami używamy modułu **OpenShift Virtualization** dostępnego z poziomu Web Console klastra baremetal.

## 4.1 Gdzie znaleźć maszyny wirtualne

1. Zaloguj się do konsoli **klastra baremetal** (TEST lub PROD)
2. W menu po lewej: **Virtualization → VirtualMachines**

> 📸 **[SCREENSHOT: Menu boczne — zaznaczona sekcja "Virtualization" i podmenu "VirtualMachines"]**

3. Zobaczysz listę wszystkich maszyn wirtualnych pogrupowanych według namespace'ów

> 📸 **[SCREENSHOT: Virtualization → VirtualMachines — tabela VM z kolumnami: Name, Namespace, Status, Node, IP]**

### Tabela VM — co oznaczają statusy

| Status | Ikona | Opis |
|---|---|---|
| Running | 🟢 Zielony | VM działa normalnie |
| Stopped | ⚫ Szary | VM zatrzymana (wyłączona) |
| Starting | 🔄 Animacja | VM jest uruchamiana |
| Stopping | 🔄 Animacja | VM jest zatrzymywana |
| Migrating | 🔄 Animacja | VM jest przenoszona na inny node |
| Error | 🔴 Czerwony | Problem — wymaga diagnozy |
| Paused | 🟡 Żółty | VM wstrzymana (zamrożona) |

---

## 4.2 Inwentarz VM — tabela referencyjna

| Nazwa VM | Namespace | Typ klastra wewnątrz | Środowisko | Uwagi |
|---|---|---|---|---|
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | OCP | test-app1 | |
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | OCP | test-app2 | |
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | OCP | prod-app1 | ⚠️ Produkcja |
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | OCP | prod-app2 | ⚠️ Produkcja |

---

## 4.3 Restart maszyny wirtualnej

> ⚠️ **Uwaga dla środowisk produkcyjnych:** Restart VM oznacza restart całego klastra OCP działającego wewnątrz. Wszystkie aplikacje na tym klastrze będą niedostępne podczas restartu. Wymaga **okna serwisowego** i powiadomienia odpowiednich zespołów.

### Przez Web Console (zalecane)

1. Przejdź do: **Virtualization → VirtualMachines**
2. Znajdź właściwą VM na liście
3. Kliknij w **trzy kropki (⋮)** po prawej stronie wiersza
4. Wybierz odpowiednią akcję:

| Akcja | Kiedy używać |
|---|---|
| **Restart** | Miękki restart — OS dostaje sygnał restartu (zalecane) |
| **Stop** + **Start** | Twardy restart — jak wyjęcie wtyczki (gdy VM nie odpowiada) |
| **Pause** | Chwilowe zamrożenie VM (bez wyłączania) |
| **Migrate** | Przeniesienie VM na inny fizyczny node (bez wyłączania) |

> 📸 **[SCREENSHOT: Virtualization → VirtualMachines — menu kontekstowe (trzy kropki) z opcjami Restart/Stop/Start/Pause/Migrate]**

5. Potwierdź akcję w oknie dialogowym
6. Obserwuj zmianę statusu VM w tabeli

### Przez CLI

```bash
# Restart VM (miękki — jak "reboot" w systemie)
virtctl restart [NAZWA_VM] -n [NAMESPACE]

# Stop VM
virtctl stop [NAZWA_VM] -n [NAMESPACE]

# Start VM
virtctl start [NAZWA_VM] -n [NAMESPACE]

# Przykład:
virtctl restart ocp-prod-app1-master-1 -n virtualization-prod
```

---

## 4.4 Konsola VM (dostęp do ekranu)

Gdy VM jest uruchomiona, możesz połączyć się z jej konsolą graficzną — jak monitor podłączony bezpośrednio do serwera.

1. Przejdź do: **Virtualization → VirtualMachines**
2. Kliknij w **nazwę VM** (nie w trzy kropki)
3. Przejdź do zakładki **"Console"**

> 📸 **[SCREENSHOT: Szczegóły VM — zakładka "Console" z widokiem terminala/ekranu maszyny]**

> 📝 **Uwaga:** Konsola VNC jest przydatna gdy VM jest niedostępna przez sieć (np. po awarii sieci wewnątrz VM). Normalna praca odbywa się przez SSH lub konsolę OCP wewnątrz VM.

---

## 4.5 Zasoby VM — sprawdzenie wykorzystania

1. Kliknij w **nazwę VM** → zakładka **"Metrics"**
2. Dostępne wykresy: CPU, RAM, sieć, dysk

> 📸 **[SCREENSHOT: Szczegóły VM — zakładka "Metrics" z wykresami wykorzystania zasobów]**

Przez CLI:
```bash
# Status i podstawowe info o VM
oc get vm [NAZWA_VM] -n [NAMESPACE]

# Szczegółowy opis VM
oc describe vm [NAZWA_VM] -n [NAMESPACE]

# Status uruchomionej instancji VM (VMI = VirtualMachineInstance)
oc get vmi -n [NAMESPACE]
```

---

---

# 5. Namespacy i aplikacje

> 📝 **Co to jest namespace?** Namespace to wyizolowana przestrzeń w OpenShift, gdzie działają aplikacje. Można to porównać do oddzielnych "folderów" — aplikacje w jednym namespace domyślnie nie widzą innych. Każde środowisko aplikacyjne ma swoje namespacy.

## 5.1 Lista namespace'ów — nawigacja

### W Web Console

1. Przejdź do: **Home → Projects** (Projects = Namespaces w OCP)
2. Zobaczysz listę wszystkich namespace'ów

> 📸 **[SCREENSHOT: Home → Projects — tabela projektów z kolumnami Name, Status, Created]**

3. Kliknij w nazwę projektu, żeby przejść do jego zasobów

### Przez CLI

```bash
# Lista wszystkich namespace'ów
oc get projects

# Przełączenie na konkretny namespace (wszystkie kolejne komendy działają w tym kontekście)
oc project [NAZWA_NAMESPACE]

# Sprawdzenie aktualnego namespace
oc project
```

---

## 5.2 Namespacy systemowe vs aplikacyjne

> ⚠️ **Nigdy nie modyfikuj** namespace'ów systemowych bez konsultacji z administratorem.

| Typ | Przykłady | Opis |
|---|---|---|
| Systemowe (nie ruszać) | `openshift-*`, `kube-*`, `default` | Infrastruktura klastra |
| Aplikacyjne | `[UZUPEŁNIJ — np. app-frontend, app-backend]` | Twoje aplikacje |
| Virtualization | `[UZUPEŁNIJ — np. openshift-cnv, vms-prod]` | VM-y OpenShift Virt |

---

## 5.3 Tabela namespace'ów aplikacyjnych

> Uzupełnij poniższą tabelę dla każdego klastra aplikacyjnego.

**Klaster: `[NAZWA_KLASTRA]`**

| Namespace | Aplikacja | Zespół właścicielski | Kontakt |
|---|---|---|---|
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |
| `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |

---

## 5.4 Stan aplikacji — podstawowa weryfikacja

Po zalogowaniu do wybranego klastra aplikacyjnego:

### Sprawdzenie podów (aplikacji)

```bash
# Lista podów w namespace
oc get pods -n [NAMESPACE]

# Prawidłowy status to: Running (lub Completed dla zadań jednorazowych)
# Nieprawidłowe stany: CrashLoopBackOff, Error, Pending, ImagePullBackOff

# Jeśli pod ma problem — sprawdź logi
oc logs [NAZWA_PODA] -n [NAMESPACE]

# Jeśli pod ma wiele kontenerów
oc logs [NAZWA_PODA] -c [NAZWA_KONTENERA] -n [NAMESPACE]
```

### W Web Console

1. Przejdź do: **Workloads → Pods**
2. W górze ekranu wybierz namespace z listy rozwijanej
3. Sprawdź kolumnę **"Status"** — wszystkie powinny być zielone (Running)

> 📸 **[SCREENSHOT: Workloads → Pods — tabela podów z kolorami statusów, zaznaczona lista rozwijana namespace'u na górze]**

---

## 5.5 Restarty podów — kiedy i jak

> ⚠️ Ręczny restart poda powinien być ostatecznością. Jeśli pod ciągle restartuje — to symptom problemu, nie sam problem.

```bash
# Restart poda przez jego usunięcie (zostanie automatycznie odtworzony)
oc delete pod [NAZWA_PODA] -n [NAMESPACE]

# Restart całego deploymentu (wszystkich podów aplikacji naraz)
oc rollout restart deployment/[NAZWA_DEPLOYMENTU] -n [NAMESPACE]

# Sprawdzenie historii restartów
oc get pods -n [NAMESPACE] | grep -v Running
# Kolumna RESTARTS pokaże ile razy pod się restartował
```

---

---

# 6. Storage — Portworx + Pure Storage

> 📝 **Kontekst:** Storage w tej infrastrukturze działa dwuwarstwowo: macierz Pure Storage (fizyczne dyski SAN) jest podłączona do klastrów baremetal przez Portworx (PX-CSI). Maszyny wirtualne i pody korzystają z wolumenów (PVC) tworzonych dynamicznie.

## 6.1 Podstawowe pojęcia

| Pojęcie | Opis |
|---|---|
| **PV** (PersistentVolume) | Fizyczny wolumen — kawałek dysku z macierzy |
| **PVC** (PersistentVolumeClaim) | Żądanie dysku przez aplikację — "daj mi 100GB" |
| **StorageClass** | Profil dysku — definiuje typ i parametry (np. `portworx-thick`) |

---

## 6.2 Sprawdzenie statusu wolumenów

```bash
# Lista wszystkich PVC w namespace (czy są podłączone?)
oc get pvc -n [NAMESPACE]

# STATUS powinien być: Bound
# Nieprawidłowe: Pending (nie udało się przydzielić dysku), Lost

# Lista wszystkich PV w klastrze
oc get pv

# Szczegóły konkretnego PVC
oc describe pvc [NAZWA_PVC] -n [NAMESPACE]
```

### W Web Console

1. **Storage → PersistentVolumeClaims**
2. Wybierz namespace
3. Kolumna "Status" — wszystkie powinny być **Bound**

> 📸 **[SCREENSHOT: Storage → PersistentVolumeClaims — tabela PVC z kolumną Status = Bound]**

---

## 6.3 Dostępne StorageClasses

```bash
# Lista klas storage
oc get storageclass

# Przykładowy output w tej infrastrukturze:
# NAME                  PROVISIONER              RECLAIMPOLICY   VOLUMEBINDINGMODE
# portworx-thick        pxd.portworx.com         Delete          Immediate
# portworx-csi-db       pxd.portworx.com         Retain          Immediate
```

---

## 6.4 Status Portworx

```bash
# Status podów Portworx (działają w namespace portworx lub kube-system)
oc get pods -n portworx

# Wszystkie pody px-* powinny być Running

# Status klastra Portworx (wymaga narzędzia pxctl lub przez pod)
oc exec -n portworx [NAZWA_PODA_PX] -- /opt/pwx/bin/pxctl status
```

> 📸 **[SCREENSHOT: Workloads → Pods w namespace "portworx" — lista podów px-* ze statusem Running]**

---

---

# 7. Procedury awaryjne

## 7.1 Drzewo decyzyjne — "coś nie działa"

```
Problem zgłoszony
       │
       ▼
Czy aplikacja jest niedostępna?
       │
   ┌───┴───┐
  TAK      NIE ──→ Sprawdź alerty (sekcja 3.4)
   │
   ▼
Zaloguj się do klastra OCP aplikacji (sekcja 2)
       │
       ▼
Sprawdź pody: oc get pods -n [NAMESPACE] (sekcja 5.4)
       │
   ┌───┴───────────────────┐
  Pody OK?               Pody Error/Pending?
   │                         │
   ▼                         ▼
Sprawdź Ingress/Route    oc logs [pod] -n [NS]
oc get routes -n [NS]    oc describe pod [pod] -n [NS]
   │                         │
   ▼                         ▼
Sprawdź DNS/sieć         CrashLoopBackOff?
                              │
                          ┌───┴───┐
                         TAK      NIE
                          │        │
                          ▼        ▼
                     Błąd aplik.  Pending?
                     Sprawdź logi  → Sprawdź PVC
                                   → Sprawdź node'y
                                   → Sprawdź zasoby
```

---

## 7.2 Procedura: VM nie odpowiada

**Objawy:** Klaster aplikacyjny wewnątrz VM jest niedostępny, konsola OCP nie odpowiada.

**Kroki:**

1. Zaloguj się do **konsoli klastra baremetal** (gdzie działa ta VM)
2. Przejdź do **Virtualization → VirtualMachines**
3. Sprawdź status VM:
   - `Running` → VM działa, problem może być wewnątrz (sieć, OS, OCP)
   - `Error` → VM ma problem, sprawdź eventy
   - `Stopped` → VM jest wyłączona, uruchom (Start)
4. Jeśli VM Running ale niedostępna — otwórz konsolę VNC (sekcja 4.4)
5. Jeśli konsola VNC pokazuje błędy OS — sprawdź dysk (storage)
6. Jeśli wszystko wygląda OK w konsoli — sprawdź routing sieciowy

**Eskalacja:** Jeśli VM nie uruchamia się po 10 minutach → `[KONTAKT ESKALACJI]`

---

## 7.3 Procedura: Node baremetal niedostępny

**Objawy:** `oc get nodes` pokazuje node w stanie `NotReady`.

```bash
# Sprawdź szczegóły node'a
oc describe node [NAZWA_NODE'A]

# Sprawdź zdarzenia na node
oc get events --field-selector involvedObject.name=[NAZWA_NODE'A]
```

**Kroki:**

1. Sprawdź fizyczny dostęp do serwera (IPMI/iDRAC/iLO) — `[UZUPEŁNIJ adres/login]`
2. Sprawdź logi systemowe przez IPMI
3. Jeśli serwer działa — sprawdź kubelet: `ssh [NODE] "systemctl status kubelet"`
4. Jeśli node jest `NotReady` ale działa — VM-y mogą zostać automatycznie przeniesione (Live Migration)

**Eskalacja:** `[KONTAKT ESKALACJI]`

---

## 7.4 Procedura: PVC w stanie Pending

**Objawy:** Aplikacja nie startuje, PVC nie jest przydzielone.

```bash
# Sprawdź dlaczego PVC jest Pending
oc describe pvc [NAZWA_PVC] -n [NAMESPACE]
# Sekcja "Events" powie co się dzieje

# Sprawdź czy Portworx działa (sekcja 6.4)
oc get pods -n portworx
```

**Częste przyczyny:**

| Przyczyna | Rozwiązanie |
|---|---|
| Portworx pod nie działa | Sprawdź logi px poda, eskaluj |
| Brak miejsca na macierzy | Sprawdź pojemność Pure Storage |
| Błędna StorageClass w PVC | Sprawdź definicję PVC (yaml) |

---

## 7.5 Kontakty i eskalacja

| Sytuacja | Kontakt | Telefon/Slack |
|---|---|---|
| Awaria klastra baremetal | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |
| Problem z macierzą Pure | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |
| Problem aplikacyjny | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |
| Awaria poza godzinami | `[UZUPEŁNIJ]` | `[UZUPEŁNIJ]` |

---

---

# 8. Ściągawka komend `oc`

## 8.1 Podstawowe operacje

```bash
# ─── LOGOWANIE ────────────────────────────────────────────────
oc login https://api.[KLASTER]:6443 --username=[USER]
oc whoami                          # kto jestem?
oc whoami --show-server            # do jakiego klastra?
oc logout                          # wylogowanie

# ─── NAMESPACE / PROJECT ──────────────────────────────────────
oc get projects                    # lista namespace'ów
oc project [NAMESPACE]             # przełącz namespace
oc project                         # aktualny namespace

# ─── NODE'Y ───────────────────────────────────────────────────
oc get nodes                       # lista node'ów i status
oc get nodes -o wide               # więcej szczegółów (IP, OS)
oc adm top nodes                   # zużycie CPU/RAM node'ów
oc describe node [NAZWA]           # szczegóły node'a

# ─── PODY ─────────────────────────────────────────────────────
oc get pods -n [NAMESPACE]                    # lista podów
oc get pods -n [NAMESPACE] -o wide            # + IP, node
oc get pods -A                                # wszystkie namespace'y
oc adm top pods -n [NAMESPACE]               # zużycie CPU/RAM
oc logs [POD] -n [NAMESPACE]                  # logi poda
oc logs [POD] -n [NAMESPACE] --tail=100       # ostatnie 100 linii
oc logs [POD] -n [NAMESPACE] -f               # logi na żywo (follow)
oc describe pod [POD] -n [NAMESPACE]          # szczegóły + eventy
oc delete pod [POD] -n [NAMESPACE]            # usuń pod (restart)
oc exec -it [POD] -n [NAMESPACE] -- bash      # wejdź do poda (shell)

# ─── DEPLOYMENTY ──────────────────────────────────────────────
oc get deployments -n [NAMESPACE]
oc rollout restart deployment/[NAZWA] -n [NAMESPACE]   # restart
oc rollout status deployment/[NAZWA] -n [NAMESPACE]    # postęp
oc rollout history deployment/[NAZWA] -n [NAMESPACE]   # historia

# ─── STORAGE ──────────────────────────────────────────────────
oc get pvc -n [NAMESPACE]          # wolumeny w namespace
oc get pv                          # wszystkie wolumeny w klastrze
oc get storageclass                # dostępne klasy storage
oc describe pvc [NAZWA] -n [NS]    # szczegóły wolumenu

# ─── EVENTY (ZDARZENIA) ───────────────────────────────────────
oc get events -n [NAMESPACE]                  # zdarzenia w namespace
oc get events -n [NAMESPACE] --sort-by='.lastTimestamp'  # posortowane
oc get events -A | grep Warning               # warningi ze wszystkich NS

# ─── OPERATORY KLASTRA ────────────────────────────────────────
oc get clusteroperators            # zdrowie operatorów systemowych
oc get clusterversion              # wersja klastra OCP

# ─── VIRTUALIZATION ───────────────────────────────────────────
oc get vm -n [NAMESPACE]           # lista VM
oc get vmi -n [NAMESPACE]          # lista uruchomionych instancji VM
virtctl start [VM] -n [NAMESPACE]  # uruchom VM
virtctl stop [VM] -n [NAMESPACE]   # zatrzymaj VM
virtctl restart [VM] -n [NAMESPACE] # restartuj VM
```

---

## 8.2 Diagnoza typowych problemów

```bash
# Pod w CrashLoopBackOff — co się stało?
oc logs [POD] -n [NS] --previous    # logi z poprzedniego uruchomienia

# Pod w stanie Pending — dlaczego nie startuje?
oc describe pod [POD] -n [NS]       # sekcja "Events" powie powód

# Sprawdzenie routingu (dostępności przez HTTP/HTTPS)
oc get routes -n [NAMESPACE]        # lista adresów URL aplikacji

# Sprawdzenie serwisów wewnętrznych
oc get services -n [NAMESPACE]

# Użycie zasobów przez namespace (top 10)
oc adm top pods -A --sort-by=memory | head -20
```

---

---

# Załączniki

## A. Słownik pojęć

| Pojęcie | Wyjaśnienie |
|---|---|
| **OpenShift (OCP)** | Platforma kontenerowa Red Hat — zarządza aplikacjami w kontenerach |
| **Node** | Fizyczny lub wirtualny serwer będący częścią klastra |
| **Pod** | Najmniejsza jednostka w OCP — zawiera jeden lub więcej kontenerów (aplikacji) |
| **Namespace / Project** | Izolowana przestrzeń dla grupy aplikacji |
| **Deployment** | Definicja jak uruchomić aplikację (ile podów, z jakiego obrazu itp.) |
| **PVC / PV** | Żądanie dysku / fizyczny dysk — mechanizm storage'u |
| **StorageClass** | Typ/profil dysku dostępny w klastrze |
| **Operator** | Aplikacja zarządzająca inną aplikacją lub funkcją klastra |
| **ClusterOperator** | Wbudowany operator zarządzający systemowym komponentem OCP |
| **Portworx (PX-CSI)** | Driver storage łączący OCP z macierzą Pure Storage |
| **OpenShift Virtualization** | Moduł OCP pozwalający uruchamiać maszyny wirtualne |
| **VM / VMI** | VirtualMachine (definicja) / VirtualMachineInstance (uruchomiona instancja) |
| **virtctl** | Narzędzie CLI do zarządzania VM w OpenShift Virtualization |
| **Ingress / Route** | Mechanizm udostępniania aplikacji na zewnątrz (HTTP/HTTPS) |

---

## B. Historia zmian dokumentu

| Data | Autor | Opis zmiany |
|---|---|---|
| `[DATA]` | `[IMIĘ]` | Pierwsza wersja dokumentu |

---

*Dokument wygenerowany jako szablon — wymaga uzupełnienia danych środowiskowych oznaczonych `[UZUPEŁNIJ]`.*
