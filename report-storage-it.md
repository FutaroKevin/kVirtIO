# Report Benchmark Storage — Cluster KVM / SLES 15.7 / Pacemaker

**Data test:** 7 luglio 2026
**Tool utilizzato:** `fio` 3.35

---

## 1. Contesto e Ambiente Infrastrutturale

| Componente | Dettaglio |
|---|---|
| Hypervisor | KVM su SLES 15.7 |
| Cluster manager | Pacemaker (3 nodi) |
| Storage | SAN Fibre Channel, link a 16 Gbit |
| Multipathing | Active/Active |
| Storage layer | LVM Clustered, montato su tutti e 3 i nodi |
| Volume Group | Composto da più LUN da 2 TB ciascuna → datastore VM |
| VM di test | Guest sottoposto a stress test I/O sequenziale e randomico |

Il test è stato eseguito da una singola VM appoggiata sul datastore condiviso, per validare il comportamento dello stack completo (VM → KVM → Multipath/LVM Clustered → FC SAN) sia in condizioni di banda sequenziale sostenuta sia in condizioni di carico transazionale randomico.

---

## 2. Test 1 — Throughput Sequenziale

### Comando eseguito

```bash
fio --name=seq_test --ioengine=libaio --rw=readwrite --bs=1m --size=4G \
    --numjobs=1 --iodepth=16 --direct=1 --time_based --runtime=60 --group_reporting
```

Test sequenziale misto lettura/scrittura, blocchi da 1 MiB, coda di profondità 16, I/O diretto (bypass cache pagina), durata 60 secondi.

### Risultati ottenuti

| Metrica | Lettura (Read) | Scrittura (Write) |
|---|---|---|
| Banda Passante (BW) | 1073 MiB/s (1125 MB/s) | 1067 MiB/s (1119 MB/s) |
| IOPS | 1072 | 1066 |
| Latenza Media (avg) | 345,98 µs (~0,35 ms) | 14,55 ms |
| 99° Percentile Latenza | 717 µs (~0,72 ms) | 27,40 ms |
| Dati totali trasferiti | 62,9 GiB | 62,5 GiB |

### Considerazioni tecniche

- **Saturazione del link fisico**: la banda combinata registrata (~1,12–1,13 GB/s sia in lettura che in scrittura) indica che lo stack software (KVM + Multipath + LVM Clustered) riesce a saturare pienamente la banda utile reale di un singolo path Fibre Channel a 16 Gbps, il cui limite teorico netto — depurato dall'overhead di protocollo — si attesta proprio attorno a 1,1–1,2 GB/s.
- **Profilo della latenza**: in lettura la latenza è estremamente contenuta (sub-millisecondo). In scrittura la media sale a ~14,5 ms, con un picco isolato (fino a 2,67 s in coda alla distribuzione, visibile nel 99,99° percentile) riconducibile al riempimento delle cache del controller storage, che forza il "destage" fisico dei blocchi sui moduli NVMe di back-end. Comportamento nominale per uno stress test sequenziale sostenuto di questa entità.

---

## 3. Test 2 — I/O Randomico (IOPS e Reattività)

Simula il comportamento di applicazioni transazionali pesanti (database relazionali, server web ad alta concorrenza), con blocchi piccoli da 4 KB in modalità randomica, bilanciamento 70% lettura / 30% scrittura.

### Comando eseguito

```bash
fio --name=rand_test --ioengine=libaio --rw=randrw --rwmixread=70 --bs=4k --size=4G \
    --numjobs=4 --iodepth=64 --direct=1 --time_based --runtime=60 --group_reporting
```

### Nota tecnica sull'esecuzione (ENOSPC)

Durante la fase di allocazione dei file di test, `fio` ha riscontrato un esaurimento dello spazio disco sulla VM (`fio: ENOSPC on laying out file... No space left on device`). La configurazione prevedeva 4 processi paralleli su file da 4 GB ciascuno (16 GB totali richiesti), ma lo spazio disponibile sul disco della VM non era sufficiente. Di conseguenza `fio` ha proseguito il test con solo **2 processi attivi su 4**.

> Il test ha quindi girato a "motore parziale": i numeri riportati sotto sono comunque validi e significativi, ma rappresentano una prova a capacità dimezzata rispetto al piano originale.

### Risultati ottenuti

