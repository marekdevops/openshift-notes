# Analiza odtwarzania klastrów OpenShift — DR/BCP

## Wersja robocza, kwiecień 2026

---

## 1. Podsumowanie wykonawcze

**Obecny poziom dojrzałości DR: niski.**

Środowisko ma solidne fundamenty fizyczne (dwa DC, stretched VMware, druga macierz Pure dostępna, światłowód), ale praktycznie zero warstwy software'owej DR. W szczególności:

- **Nie ma backupu etcd** — to najpoważniejsza luka. W przypadku korupcji etcd parent klastra nie da się go odtworzyć.
- **Nie ma OADP/Velero** — żadnej aplikacji ani PV nie da się odtworzyć z backupu.
- **Druga macierz nie jest skonfigurowana** — fizyczny SPOF na poziomie storage.
- **Brak IaaC** — odtworzenie konfiguracji klastrów to ręczna robota.

Trzy najpilniejsze rzeczy do wdrożenia w ciągu najbliższych 2 tygodni:

1. Automatyczny backup etcd (parent + każdy child) z retencją.
2. OADP z backupem do zewnętrznego S3/MinIO.
3. Eksport krytycznych konfiguracji do Git (nawet "as-is", bez refaktoringu).

---

## 2. Inwentaryzacja stanu obecnego

### 2.1. Architektura warstwowa

```
┌──────────────────────────────────────────────────────────┐
│  Parent klaster OCP (Bare Metal)                          │
│  ├── Control plane + Infra: VMware (DC1 + DC2 stretched)  │
│  ├── Workers: bare metal (połowa DC1 / połowa DC2)        │
│  ├── PX-CSI → Pure FlashArray (DC1, FC)                   │
│  ├── OCP Virtualization (KubeVirt)                        │
│  └── HAProxy (LB)                                          │
│                                                            │
│  Sieć: VLAN 100 (BM), VLAN 110 (apps), Multus bridges     │
└──────────────────────────────────────────────────────────┘
                          │
                          │  KubeVirt VM
                          ▼
┌──────────────────────────────────────────────────────────┐
│  6× Child klaster OCP (każdy w osobnym namespace)         │
│  ├── Control plane + Workers: VM na parent klastrze       │
│  ├── LVMS (lokalny storage z Pure przez parent)           │
│  ├── Aplikacje (Kafka 3 repliki, inne)                    │
│  └── F5 (LB)                                               │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
       Bazy danych: AIX (zewnętrzne, poza klastrem)
```

### 2.2. Tabela komponentów

| Komponent | HA wewn. | Backup | Replika DR | IaaC | Status |
|---|---|---|---|---|---|
| Parent etcd | 3 nody | ❌ brak | ❌ | częściowo (Ansible) | **KRYTYCZNE** |
| Child etcd ×6 | 3 nody/klaster | ❌ brak | ❌ | częściowo | **KRYTYCZNE** |
| Pure FlashArray (DC1) | wewn. RAID | ⚠️ snapshoty? | ❌ brak repliki | n/d | **WYSOKIE** |
| Pure FlashArray (DC2) | dostępna | n/d | n/d | n/d | nieskonfigurowana |
| VMware (control/infra) | stretched | ⚠️ vCenter? | częściowo | ❌ | średnie |
| Bare metal workers | rozłożone DC1/DC2 | n/d | n/d | częściowo | OK |
| HAProxy (parent LB) | ? sprawdzić | ❌ konfig | ❌ | ❌ | nieznane |
| F5 (child LB) | tak | ❌ konfig | ❌ | ❌ | średnie |
| Konfiguracja klastra | n/d | ❌ | ❌ | ❌ pliki | **WYSOKIE** |
| Certyfikaty | n/d | ⚠️ pliki | ❌ | ❌ | **WYSOKIE** |
| MachineConfigy | n/d | ❌ | ❌ | ❌ | wysokie |
| Aplikacje (manifesty) | n/d | ⚠️ częśc. ArgoCD | ❌ | częśc. | średnie |
| PV / dane aplikacji | n/d | ❌ brak | ❌ | n/d | **WYSOKIE** |
| Image registry | ? | ❌ | ❌ | ❌ | nieznane |
| DNS (AD) | zależy od AD | n/d | n/d | n/d | zależność zewn. |
| LDAP/AD | zależy od AD | n/d | n/d | n/d | zależność zewn. |
| Bazy danych (AIX) | poza zakresem | poza zakresem | ? | n/d | poza zakresem |

