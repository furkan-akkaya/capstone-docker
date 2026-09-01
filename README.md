# Hardened Multi-Service Docker Capstone

Nginx → Flask API → PostgreSQL + Redis mimarisinde, ağ segmentasyonu ve container hardening uygulanmış, uçtan uca çalışan bir Docker Compose sistemi.

## Mimari

- `public` network: sadece nginx burada, host'a açık tek network
- `app_net` (`internal: true`): nginx ↔ api arası, dış dünyaya çıkışı yok
- `data_net` (`internal: true`): api ↔ postgres/redis arası, tamamen izole — postgres ve redis'e host'tan hiçbir şekilde doğrudan erişilemez

## Güvenlik Sertleştirmeleri (Hardening)

| Katman | Uygulama |
|---|---|
| Non-root çalıştırma | Her serviste ayrı, sabit UID (`appuser`, `999:999`, `101:101`) |
| Capability kısıtlama | `cap_drop: ALL` her serviste |
| Privilege escalation engeli | `security_opt: no-new-privileges:true` |
| Read-only filesystem | api ve nginx `read_only: true` + gerekli yerlerde `tmpfs` |
| Multi-stage build | API image'ında build araçları (gcc, libpq-dev) final image'da yok |
| Network segmentasyonu | Veritabanı ve cache dış dünyayı hiç görmüyor |
| Healthcheck tabanlı bağımlılık | `depends_on: condition: service_healthy` — servisler gerçekten hazır olmadan başlamıyor |

## Nasıl Çalıştırılır

\`\`\`bash
cp .env.example .env
# .env içindeki POSTGRES_PASSWORD'u değiştir
docker compose up -d
curl http://localhost:8080/health
\`\`\`

## Gerçek Dünya Debug Hikayesi

Bu proje "ilk denemede çalıştı" değil — hardening katmanları birbiriyle çatıştığında ortaya çıkan gerçek sorunları çözerek ilerledi:

1. **Redis/Postgres'in resmi image'ları root olarak başlayıp kendini non-root kullanıcıya düşürmeye çalışıyordu** (`gosu`/`setresuid`), `cap_drop: ALL` bunu engelliyordu → çözüm: container'ları doğrudan hedef kullanıcıyla (`user: "999:999"`) başlatmak, hiç root'a uğramadan.
2. **Postgres, ilk mount edilen volume'a chown atamıyordu** (root'a hiç uğramadığı için sahiplik değiştirme yetkisi yoktu) → çözüm: tek seferlik bir `pg-init` (busybox) container'ı ile volume'u önceden doğru sahiplikle hazırlamak.
3. **gVisor (`runsc`) runtime'ı, API container'ında Docker'ın embedded DNS'ine giden sorguları bozuyordu** (`Temporary failure in name resolution`) → teşhis edildi, bu servis için gVisor bilinçli olarak kaldırıldı; diğer hardening katmanları (non-root, cap_drop, read-only) korundu.
4. **Nginx healthcheck'i `localhost`'u IPv6 (`::1`) olarak çözüp reddediliyordu** → `127.0.0.1`'e sabitlenerek çözüldü.

Her sorun, körlemesine deneme yerine container logları okunarak teşhis edildi ve tek noktadan düzeltildi.

## Sonraki Adım

Bu proje Kubernetes'e geçiş için hazırlanıyor — her servis bir Deployment, `pgdata` volume'u bir PersistentVolumeClaim, network segmentasyonu bir NetworkPolicy, healthcheck'ler ise readiness/liveness probe olarak yeniden yazılacak.
