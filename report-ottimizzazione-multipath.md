# Report Tuning Storage e Migrazione VM OLTP — Cluster KVM / SLES 15.7

**Data report:** 9 luglio 2026  
**Infrastruttura di Riferimento:** Architettura [KvirtIO](README_IT.md)  
**Ambiente:** SLES 15.7 / Pacemaker / Multipath FC / KVM  

---

## 1. Contesto e Ambiente Hardware del Cluster

Il deployment è stato eseguito su un cluster KVM a 3 nodi con risorse eterogenee, configurato per garantire alta affidabilità (HA) e massimizzazione del throughput I/O per carichi transazionali (OLTP).

| Componente | Dettaglio / Specifiche |
|---|---|
| **Modello Nodi** | Dell PowerEdge R740 (3 nodi fisici) |
| **Memoria RAM** | Eterogenea: 2 nodi da **~740 GB** di RAM, 1 nodo da **1.5 TB** di RAM |
| **Connettività Rete** | 2 interfacce da 10 Gigabit Ethernet configurate in Port Channel (LACP) |
| **Connettività Storage** | 2 HBA Fibre Channel da 16 Gigabit per ciascun nodo |
| **Storage Array** | **Dell PowerStore 1200T** |
| **Storage Config** | Storage distribuito su **2 LUN stretchate** (stretched LUNs) |
| **Hypervisor & Cluster** | KVM su SUSE Linux Enterprise Server 15.7 gestito da Pacemaker |

> **Nota sull'eterogeneità dei nodi**: L'HLD di riferimento ([KvirtIO_HLD](Kvirtio_HLD_IT.md), Sezione 2) raccomanda nodi omogenei per semplificare la live migration. Questo deployment rappresenta una validazione in condizioni reali con hardware eterogeneo, confermando che l'architettura KvirtIO opera correttamente anche in presenza di asimmetrie di capacità RAM tra nodi, a patto che le policy di migrazione Pacemaker (`resource-stickiness` e score negativi) siano configurate per tenere conto dei vincoli di memoria massima per nodo.

---

## 2. Baseline dei Test Precedenti

I benchmark iniziali eseguiti su una VM di test prima delle ottimizzazioni sono dettagliati nel documento [report-storage-it.md](report-storage-it.md). 

Quei test avevano evidenziato:
- **Saturazione del singolo link**: Il throughput sequenziale era limitato a ~1073 MiB/s in lettura e ~1067 MiB/s in scrittura, saturando la banda netta di un solo path FC da 16 Gbps.
- **Accodamento e Latenza**: A bassi livelli di concorrenza le latenze erano ottimali (~1.1 ms), ma con concorrenza estrema (100 processi paralleli, coda totale 6400 I/O in volo), la latenza media saliva a **~50.6 ms** per via dei colli di bottiglia legati all'accodamento e ai driver HBA non ottimizzati.

---

## 3. Interventi di Tuning e Ottimizzazione Storage

Per risolvere la saturazione dei singoli link e consentire una reale parallelizzazione dell'I/O sulle HBA e sui diversi percorsi fisici, sono state apportate due importanti modifiche configurative a livello di host.

### A. Ottimizzazione del Multipathing (`/etc/multipath/conf.d/hba.conf`)

È stata configurata una policy di aggregazione e selezione dei path mirata alla riduzione dei tempi di servizio e alla parallelizzazione dei carichi. Il file è stato modificato come segue:

```text
defaults {
    user_friendly_names yes
    path_grouping_policy multibus
    path_selector "service-time 0"
    rr_min_io_rq 1
    polling_interval 5
    no_path_retry fail
}
```

#### Dettagli sulle direttive