### 2.3. Co działa dobrze

- Stretched VMware na dwóch DC ze światłowodem
- Bare metal workery rozłożone DC1/DC2
- Druga macierz Pure fizycznie istnieje
- Kafka ma własną replikację (3 repliki) — odporne na utratę pojedynczego node'a
- AIX poza klastrem — dane nie giną z klastrem
- ArgoCD dla części aplikacji — częściowy GitOps

### 2.4. Czego brakuje

- Backupu etcd (parent + childów)
- OADP/Velero
- Replikacji macierzy
- IaaC dla całej infrastruktury
- Procedur DR (runbooks)
- Backupu konfiguracji (LB, sieci, certs)
- Backupu AD/DNS (czyja odpowiedzialność?)
- Image registry HA + backup
- Testów DR (drills)
- ACM do zarządzania flotą klastrów

---

## 3. Macierz scenariuszy awarii

Skala dotkliwości:
- 🟢 Niska — automatyczna rekonsyliacja
- 🟡 Średnia — wymaga interwencji, ale RTO < 1h
- 🟠 Wysoka — RTO godziny, ryzyko utraty danych
- 🔴 Krytyczna — RTO dni, duża utrata danych
- 💀 Katastroficzna — odtworzenie tygodnie / nie do odtworzenia

### 3.1. Awarie pojedynczych komponentów (🟢)

| Scenariusz | Obecny stan | Co się dzieje |
|---|---|---|
| Pojedynczy bare metal worker | OK | OCP scheduler przenosi pody, Kubernetes HA |
| Pojedynczy VM worker (child) | OK | KubeVirt restart na innym node, OCP scheduler |
| Pojedynczy ESX | OK | vSphere HA migruje VM-ki |
| Awaria dysku w macierzy | OK | RAID pokrywa |
| Pad jednego F5 nodu | OK (zakładam HA F5) | drugi przejmie |

### 3.2. Awarie komponentów krytycznych (🟠–🔴)

#### Scenariusz A: Korupcja etcd parent klastra 💀

**Obecny stan:** brak backupu etcd → klaster nie do odtworzenia bez ręcznej rekonstrukcji wszystkiego.

**Impact:**
- Wszystkie VM child klastrów są na PV-kach przez PX-CSI — dane PV przeżywają.
- Ale definicje VM, MachineConfig, Operatorzy, secrety — wszystko w etcd.
- Bez etcd: trzeba zbudować parent od zera, ręcznie odtworzyć każdą VM, każdy operator, każdy secret.
- RTO: dni do tygodni.
- RPO: cały stan obecny stracony.

**Co potrzebne:** backup etcd (każde 2-6h) + procedura restore.

#### Scenariusz B: Awaria macierzy Pure DC1 💀

**Obecny stan:** druga macierz nie skonfigurowana, brak replikacji → wszystkie VM, PV, dane stracone.

**Impact:**
- Wszystkie VM child klastrów martwe (dyski w Pure).
- Wszystkie PV dla LVMS martwe (dyski w Pure).
- Image registry (jeśli na PV) — martwy.
- Parent klaster może żyć (kontrolery na VMware) ale bez storage workerów.
- RTO: dni.
- RPO: wszystko od ostatniego snapshotu macierzy (jeśli są).

**Co potrzebne:** druga macierz aktywna + replikacja synchroniczna lub ActiveCluster.

#### Scenariusz C: Awaria parent klastra (np. zła konfiguracja, błąd ludzki) 🔴

**Obecny stan:** brak backupu etcd, brak IaaC → odtworzenie ręczne.

**Impact:**
- Child klastry działają nadal (są niezależne, mają własne control plane na VM).
- Ale: nie da się tworzyć nowych VM, restartować padłych, skalować.
- VM child workerów żyją do pierwszego restartu node'a.
- RTO: dni.
- RPO: dzień+.

**Co potrzebne:** backup etcd parent + IaaC żeby odtworzyć platformę.

#### Scenariusz D: Awaria pojedynczego child klastra 🟠

**Obecny stan:** brak OADP → trzeba odtworzyć VM-ki ręcznie i podłączyć aplikacje od nowa.

**Impact:**
- Pozostałe 5 klastrów działa.
- Ten konkretny klaster trzeba zbudować od zera.
- Aplikacje deployowane przez ArgoCD odbudują się automatycznie po odtworzeniu klastra.
- Aplikacje nie-ArgoCD — ręczna robota.
- PV w LVMS — utracone (jeśli klastra fizycznie nie ma).
- RTO: 4-12h.
- RPO: zależy od ArgoCD vs ręczne aplikacje.

