# Cloud-Native Capstone — Sertleştirilmiş Docker → Production Seviyesi Kubernetes

[English](README.md) | **Türkçe**

![ci](https://github.com/furkan-akkaya/capstone-docker/actions/workflows/ci.yaml/badge.svg)

Küçük bir `nginx → Flask API → PostgreSQL + Redis` yığını; **güvenlik açısından sertleştirilmiş (hardened) bir Docker Compose** kurulumundan alınıp **production'a hazır bir Kubernetes** kurulumuna kadar taşındı — zero-trust ağ segmentasyonu, Pod Security Admission, otomatik ölçekleme ve GitOps'a hazır bir Kustomize yapısıyla.

Uygulama bilinçli olarak minik tutuldu; böylece asıl ilgi çekici kısım iş mantığı değil, **onun etrafındaki operasyonel ve güvenlik mühendisliği** oluyor.

---

## Uygulama

Flask + Gunicorn ile sunulan üç HTTP endpoint'i:

| Endpoint    | Ne yapar                                                  |
|-------------|-----------------------------------------------------------|
| `/health`   | Liveness/readiness sinyali — `{"status":"ok"}`            |
| `/`         | Bir **Redis** sayacını artırır — cache bağlantısını kanıtlar |
| `/db-check` | **PostgreSQL** üzerinde `SELECT 1` çalıştırır — DB bağlantısını kanıtlar |

---

## Mimari

Dört servis, üç katman halinde dizilmiş; her katman kendi izole ağında. Temel fikir: **trafik yalnızca bir adım içeri hareket edebilir, asla bir katmanı atlayamaz.** İnternet nginx'e ulaşır; nginx API'ye ulaşır; veri katmanına yalnızca API ulaşır.

```
                    HOST
                     │  yalnızca :8080 yayınlanmış
   ══════════════════│═══════════════════════════════════  public ağı
                     ▼
              ┌──────────────┐
              │    nginx     │  reverse proxy (uid 101)
              └──────┬───────┘
   ══════════════════│═══════════════════════════════════  app_net  (internal)
                     ▼
              ┌──────────────┐
              │     api      │  Flask + Gunicorn (uid 1000)
              └──────┬───────┘
   ══════════════════│═══════════════════════════════════  data_net (internal)
             ┌───────┴────────┐
             ▼                ▼
      ┌────────────┐   ┌────────────┐
      │  postgres  │   │   redis    │   veritabanı + cache (uid 999)
      └────────────┘   └────────────┘
```

### Servisler (container'lar)

| Servis     | Rol                              | Image                | Çalışan kullanıcı | Ağ(lar)             | Port | Host'tan erişilebilir mi? |
|------------|----------------------------------|----------------------|-------------------|---------------------|------|---------------------------|
| `nginx`    | Reverse proxy / giriş noktası    | `nginx:1.27-alpine`  | `101:101`         | `public`, `app_net` | 8080 | ✅ evet — yalnızca `:8080` |
| `api`      | Flask uygulaması                 | `./api`'dan build    | `1000` (`appuser`) | `app_net`, `data_net` | 5000 | ❌ hayır |
| `postgres` | Veritabanı                       | `postgres:16-alpine` | `999:999`         | `data_net`          | 5432 | ❌ hayır |
| `redis`    | Cache / sayaç                    | `redis:7-alpine`     | `999:999`         | `data_net`          | 6379 | ❌ hayır |
| `pg-init`  | Tek seferlik volume izin düzeltici | `busybox`          | root (hemen çıkar) | `data_net`         | —    | ❌ hayır |

### Ağlar (üç katman)

| Ağ         | `internal`? | Üyeler                       | Amaç |
|------------|-------------|------------------------------|------|
| `public`   | hayır       | `nginx`                      | Host'a bağlı **tek** ağ. Tüm dış trafik buradan girer — başka hiçbir yerden değil. |
| `app_net`  | **evet**    | `nginx`, `api`               | Proxy ile uygulama arasındaki özel bağlantı. İnternete çıkışı yok. |
| `data_net` | **evet**    | `api`, `postgres`, `redis`   | Tamamen izole veri katmanı. Host'tan *ve* nginx'ten erişilemez. |

**Tüm tasarımın anahtarı:** `api`, hem `app_net` hem `data_net` üzerinde bulunan *tek* servistir. Uygulama katmanı ile veri katmanı arasındaki tek ve bilinçli köprüdür. `nginx`, `data_net` üzerinde **değildir**, dolayısıyla `postgres`/`redis`'i isimle bile çözemez — veritabanı, saldırganlara en açık katman için görünmezdir.

### Bir isteğin yolculuğu

1. Bir istemci `http://host:8080/`'a vurur → `public` ağındaki **nginx**'e ulaşır.
2. nginx isteği **`app_net`** üzerinden **`api:5000`**'e proxy'ler.
3. api, yanıtı oluşturmak için **`data_net`** üzerinden **`redis:6379`** ve **`postgres:5432`** ile konuşur.
4. Yanıt aynı yoldan geri döner: api → nginx → istemci.

İstemci veritabanını hiç görmez; veritabanı istemciyi hiç görmez. Her sıçrama tam olarak bir ağ sınırını geçer.

---

## Tek kod tabanı, iki dağıtım aşaması

Aynı dört servis ve aynı nginx config'i, iki farklı şekilde dağıtılıyor — sertleştirilmiş tek bir host'tan production'a hazır bir cluster'a.

### Aşama 1 — Sertleştirilmiş Docker Compose

```bash
cp .env.example .env      # sonra POSTGRES_PASSWORD'ü düzenle
make compose-up
curl http://localhost:8080/health
```

Yukarıdaki üç katmanlı ağ modeli, ikisi `internal: true` olan üç Docker bridge network'ü olarak ifade edilir.

### Aşama 2 — Kubernetes

```bash
# Lokal, sıfırdan: kind cluster'ı oluşturur, image'ı build edip yükler,
# ingress-nginx kurar, dev overlay'i dağıtır ve smoke-test eder.
make kind-up

# Ya da mevcut herhangi bir cluster'a uygula:
kubectl apply -k k8s/overlays/dev     # veya overlays/prod
```

Mimari, Kubernetes ilkellerine (primitives) temiz biçimde eşlenir:

| Docker Compose             | Kubernetes                                     |
|----------------------------|------------------------------------------------|
| üç izole ağ                | **NetworkPolicy'ler** (default-deny + izin listesi) |
| adlandırılmış volume (`pgdata`) | **PersistentVolumeClaim** (StatefulSet ile)  |
| `pg-init` chown container'ı | **`fsGroup`** (kubelet volume sahipliğini ayarlar) |
| healthcheck'ler            | **readiness / liveness / startup probe'ları**  |
| `depends_on: healthy`      | readiness kapılama + init sıralaması            |
| — (yalnızca host seviyesi) | **Pod Security Admission**, HPA, PodDisruptionBudget |

---

## Güvenlik duruşu (Security posture)

**Her iki aşamada** da tutarlı biçimde uygulandı:

| Kontrol                       | Docker Compose                     | Kubernetes                                             |
|-------------------------------|------------------------------------|--------------------------------------------------------|
| Non-root çalıştırma           | sabit UID'ler (`999`, `101`, `1000`) | `runAsNonRoot` + her workload için açık `runAsUser`  |
| Linux capability'lerini düşür | `cap_drop: ALL`                    | `capabilities.drop: [ALL]`                            |
| Privilege escalation engeli   | `no-new-privileges:true`           | `allowPrivilegeEscalation: false`                     |
| Salt-okunur root filesystem   | `read_only: true` + `tmpfs`        | `readOnlyRootFilesystem: true` + `emptyDir`           |
| Syscall filtreleme            | Docker varsayılan seccomp          | `seccompProfile: RuntimeDefault`                       |
| Admission'da zorlama          | —                                  | **Pod Security Admission: `restricted`** (namespace'te) |
| En az yetkili API erişimi     | —                                  | workload başına ayrı SA, `automountServiceAccountToken: false` |
| Minimal image                 | multi-stage build (final image'da gcc/libpq-dev yok)                      ||
| Sırlar (secrets)              | `.env` (gitignore'da)              | `Secret` referansları (Sealed Secrets / ESO / SOPS ile değiştirilir) |

### Bu sertleştirme neden önemli — saldırganın gözünden

Bunların hiçbiri süs değil. Her kontrolün somut bir saldırıya karşılığı var. Tüm tasarımın amacı **defense in depth** (katmanlı savunma): "her ihlali önlemek" değil (imkânsız), tek bir ele geçirmenin topyekûn kayba dönüşmesini engellemek.

| Kontrol | Engellediği saldırı |
|---|---|
| **Ağ segmentasyonu** (postgres/redis yalnızca internal katmanda) | Lateral movement. Saldırgan edge'i (nginx) ele geçirse bile **veritabanına sıçrayamaz** — data katmanı oradan yönlendirilebilir bile değil. Gerçek ihlallerin çoğu tam olarak "çevre delindi → DB'ye yüründü" senaryosudur; bu yolu keser. |
| **Non-root çalıştırma** | Ele geçirme sonrası güç. API container'ında kod çalıştırma, yetkisiz bir kullanıcı olarak düşer — root'a ait dosyaları okuyamaz, ayrıcalıklı portları bağlayamaz, işletim sistemini kurcalayamaz. |
| **Tüm capability'leri düşür** | Kernel seviyesi istismar. Süreç root olsa *bile* `CAP_NET_RAW` (paket dinleme/sahteleme), `CAP_SYS_ADMIN` (mount, birçok escape) vb. yoktur — yani standart container-escape araç kutusu çoğunlukla işlemez. |
| **`no-new-privileges`** | Privilege escalation. Klasik "setuid binary'yi istismar edip root ol" adımını boşa çıkarır — kernel bu süreç ağacı için yetki kazanımını reddeder. |
| **Salt-okunur root filesystem** | Kalıcılık (persistence). Saldırgan webshell, backdoor veya değiştirilmiş binary bırakamaz — disk yazmayı kabul etmez. Hayatta kalmak için yazması gereken zararlı yazılım basitçe yazamaz. |
| **Seccomp `RuntimeDefault`** | Container escape. Kernel istismarlarında kullanılan tehlikeli/nadir syscall'lar kernele ulaşmadan filtrelenir. |
| **Pod Security Admission `restricted`** (K8s) | Kötü niyetli/yanlış yapılandırılmış manifestler. `privileged`, `hostPath` veya root isteyen bir pod **admission'da reddedilir** — koruma, inceleyenin dikkatine değil, API server'a bırakılmıştır. |
| **ServiceAccount token automount kapalı** (K8s) | Cluster ele geçirme. Ele geçirilen API pod'unda **çalınacak bir Kubernetes bearer token yoktur**, dolayısıyla secret'ları sayamaz veya kontrol düzlemine saldıramaz — K8s lateral movement'ın büyük bir sınıfını kapatır. |
| **Sırlar git dışında** (`.env` / Sealed Secrets / ESO) | Kimlik bilgisi sızıntısı. DB parolaları repo'da asla düz metin olarak durmaz. |
| **Minimal multi-stage image** (final image'da derleyici, paket yöneticisi yok) | Living-off-the-land. Saldırganın exploit derleyeceği ya da araç indireceği `gcc`, `apt` veya build zinciri yoktur. |
| **Resource requests/limits** (K8s) | Kaynak-tüketimi DoS ve cryptomining. Kontrolden çıkmış veya ele geçirilmiş bir container cgroup'larla sınırlanır, komşularını aç bırakamaz. |

**Kill chain'i adım adım yürüyelim.** Diyelim ki saldırgan Flask uygulamasında RCE buldu — gerçekçi en kötü başlangıç noktası:

1. Bir shell'i var — ama **uid 1000, non-root** olarak ve **tüm capability'ler düşürülmüş** halde.
2. Bir setuid binary ile yükselmeyi dener → **`no-new-privileges` engeller**.
3. Kalıcı bir backdoor bırakmayı dener → **salt-okunur filesystem yazmayı reddeder**.
4. Veritabanına sıçramayı dener → nginx onu göremez bile, API katmanından ise **yalnızca** izin verilen tam portlarda postgres/redis'e ulaşır — başka hiçbir şeye değil ve asla internete değil (default-deny egress).
5. Kubernetes'te cluster'a saldırmak için bir service-account token'ı arar → **mount edilmiş bir token yoktur**.

İlk yer edinmeden sonraki her adım bir duvara çarpar. Tüm mesele bu.

### Zero-trust ağ (Kubernetes)

`k8s/base/network-policies.yaml` tüm pod'larda bir **default-deny** ile başlar (hem ingress *hem* egress), ardından yalnızca gereken yolları açar:

```
internet ──▶ nginx :8080 ──▶ api :5000 ──┬─▶ postgres :5432
                                          └─▶ redis    :6379
```

- Her pod varsayılan olarak **yalnızca** DNS'e ulaşabilir.
- `postgres` ve `redis` bağlantıları **yalnızca `api`'den** kabul eder.
- Namespace içindeki hiçbir şey internete egress yapamaz.

> NetworkPolicy'yi zorlayan bir CNI gerektirir (Calico / Cilium). kind'in varsayılan `kindnet`'i policy nesnelerini kabul eder ama **zorlamaz** — `scripts/bootstrap-kind.sh` içindeki nota bakın.

---

## İzolasyon kanıtı — kendin doğrula

Yukarıdaki iddialar sadece söylenmiyor; çalışan yığına karşı **kontrol ediliyor**.

```bash
make compose-up
make verify-isolation      # veya: ./scripts/verify-isolation.sh
```

Script canlı container'ları yoklar ve herhangi bir kontrol gerçekten zorlanmıyorsa yüksek sesle başarısız olur:

```
1. End-to-end path works (internet → nginx → api → postgres/redis)
  ✔ PASS  /health responds
  ✔ PASS  / responds (redis counter)
  ✔ PASS  /db-check responds (postgres)

2. Data tier is NOT exposed to the host  (defeats: direct DB attack from outside)
  ✔ PASS  postgres 5432 refused from host
  ✔ PASS  redis 6379 refused from host

3. Network segmentation  (defeats: lateral movement after edge compromise)
  ✔ PASS  nginx cannot reach postgres (not on data_net)
  ✔ PASS  nginx cannot reach redis (not on data_net)
  ✔ PASS  api can reach postgres + redis (only it is on data_net)

4. Container hardening on the API  (defeats: privilege escalation & persistence)
  ✔ PASS  api runs as non-root (uid=1000)
  ✔ PASS  api rootfs read-only (cannot drop backdoor)
  ✔ PASS  all Linux capabilities dropped (cap_drop: ALL)
  ✔ PASS  privilege escalation disabled (no-new-privileges)
  ✔ PASS  read-only root filesystem enforced by runtime

Summary: 13 passed, 0 failed
All isolation & hardening controls verified.
```

---

## Depo yapısı

```
.
├── api/                      # Flask uygulaması + multi-stage Dockerfile
├── docker-compose.yml        # Aşama 1: sertleştirilmiş Compose yığını
├── k8s/
│   ├── base/                 # Aşama 2: ortamdan bağımsız manifestler
│   │   ├── namespace.yaml            # Pod Security Admission: restricted
│   │   ├── serviceaccounts.yaml      # workload başına SA, token automount kapalı
│   │   ├── secret.yaml               # DB kimlik bilgileri (demo placeholder)
│   │   ├── postgres.yaml             # StatefulSet + headless Service + PVC
│   │   ├── redis.yaml                # Deployment + Service
│   │   ├── api.yaml                  # Deployment + Service + probe'lar
│   │   ├── nginx.yaml                # Deployment + Service (+ üretilen ConfigMap)
│   │   ├── nginx.conf                # tek doğruluk kaynağı (Compose + K8s)
│   │   ├── ingress.yaml              # cluster-kenarı giriş noktası
│   │   ├── network-policies.yaml     # zero-trust segmentasyon
│   │   ├── pdb.yaml                  # PodDisruptionBudget'lar
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/              # katman başına 1 replica — laptop / kind
│       └── prod/             # HA replica + HPA + immutable registry tag
├── kind/                     # lokal cluster config'i
├── scripts/
│   ├── bootstrap-kind.sh     # tek komutla lokal cluster + dağıtım
│   ├── teardown-kind.sh
│   └── verify-isolation.sh   # izolasyon/hardening kontrollerinin geçerliliğini kanıtlar
├── .github/workflows/ci.yaml # her overlay'i render + şema-valide et, image build et
└── Makefile
```

Tüm görevleri görmek için `make help` çalıştırın.

---

## Gösterilen cloud-native kavramlar

- **StatefulSet + `volumeClaimTemplates`** ile veritabanı; volume sahipliğini `fsGroup` yönetir — Compose yığınının ihtiyaç duyduğu tek seferlik `pg-init` chown container'ının yerel (native) karşılığı.
- **Kustomize base + overlay'ler** — tek doğruluk kaynağı, ortam farkları patch olarak ifade edilir (replica, otomatik ölçekleme, image tag). Templating motoru yok, GitOps'a hazır.
- **Probe'lar** — `startupProbe` yavaş ilk açılışı korur, ardından `liveness`/`readiness` devreye girer; trafik yalnızca Ready pod'lara yönlendirilir.
- **Horizontal Pod Autoscaler** (prod) — CPU tabanlı ölçekleme, scale-down stabilizasyon penceresiyle.
- **PodDisruptionBudget** — node drain ve upgrade sırasında en az bir replica'yı ayakta tutar.
- **Pod Security Admission (`restricted`)** — sertleştirme API server'da zorlanır, sadece umulmaz.
- **NetworkPolicy** — açık, en az yetkili doğu-batı (east-west) trafiği.
- **Immutable, registry'de barınan image tag'leri** (prod) ile lokal build edilen `:latest` (dev) karşılaştırması.

---

## Lokal doğrulama (cluster gerekmez)

```bash
# Her iki overlay'i render et ve her nesneyi şema açısından kontrol et
kubectl kustomize k8s/overlays/dev  | kubeconform -strict -summary -ignore-missing-schemas
kubectl kustomize k8s/overlays/prod | kubeconform -strict -summary -ignore-missing-schemas
```

CI, her push ve pull request'te tam olarak bunu çalıştırır.

---

## Gereksinimler

- **Aşama 1:** Docker + Docker Compose
- **Aşama 2:** `kubectl`; lokal cluster için `kind`; offline doğrulama için `kustomize` + `kubeconform`