- **`path_grouping_policy multibus`**: Raggruppa tutti i path attivi in un unico gruppo "multibus", permettendo di bilanciare il carico su tutti i canali fisici contemporaneamente.

  > **Nota architetturale — Compatibilità con il modello di accesso dell'array**: La policy `multibus` presuppone che lo storage array presenti le LUN in modalità **Active/Active simmetrica** su tutti i controller, ovvero che ogni path fisico sia equivalente in termini di latenza e throughput. Il **Dell PowerStore 1200T** utilizza un'architettura **Active/Active con volume auto-placement** uniforme, dove le LUN vengono servite simmetricamente da tutti i nodi dell'appliance senza necessità di trespassing tra controller. Questo conferma la correttezza della scelta `multibus`. Su storage array che implementano **ALUA (Asymmetric Logical Unit Access)** con path preferiti e non-preferiti (es. active/passive o active/optimized vs active/non-optimized), la policy corretta sarebbe `group_by_prio` per evitare trespassing implicito delle LUN tra controller, che degraderebbe pesantemente le prestazioni. **Chi adotta questa configurazione su array diversi dal PowerStore deve verificare il modello di accesso del proprio storage prima di replicare questa direttiva.**

- **`path_selector "service-time 0"`**: Invia l'I/O al percorso che presenta la minore latenza/tempo di servizio stimato, massimizzando l'efficienza.

- **`rr_min_io_rq 1`**: Forza lo switch del percorso multipath dopo una singola richiesta I/O. Questo distribuisce il carico al massimo livello di granularità (round-robin a livello di singolo pacchetto/richiesta).