**Co potrzebne:** IaaC do szybkiego odtworzenia + OADP dla PV.

### 3.3. Awarie lokalizacji

#### Scenariusz E: Utrata DC1 (główny) 💀

**Obecny stan:** macierz w DC1 → utrata całego storage. VMware stretched, ale brak storage = brak VM.

**Impact:**
- Storage: utracony (Pure DC1, brak repliki).
- VM control/infra: część w DC2 może żyć, ale bez storage do iSCSI/FC.
- Bare metal workery DC1: martwe, DC2: bez storage.
- RTO: tygodnie.
- RPO: wszystko utracone od ostatniego snapshotu.

**Co potrzebne:**
- Pure ActiveCluster (replikacja synchroniczna).
- Druga macierz aktywna i osiągalna z DC2.
- F5/HAProxy w DC2.
- Sieć: VLAN-y rozciągnięte lub routowane na DC2.

#### Scenariusz F: Utrata DC2 🟡

**Obecny stan:** DC1 ma macierz, większość rzeczy. DC2 to pasywny site.

**Impact:**
- VMware: traci połowę ESX, vSphere HA spróbuje uruchomić na DC1 (wymaga zapasu CPU/RAM).
- Bare metal workery DC2: martwe, OCP scheduler przenosi obciążenie do DC1.
- Storage żyje (DC1).
- Ryzyko: brak rezerwy mocy w DC1 → niektóre pody nie wstaną.

**Co potrzebne:**
- Sprawdzenie rezerwy mocy w DC1.
- Pod-disruption-budgety, pod-affinity rules.

#### Scenariusz G: Split-brain między DC 🟠

**Obecny stan:** etcd ma 3 nody. Jeśli nieparzysty rozkład (np. 2 w DC1, 1 w DC2), DC2 traci kworum.

**Impact:**
- Klaster może działać ale niedeterministycznie.
- Wymaga interwencji.

**Co potrzebne:**
- Plan rozłożenia control plane (witness?).
- Procedura split-brain recovery.

### 3.4. Awarie totalne

#### Scenariusz H: Ransomware / encryption attack 💀

**Obecny stan:** brak immutable backup, brak air-gap → backupy (jeśli pojawią się) mogą być zaszyfrowane razem z danymi.

**Co potrzebne:** Backup do storage z immutability/object lock (np. S3 z Object Lock, Pure SafeMode).

#### Scenariusz I: Błąd ludzki (np. delete cluster, drop manifest) 🔴

**Obecny stan:** brak undo, brak GitOps na wszystkim, brak audit trail jako safety net.

**Co potrzebne:** GitOps wszędzie + OADP + RBAC restrictive.

#### Scenariusz J: Utrata obu DC 💀

**Obecny stan:** koniec.

**Co potrzebne:** Backup do trzeciej lokalizacji (cloud? offsite?). Decyzja biznesowa — czy to w ogóle scenariusz do pokrycia.

---

## 4. Gap analysis

### 4.1. Krytyczne (do zrobienia natychmiast)

| Luka | Skutek | Szacunkowy effort |
|---|---|---|
| Brak backupu etcd | Klastry nieodtwarzalne | 2-3 dni |
| Brak OADP / Velero | Aplikacje i PV nieodtwarzalne | 1-2 tyg |
| Brak IaaC dla konfiguracji | Każde odtworzenie ręcznie | 1-2 mies |
| Druga macierz nieskonfigurowana | SPOF storage | 1-2 tyg konfiguracji |

### 4.2. Wysokie (do zrobienia w 1-3 mies)

| Luka | Skutek | Szacunkowy effort |
|---|---|---|
| Brak replikacji Pure | Awaria DC1 = koniec | 1-2 tyg |
| Konfiguracja LB nie w kodzie | Trudne odtworzenie | 1-2 tyg |
| Certyfikaty w plikach | Ryzyko utraty | 1 tydz (cert-manager) |
| Brak procedur DR | Improwizacja podczas awarii | 2-3 tyg pisania |
| Brak ACM | Ręczne zarządzanie flotą | 2-3 tyg |
| Brak monitoringu / alertingu DR | Niewykryte awarie | 2 tyg |

### 4.3. Średnie (3-6 mies)