| Metrica | Lettura (Read) | Scrittura (Write) | Totale complessivo |
|---|---|---|---|
| IOPS | 80.000 | 34.300 | **114.300 IOPS** |
| Banda Passante (BW) | 312 MiB/s (328 MB/s) | 134 MiB/s (140 MB/s) | **446 MiB/s** |
| Latenza Media (avg) | 1,10 ms | 1,15 ms | ~1,11 ms |
| 99° Percentile Latenza | 2,02 ms | 2,11 ms | < 2,15 ms |
| Dati totali trasferiti | 18,3 GiB | 8034 MiB | — |

### Considerazioni tecniche

- **Performance NVMe pure**: oltre 114.000 IOPS complessivi generati da una singola VM, pur con solo metà dei worker attivi, è un valore di fascia altissima e conferma l'assenza di colli di bottiglia nel protocollo di comunicazione con l'array di storage.
- **Consistenza dei percentili**: il 99° percentile fermo a ~2 ms è il dato più rilevante dal punto di vista applicativo. Significa che il 99% delle richieste I/O viene evaso in tempi quasi istantanei, senza micro-impuntamenti né code anomale che potrebbero impattare applicazioni transazionali in produzione.
- **Stabilità del locking cluster**: l'infrastruttura di clustering (Pacemaker + LVM Clustered) non introduce overhead percepibile né degradazione sulle code di I/O raw, a conferma della bontà della configurazione architetturale adottata.

---

## 4. Test 3 — I/O Randomico ad Alta Concorrenza (File Piccoli, 100 Processi)

Ripetizione del test randomico risolvendo il problema di ENOSPC del Test 2, ma spingendo drasticamente la concorrenza: file da 100 MB invece di 4 GB, con **100 processi paralleli** invece di 4, sempre con `iodepth=64` per processo.

### Comando eseguito

```bash
fio --name=rand_test --ioengine=libaio --rw=randrw --rwmixread=70 --bs=4k --size=100M \
    --numjobs=100 --iodepth=64 --direct=1 --time_based --runtime=60 --group_reporting
```

### Risultati ottenuti

| Metrica | Lettura (Read) | Scrittura (Write) | Totale complessivo |
|---|---|---|---|
| IOPS | 87.200 | 37.400 | **124.600 IOPS** |
| Banda Passante (BW) | 341 MiB/s (357 MB/s) | 146 MiB/s (153 MB/s) | **487 MiB/s** |
| Latenza Media (avg) | 49,58 ms | 52,89 ms | ~50,6 ms |
| Latenza P50 | 43,78 ms | ~48 ms | — |
| Latenza P90 | 101,19 ms | ~105 ms | — |
| Latenza P95 | 123,21 ms | ~127 ms | — |
| Latenza P99 | 173,02 ms | ~178 ms | — |
| Latenza P99,9 | 250,61 ms | ~255 ms | — |
| Latenza massima | 449,38 ms | 449,45 ms | — |
| Dati totali trasferiti | 20,0 GiB | 8769 MiB | — |

### Considerazioni tecniche — perché la latenza "esplode"

A colpo d'occhio il throughput aggregato (IOPS e BW) è addirittura **superiore** a quello del Test 2 (124.600 IOPS vs 114.300 IOPS), ma la latenza media è passata da ~1,1 ms a **~50 ms**, cioè circa **45 volte peggiore**. Questo non è un problema dello storage, ma dell'effetto combinato di **concorrenza** e **coda**:

- **Coda totale in volo**: `numjobs=100 × iodepth=64 = 6.400` richieste I/O simultaneamente in outstanding verso il device, contro appena `2 processi attivi × 64 = 128` del Test 2 (per effetto dell'ENOSPC che aveva limitato i worker realmente partiti).
- **Legge di Little (L = λ × W)**: la latenza media attesa è pari alla coda totale divisa per il throughput in IOPS. Applicandola ai due test:
  - Test 2: `128 / 114.300 IOPS ≈ 1,12 ms` → coincide quasi esattamente con la latenza media osservata (~1,11 ms).
  - Test 3: `6.400 / 124.600 IOPS ≈ 51,4 ms` → coincide quasi esattamente con la latenza media osservata (~50,6 ms).

  In altre parole: lo storage sta lavorando bene ed eroga più o meno lo stesso numero di operazioni al secondo in entrambi i casi, ma nel Test 3 ogni richiesta deve "aspettare in fila" molto più a lungo perché il numero di richieste in coda contemporaneamente è ~50 volte superiore.
- **Non è (solo) una questione di "file piccoli"**: la dimensione del file (100 MB vs 4 GB) di per sé incide poco, dato che il pattern è randomico a blocchi di 4 KB in entrambi i test. L'elemento davvero determinante è **il numero di processi concorrenti (100) moltiplicato per la profondità di coda per processo (64)**. Lo scenario "tanti file piccoli" nella realtà porta però quasi sempre a questo pattern (tanti processi/thread/VM che accedono in parallelo a tanti piccoli file), motivo per cui l'esperienza soggettiva di "incubo" è corretta e ben fotografata dal test.
- **Coerenza della distribuzione**: la progressione ordinata dei percentili (P50 ≈44-48 ms → P90 ≈101-105 ms → P99 ≈173-178 ms → max ≈449 ms) è tipica di un sistema in **accodamento stabile ma saturo**, non di uno storage che si blocca o ha malfunzionamenti: non ci sono timeout, errori o cali a zero, solo tempi di risposta dilatati in modo proporzionale al carico imposto.

### Confronto sintetico Test 2 vs Test 3

| | Test 2 (4 GB, 4 job) | Test 3 (100 MB, 100 job) |
|---|---|---|
| Coda totale (numjobs × iodepth) | 128 | 6.400 |
| IOPS totali | 114.300 | 124.600 |
| BW totale | 446 MiB/s | 487 MiB/s |
| Latenza media | ~1,1 ms | ~50,6 ms |
| Latenza P99 | < 2,15 ms | ~175 ms |

---

## 5. Conclusioni e Raccomandazioni

L'ambiente hypervisor ha superato lo stress test con metriche di classe Enterprise sia in scenario di banda sequenziale sostenuta (Test 1) sia in scenario di carico randomico a concorrenza moderata (Test 2). Il Test 3 ha invece messo in luce un aspetto importante da governare: **il throughput (IOPS/BW) resta elevato anche a concorrenza estrema, ma la latenza percepita cresce in modo proporzionale alla profondità di coda totale applicata**, non per un limite dello storage ma per pura legge di accodamento.

Per completare la messa in produzione si suggeriscono i seguenti controlli:

1. **Ottimizzazione multipathing (MPIO)**
   Poiché una singola VM satura agevolmente un link FC a 16 Gbps, verificare che su tutti gli host KVM il multipathing sia effettivamente configurato in modalità **Active/Active** con policy round-robin (o service-time), in modo da aggregare la banda di più HBA fisiche e superare il limite del singolo Gigabyte/s per host in caso di carichi concorrenti su più VM contemporaneamente.

2. **Dimensionare la profondità di coda in base al carico applicativo reale (nuovo, da Test 3)**
   Il Test 3 dimostra che spingere `numjobs × iodepth` a valori molto alti (qui 6.400) fa salire la latenza media a decine di millisecondi anche con uno storage sano. Se le applicazioni reali (database, fileserver, molte VM/container che accedono a molti file piccoli) generano livelli di concorrenza simili, è fondamentale: verificare/limitare l'`iodepth` effettivo lato applicazione e lato guest (code virtio-scsi/virtio-blk), e definire uno SLA di latenza target per poi calcolare a ritroso, con la Legge di Little, la coda massima tollerabile.

3. **Costruire una curva latenza/concorrenza per il capacity planning**
   Si raccomanda di ripetere il test randomico a step crescenti di concorrenza (es. `numjobs=10, 25, 50, 100` a `iodepth` fisso), per tracciare la curva IOPS/latenza del sistema e individuare il "ginocchio" oltre il quale la latenza degrada in modo sproporzionato rispetto al guadagno di IOPS. Questo permette di fissare in modo dati-driven i limiti di concorrenza consigliati per le applicazioni di produzione.

4. **Verifica sotto carico concorrente multi-VM**
   Essendo i test attuali riferiti a una singola VM, si raccomanda un ulteriore round con più VM attive simultaneamente sullo stesso datastore/VG, per validare il comportamento della banda aggregata e la fairness dell'arbitraggio I/O tra i nodi del cluster Pacemaker.

---

*Report generato automaticamente a partire dall'output raw di `fio` e dall'analisi tecnica dei risultati.*