- **`no_path_retry fail`**: In caso di perdita totale dei percorsi, fallisce immediatamente le I/O senza attesa.

  > **Motivazione architetturale**: In un ambiente con fencing a due livelli gestito da Pacemaker/SBD (come documentato nell'[HLD Sezione 4](Kvirtio_HLD_IT.md)), la scelta di `fail` è deliberata. Se tutti i path FC vengono persi, il nodo è in uno stato di isolamento dallo storage e deve essere gestito dal cluster (STONITH via `fence_idrac` o self-fence via SBD/watchdog), non dal multipathing. Un valore elevato di `no_path_retry` (es. `queue` o un numero alto di tentativi) manterrebbe le I/O in coda indefinitamente a livello kernel, **bloccando il processo PostgreSQL** in stato di attesa non interrompibile (`D state`) e impedendo a Pacemaker di completare lo `stop` della risorsa `VirtualDomain` entro il timeout configurato, il che porterebbe a un doppio failover disordinato. Con `fail`, PostgreSQL riceve immediatamente un errore I/O, Pacemaker rileva il fallimento della risorsa, e il cluster procede al fencing ordinato e al riavvio della VM su un nodo sano in tempi deterministici.

### B. Incremento Profondità di Coda Driver HBA QLogic

Per evitare colli di bottiglia hardware a livello di driver Fibre Channel durante carichi di lavoro ad alta concorrenza, la profondità di coda (Queue Depth) del driver `qla2xxx` è stata impostata a **256** tramite parametro del modulo kernel in `/etc/modprobe.d/qla2xxx.conf`:

```text
options qla2xxx ql2xmaxqdepth=256
```

Questo consente al kernel e all'HBA fisica di accodare un numero molto maggiore di richieste simultanee verso i controller dello storage array prima di generare congestione a livello software.

> **Correlazione con `lun_queue_depth` dell'HLD**: Come documentato nell'[HLD Sezione 3.1](Kvirtio_HLD_IT.md), il parametro `lun_queue_depth` a livello di singolo device (`/sys/block/sdX/device/queue_depth`) è il limite effettivo delle richieste in volo per singola LUN/path al livello SCSI mid-layer. Il parametro `ql2xmaxqdepth` imposta il **tetto massimo** che il driver HBA è disposto ad accettare, ma la profondità di coda operativa per ciascuna LUN è determinata dal valore di `queue_depth` negoziato o impostato a livello di device. In questo deployment, il valore di `queue_depth` per LUN è stato verificato coerente con la configurazione del driver per evitare che il limite per-LUN vanificasse l'incremento a livello HBA. La strategia Multi-LUN Striped raccomandata dall'HLD (Sezione 3.2) moltiplica la coda aggregata per il numero di LUN nel volume group, garantendo che la coda complessiva disponibile ($N_{\text{LUN}} \times \text{queue\_depth}$) sia ampiamente superiore alla domanda generata dalle VM.

---

## 4. Benchmark Fio Post-Tuning (OLTP Simulation)

Dopo l'applicazione dei parametri di tuning, è stato eseguito un test di validazione con `fio` simulando un carico transazionale randomico misto (70% Lettura / 30% Scrittura) con blocchi piccoli (4 KB). 

> **Nota:** La dimensione dei file e il numero di processi (job) sono stati leggermente ridotti rispetto ai test della baseline per evitare problemi di spazio su disco (ENOSPC) all'interno della VM di test.

### Comando Eseguito

```bash
fio --name=rand_test_oltp --ioengine=libaio --rw=randrw --rwmixread=70 --bs=4k --size=1G \
    --numjobs=12 --iodepth=32 --direct=1 --time_based --runtime=60 --group_reporting
```

### Risultati Ottenuti

| Metrica | Lettura (Read) | Scrittura (Write) | Totale Aggregato |
|---|---|---|---|
| **IOPS** | 82.300 | 35.300 | **117.600 IOPS** |
| **Banda Passante (BW)** | 321 MiB/s (337 MB/s) | 138 MiB/s (145 MB/s) | **459 MiB/s** (482 MB/s) |
| **Latenza Media (`clat`)** | 3.20 ms (3204 µs) | 3.35 ms (3346 µs) | **~3.25 ms** |
| **99° Percentile Latenza** | 6.33 ms (6325 µs) | 6.72 ms (6718 µs) | **~6.45 ms** |
| **99.9° Percentile Latenza** | 9.50 ms (9503 µs) | 10.55 ms (10552 µs) | **~9.80 ms** |
| **Latenza Massima** | 24.89 ms (24893 µs) | 26.99 ms (26989 µs) | — |
| **Dati Trasferiti** | 18.8 GiB | 8275 MiB | — |

### Analisi Tecnica delle Prestazioni

#### Verifica con la Legge di Little

Con `numjobs=12` e `iodepth=32` per processo, la coda totale di richieste I/O contemporaneamente in volo (outstanding IO) è pari a $12 \times 32 = 384$. 

Applicando la formula teorica per la latenza:

$$\text{Latenza media attesa} = \frac{\text{Coda Totale}}{\text{IOPS aggregati}} = \frac{384}{117.638 \text{ IOPS}} \approx 3.26\text{ ms}$$

La latenza media effettiva registrata da `fio` si attesta a **~3.25 ms**. Questo allineamento millimetrico indica che lo storage array (PowerStore 1200T) e la SAN stanno processando le richieste in modo ottimale, senza generare code anomale o attese spurie oltre quelle matematicamente attese dalla concorrenza imposta dal test. In altri termini, **il 100% della latenza osservata è spiegabile dalla profondità di coda**, non da inefficienze del path.

#### Coerenza Interna dei Dati Trasferiti

A ulteriore conferma della validità dei dati:
- Lettura: $321 \text{ MiB/s} \times 60\text{s} \approx 18.8\text{ GiB}$ ✓
- Scrittura: $138 \text{ MiB/s} \times 60\text{s} \approx 8.275\text{ MiB}$ ✓

#### Percentili Estremamente Stabili

La latenza al 99° percentile si mantiene sotto i 7 ms sia in lettura che in scrittura, mentre il 99.9° percentile (worst-case transazionale) non supera gli 11 ms. Per un database OLTP, questa predicibilità della latenza garantisce transazioni stabili e previene i picchi di blocco della coda delle query.

---

## 5. Monitoraggio in Produzione della VM OLTP Migrata

A seguito dei risultati incoraggianti ottenuti con i benchmark sintetici, è stata effettuata la migrazione nel cluster KVM (con stack [KvirtIO](README_IT.md)) di una **VM OLTP di produzione**.

### Profilo della VM OLTP

| Parametro | Valore |
|---|---|
| **Ruolo** | Nodo Database PostgreSQL a servizio di un'istanza Zabbix |
| **Carico Applicativo** | Media di **4000 VPS** (values per second) scritti sul DB PostgreSQL |
| **Configurazione Storage** | Alloggiata su **2 LUN stretchate** attive sul PowerStore 1200T |
| **Nodo di Esecuzione** | `tlkvm03` |

### Analisi del Comportamento (Metriche da Dashboard)

Le telemetrie storiche estratte dal monitoraggio dell'host di esecuzione (`tlkvm03`) mostrano chiaramente le prestazioni dello storage su due distinte fasi operative:

![Metriche di Storage del Hypervisor durante e dopo la migrazione](grafico-ottimizzazione-oltp.png)

*Grafico superiore: Disk Time (latenza read/write per LUN) — Grafico inferiore: Utilizzo percentuale per singola LUN.*

#### Fase 1: Esercizio Standard (Avvio e Esecuzione Workload) — *Intervallo ~18:30 - 20:30*

- **Disk Time (Latenza)**: Nel grafico superiore (dove la semiretta positiva rappresenta il tempo di scrittura e quella negativa il tempo di lettura), il tempo di risposta si attesta a livelli eccellenti:
  - **Scrittura (Write time)**: Sotto **0.25 ms** (valore medio prossimo a 0.15 ms).
  - **Lettura (Read time)**: Compreso tra **-0.25 ms** e **-0.5 ms** (con rari picchi transitori a -0.75 ms).
- **Utilizzo LUN**: Nel grafico inferiore, l'utilizzo percentuale di ciascuna delle LUN coinvolte rimane confinato a livelli inferiori al **5%**.
- *Considerazioni*: Le ottimizzazioni multipath + HBA applicate, combinate con la bassa latenza nativa del PowerStore 1200T, mantengono le latenze operative a livello sub-millisecondo pur gestendo le frequenti scritture/letture necessarie a processare i 4000 VPS di Zabbix.

#### Fase 2: Replica Forzata di Allineamento (Catch-up) — *Intervallo ~21:40 - 22:15*

- **Contesto**: Durante lo spegnimento temporaneo per completare la migrazione all'interno del cluster KVM, la base dati ha accumulato un ritardo nei dati. Al riavvio, è stata forzata una replica massiva dei dati per riallineare il nodo PostgreSQL.
- **Disk Time (Latenza)**: Nonostante il pesante incremento di throughput dovuto alla sincronizzazione concorrente, i tempi di risposta hanno registrato un aumento minimo e controllato:
  - **Scrittura (Write time)**: Picco massimo a **0.4 ms**.
  - **Lettura (Read time)**: Picco massimo a **-0.6 ms**.
  - La latenza si è mantenuta solidamente al di sotto di 1 millisecondo anche sotto stress di replica.
- **Utilizzo LUN**: L'utilizzo percentuale delle singole LUN è salito fino a un picco del **20%**.
- *Considerazioni*: Lo stress test reale della replica forzata ha dimostrato la resilienza del sistema. La saturazione delle LUN al 20% evidenzia una **riserva di prestazioni (headroom) dell'80%**, a garanzia che il cluster può assorbire picchi di carico improvvisi senza alcun degrado prestazionale per gli utenti finali o per i watcher di sistema.

---

## 6. Conclusioni Architetturali

L'adozione della configurazione di multipathing `multibus` con selettore `service-time` su array Dell PowerStore 1200T (Active/Active simmetrico), abbinata alla coda driver HBA `ql2xmaxqdepth=256`:

1. **Ha rimosso i colli di bottiglia sui singoli percorsi**: L'I/O viene ora distribuito in modo efficiente su tutti i link fisici FC da 16 Gbit a disposizione, con la conferma matematica (Legge di Little) che la latenza osservata è interamente spiegabile dalla concorrenza imposta, senza overhead aggiuntivi.
2. **Garantisce latenze inferiori al millisecondo in produzione**: La VM PostgreSQL riscontra latenze operative medie inferiori a 0.5 ms sotto carico tipico di 4000 VPS.
3. **Consente recuperi veloci**: I processi di allineamento e replica forzata sfruttano l'ampio throughput disponibile (fino a 117k IOPS misurati) saturando la LUN solo al 20%, mantenendo l'esperienza utente intatta.
4. **Conferma la validità dell'architettura KvirtIO con nodi eterogenei**: Il cluster a 3 nodi con RAM asimmetrica (2×740 GB + 1×1.5 TB) opera correttamente sia in condizioni di carico sintetico sia con workload OLTP reali di produzione, validando le scelte architetturali documentate nell'[HLD](Kvirtio_HLD_IT.md) relative a storage, multipathing, fencing e politiche di migrazione.