| Luka | Skutek |
|---|---|
| Brak immutable backupów | Ransomware niepokryty |
| Brak DR drills | Procedury niesprawdzone |
| Brak chaos engineering | Słabe punkty nieznane |
| Brak GitOps wszędzie | Dryf konfiguracji |

### 4.4. Niskie (długi horyzont)

- Trzecia lokalizacja DR (cloud)
- Multi-region active-active
- Self-service cluster provisioning

---

## 5. Roadmapa zadań

### EPIK 1: Backup i restore (P0)

**Cel:** Każdy klaster ma odtwarzalny backup w ciągu 14 dni.

#### Zadanie 1.1: Backup etcd parent klastra
- [ ] Wybrać miejsce składowania (S3? NFS? PV na innej macierzy?)
- [ ] Skonfigurować CronJob `etcd-backup` na nodach control plane
- [ ] Retencja: minimum 7 dni codziennych + 4 tygodniowe
- [ ] Test restore na środowisku testowym
- [ ] Dokumentacja procedury restore
- **Czas:** 2-3 dni
- **Akceptacja:** udane przywrócenie etcd z backupu na test labie

#### Zadanie 1.2: Backup etcd dla każdego child klastra
- [ ] Sztampowy CronJob jako MachineConfig / DaemonSet
- [ ] Wspólne miejsce składowania (np. dedykowany bucket per klaster)
- [ ] Monitoring backupu (alert gdy nie działa 24h)
- **Czas:** 2-3 dni (po zrobieniu 1.1 to copy-paste)
- **Akceptacja:** wszystkie 6 child klastrów ma backup etcd

#### Zadanie 1.3: Wdrożenie OADP/Velero
- [ ] Wybrać backend storage (S3 — MinIO na Pure FlashArray? Zewnętrzny S3?)
- [ ] Zainstalować OADP Operator na każdym child klastrze
- [ ] Skonfigurować BackupStorageLocation i VolumeSnapshotLocation
- [ ] Polityki backupu: codziennie pełny, retencja 30 dni
- [ ] Backup testowej aplikacji + restore na osobny klaster
- **Czas:** 1-2 tyg
- **Akceptacja:** udany restore aplikacji ze stanu z poprzedniego dnia

#### Zadanie 1.4: Backup konfiguracji infrastruktury
- [ ] Konfiguracja F5 — eksport do Git
- [ ] Konfiguracja HAProxy — eksport do Git
- [ ] Konfiguracja sieci (VLAN, bridge) — dokumentacja w Git
- [ ] Certyfikaty — backup do safe vault (Vault? sealed-secrets?)
- [ ] Konfiguracja Pure — eksport (purearray list, purehost list, etc.)
- **Czas:** 2 tyg
- **Akceptacja:** wszystkie konfigi w Git, certyfikaty w vault

#### Zadanie 1.5: Image registry HA + backup
- [ ] Sprawdzić obecny stan registry (gdzie jest, jak działa)
- [ ] Zapewnić HA jeśli single instance
- [ ] Backup zawartości
- **Czas:** 1 tydz
- **Akceptacja:** registry przeżyje awarię node'a, ma backup

---

### EPIK 2: Druga macierz i replikacja storage (P0)

**Cel:** Awaria pojedynczej macierzy nie powoduje utraty danych.

#### Zadanie 2.1: Konfiguracja drugiej macierzy
- [ ] Audit fizyczny: zoning FC, sieć iSCSI, dostępność z DC1 i DC2
- [ ] Konfiguracja podstawowa Purity
- [ ] Test podstawowy: utworzenie LUN, zamapowanie
- **Czas:** 3-5 dni
- **Akceptacja:** macierz odpowiada na API, można utworzyć LUN

#### Zadanie 2.2: ActiveCluster (replikacja synchroniczna)
- [ ] Konfiguracja stretched pod między DC1 i DC2
- [ ] Test latencji (kluczowe dla synchronicznej)
- [ ] Migracja PV testowych do stretched poda
- [ ] Test failover (wyłączenie DC1, sprawdzenie ciągłości)
- **Czas:** 1-2 tyg
- **Akceptacja:** awaria jednej macierzy nie powoduje utraty IO
- **Uwaga:** wymaga sprawdzenia latencji RTT < ~5ms między DC

#### Zadanie 2.3: Aktualizacja PX-CSI dla obu macierzy
- [ ] Update `pure.json` z dwoma FlashArrayami
- [ ] Aktualizacja `px-pure-secret`
- [ ] Test provisioningu na stretched LUN
- **Czas:** 2-3 dni
- **Akceptacja:** PX-CSI używa obu macierzy

#### Zadanie 2.4: Migracja istniejących PV
- [ ] Plan migracji (które PV najpierw, przerwa techniczna potrzebna?)
- [ ] Migracja warstwami: niekrytyczne → krytyczne
- [ ] Rollback plan
- **Czas:** 2-4 tyg (zależy od ilości danych)

---

### EPIK 3: IaaC (P1)

**Cel:** Każdy element konfiguracji jest w Git i może być odtworzony deklaratywnie.

#### Zadanie 3.1: Migracja Ansible do Git
- [ ] Założenie repo (GitLab — już masz)
- [ ] Refactoring: zmienne z plików → Ansible Vault / inventory
- [ ] CI/CD pipeline: lint, syntax check, dry-run
- [ ] Polityka commit/review
- **Czas:** 2-3 tyg
- **Akceptacja:** każda zmiana VM przechodzi przez PR

#### Zadanie 3.2: GitOps dla konfiguracji klastrów
- [ ] ArgoCD na parent klastrze (jeśli nie ma)
- [ ] Repo z konfiguracją: MachineConfig, Operatorzy, RBAC, ConfigMapy
- [ ] App-of-apps pattern dla każdego klastra
- [ ] Sealed-secrets lub External Secrets Operator
- **Czas:** 3-4 tyg
- **Akceptacja:** wyłączenie ręcznie utworzonej ConfigMapy → ArgoCD ją odtwarza

#### Zadanie 3.3: cert-manager
- [ ] Instalacja cert-manager
- [ ] Integracja z wewnętrznym CA lub publiczne (Let's Encrypt jeśli reachable)
- [ ] Migracja certyfikatów z plików
- **Czas:** 1 tydz

#### Zadanie 3.4: ACM (Advanced Cluster Management)
- [ ] Instalacja ACM na parent klastrze
- [ ] Import wszystkich 6 child klastrów
- [ ] Policies: minimum compliance, security baseline
- [ ] PolicyGenerator dla MachineConfigów
- **Czas:** 2-3 tyg
- **Akceptacja:** zmiana w policy ACM → propagacja na wszystkie klastry

---

### EPIK 4: Procedury DR (P1)

**Cel:** Każda awaria z macierzy scenariuszy ma napisany runbook.

#### Zadanie 4.1: Runbook — Restore etcd parent
#### Zadanie 4.2: Runbook — Restore etcd child cluster
#### Zadanie 4.3: Runbook — Failover macierzy
#### Zadanie 4.4: Runbook — Odtworzenie child klastra od zera
#### Zadanie 4.5: Runbook — Awaria DC1
#### Zadanie 4.6: Runbook — Restore aplikacji z OADP

Każdy runbook zawiera:
- Wymagania wstępne
- Kroki krok po kroku
- Komendy z przykładami
- Punkty kontrolne (jak sprawdzić że działa)
- Eskalacja

**Czas:** 1 runbook = 1-2 dni napisania + 1 dzień testu = ~3 tyg dla całego epiku.

---

### EPIK 5: Testowanie DR (P2)

**Cel:** Procedury są przetestowane, RTO/RPO są zmierzone.

#### Zadanie 5.1: DR test labu
- [ ] Mini środowisko do testów (jedna VM parent + jeden child)
- [ ] Wykonanie każdego runbooka w tym labie

#### Zadanie 5.2: DR drill — child klaster
- [ ] Świadome zniszczenie testowego child klastra
- [ ] Pomiar RTO odtworzenia
- [ ] Identyfikacja luk w runbookach
- **Częstotliwość:** kwartalnie

#### Zadanie 5.3: DR drill — failover macierzy
- [ ] Wymaga uzgodnienia okna serwisowego
- [ ] Pomiar wpływu na produkcję
- **Częstotliwość:** półrocznie

---

### EPIK 6: Monitoring DR-readiness (P2)

#### Zadanie 6.1: Alerty
- [ ] Alert: backup etcd nie wykonany w ciągu 24h
- [ ] Alert: OADP backup failed
- [ ] Alert: Pure replication lag
- [ ] Alert: ArgoCD out-of-sync > 1h

#### Zadanie 6.2: Dashboard DR-readiness
- [ ] Status backupów per klaster
- [ ] Wiek najstarszego backupu
- [ ] Status replikacji macierzy
- [ ] Last successful DR test

---

### EPIK 7: Hardening (P3)

#### Zadanie 7.1: Immutable backups
- [ ] Pure SafeMode dla snapshotów
- [ ] S3 z Object Lock dla OADP

#### Zadanie 7.2: Backup poza obie DC
- [ ] Cloud backup (AWS S3 Glacier, Azure Archive)
- [ ] Tylko najwartościowsze dane (etcd, kluczowe PV)

#### Zadanie 7.3: Chaos engineering
- [ ] LitmusChaos lub Chaos Mesh na test cluster
- [ ] Pierwsze eksperymenty: pod-kill, network-loss

---

## 6. Priorytetyzacja — kolejność wykonania

### Sprint 1 (tydzień 1-2): Stop the bleeding

1. Backup etcd parent klastra (najprostszy — bash + cron na master)
2. Eksport krytycznych konfiguracji do Git as-is (bez refactoringu)
3. Eksport certyfikatów do bezpiecznego miejsca

### Sprint 2 (tydzień 3-4): Backup completeness

4. Backup etcd wszystkich child klastrów
5. OADP — instalacja i podstawowy backup (jeden klaster jako pilot)
6. Pierwsza wersja runbooka restore etcd

### Sprint 3 (tydzień 5-8): Storage redundancy

7. Konfiguracja drugiej macierzy
8. ActiveCluster między macierzami
9. PX-CSI w trybie dwóch macierzy

### Sprint 4 (tydzień 9-12): IaaC foundations

10. Ansible w Git z CI/CD
11. ArgoCD na parent klastrze
12. ACM — instalacja i import klastrów

### Sprint 5+ (kwartał 2): Procedury i testy

13. Wszystkie runbooks
14. Pierwszy DR drill
15. cert-manager
16. Monitoring DR-readiness

---

## 7. Zależności i pytania otwarte

### 7.1. Decyzje architektoniczne wymagane

- **Gdzie składować backupy?** S3 zewnętrzny? MinIO na Pure? NFS?
- **Active-Active vs Active-Passive macierzy?** Synchroniczna czy asynchroniczna replikacja?
- **Witness host dla stretched VMware** — gdzie postawić?
- **Czy AD/DNS są w zakresie projektu DR**, czy to inny zespół?
- **Backup w chmurze** — czy w ogóle, czy poza zakresem?

### 7.2. Zależności od innych zespołów

- AIX/DBA: jak wygląda DR baz? Jeśli baza pada przy DC1 → klaster działa, ale aplikacje nie.
- Zespół AD/DNS: HA tych usług to fundament dla autentykacji do OCP.
- Zespół sieci: VLAN stretched / routed, BGP, F5 cluster-to-cluster.
- Zespół storage: zoning FC, konfiguracja replikacji Pure.

### 7.3. Założenia do potwierdzenia

- Czy stretched VMware ma witness host?
- Czy F5 jest w obu DC w trybie active-passive?
- Czy HAProxy jest w HA?
- Jaka jest realna latencja DC1↔DC2 (potrzebne dla decyzji o sync replication)?
- Czy w DC2 jest wystarczająca rezerwa mocy żeby przyjąć całe obciążenie?

---

## 8. KPI / mierniki sukcesu

Po zakończeniu sprintów 1-4 powinniśmy osiągnąć:

| Metryka | Stan obecny | Cel po 3 mies | Cel po 6 mies |
|---|---|---|---|
| RTO parent klaster | tygodnie | < 4h | < 1h |
| RTO child klaster | dni | < 2h | < 30min |
| RPO etcd | wszystko | 24h | 6h |
| RPO PV (aplikacje) | wszystko | 24h | 4h |
| Awaria macierzy = utrata danych | tak | nie | nie |
| Awaria DC1 = utrata produkcji | tak | tak (10min przerwy) | nie (auto failover) |
| Konfiguracja klastra w Git | 0% | 80% | 100% |
| Runbooks DR | 0 | 5 | 10 |
| DR drill wykonany | nigdy | 1× | 2× |

---

## 9. Następne kroki

1. **Walidacja niniejszego dokumentu** — przegląd z zespołem, weryfikacja założeń, korekta priorytetów.
2. **Decyzje architektoniczne** z sekcji 7.1 — wymagają wkładu architekta i biznesu.
3. **Założenie projektu** w narzędziu zarządzania (Jira?) z epikami z sekcji 5.
4. **Sprint 1 kickoff** — backup etcd jako pierwszy konkretny task.

---

*Dokument do iteracji. Każdy epik wymaga jeszcze dopracowania na poziomie tasków przed sprintem.*
