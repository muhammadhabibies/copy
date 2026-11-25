# Hasil migrasi Berumrah ke berumrah.com

Tanggal: 2026-11-25. Status: **cutover apex, API, dan dashboard `.com` aktif; penerimaan akhir belum lengkap**.

Plan disetujui: [Plan-Migrasi-Berumrah-Com.md](Plan-Migrasi-Berumrah-Com.md). Domain utama: **https://berumrah.com**, tanpa `www`.

## 1. Ringkasan keadaan produksi

| Hostname | Keadaan terverifikasi |
| --- | --- |
| `https://berumrah.com` | Frontend produksi, HTTP `200`, proxy `127.0.0.1:3081` |
| `https://api.berumrah.com/health` | Backend produksi, HTTP `200`, proxy `127.0.0.1:3080` |
| `https://dash.berumrah.com` | Dashboard produksi, HTTP `200`, proxy `127.0.0.1:3082` |
| `https://berumrah.id` | Redirect sementara `302` ke `https://berumrah.com$request_uri` |
| `https://dash.berumrah.id` | Redirect sementara `302` ke `https://dash.berumrah.com$request_uri` |
| `https://api.berumrah.id/health` | Backend lama tetap HTTP `200`, tanpa redirect lintas domain |
| `www.berumrah.com`, `www.berumrah.id` | **Selesai dan diuji:** DNS Cloudflare resolve; alias aaPanel ditambahkan pada situs `139` dan `94`; sertifikat Let's Encrypt SAN apex+`www` terpasang (berlaku sampai `2027-02-23`); HTTPS tanpa `-k` valid; `www.berumrah.com` → `308` dan `www.berumrah.id` → `302` ke `https://berumrah.com` dengan path/query utuh; ACME HTTP/HTTPS diuji pada keempat host |
| `assets.berumrah.id` | Tetap di server aset existing; DNS/bucket/konfigurasinya tidak diubah |

HTTP `.com` serta API `.id` memakai upgrade HTTPS same-host `308`. HTTP apex/dashboard `.id` langsung `302` ke tujuan `.com`. Path, query, dan encoding diuji tetap utuh. **Redirect lintas domain belum diubah menjadi `301`** karena DNS `www`, Google Login, dan penerimaan integrasi belum tuntas.

## 2. Backup dan batas perubahan

- Backup privat: `/root/backups/berumrah-com-20261125T080027Z`; direktori induk mode `0700`.
- Backup mencakup konfigurasi terkait, build aktif sebelum migrasi, source terkait, environment, metadata aaPanel, metadata PM2, sertifikat, serta nilai SEO/slider sebelum perubahan. Isi rahasia tidak dicantumkan di laporan ini.
- Dump database berhasil: `database-before-migration.sql`, ukuran `1320884` byte. Tidak menjalankan migrasi skema, seeder, restore DB, atau perubahan transaksi.
- Baseline 64 hostname HTTPS origin disimpan sebelum perubahan. Sepuluh request sudah gagal pada baseline; hasil sesudah dibandingkan terhadap keadaan awal, bukan dianggap seluruhnya dampak migrasi.
- Snapshot tambahan konfigurasi sebelum penguatan routing: `before-routing-hardening-20261125T133238Z/` di direktori backup.
- Preview sementara dihentikan sengaja setelah promosi. Exit `241` dari wrapper preview bukan crash proses produksi. Direktori preview/staging milik pekerjaan ini dipindahkan ke `retired-preview-and-staging/` dalam backup privat, bukan dihapus. Staging PWA terakhir `dist.pwa-stage.20261125T135147Z` diarsipkan melalui rename atomik pada `2026-11-25T15:11:42Z`: seluruh 454 file/26321681 byte dipertahankan dan hash diverifikasi; `dist` aktif tidak diubah. Listener uji `13081`/`13443` sudah tidak terbuka.
- Tidak melakukan upgrade dependensi, penggantian domain global, perubahan email/MX/TXT, pemindahan aset, pengosongan Redis global, atau perubahan aplikasi tenant lain.

## 3. aaPanel, TLS, dan Nginx

### Situs dan sertifikat

Tiga situs dibuat melalui metode aaPanel yang didukung, tanpa mengedit SQLite panel secara manual:

| Situs | ID aaPanel | TLS origin | Akhir masa berlaku |
| --- | --- | --- | --- |
| `api.berumrah.com` | `137` | Let's Encrypt | `2027-02-23` |
| `dash.berumrah.com` | `138` | Let's Encrypt | `2027-02-23` |
| `berumrah.com` | `139` | Let's Encrypt | `2027-02-23` |

- Metadata ketiga sertifikat menunjukkan `auto_renew=1`, autentikasi HTTP, dan asosiasi `user_for.sites` yang sesuai. Renewal masa depan belum dapat dibuktikan hanya dari metadata; jalur challenge sudah diuji.
- Alias `www`: `www.berumrah.com` ditambahkan ke situs `139` dan `www.berumrah.id` ke situs `94` melalui `AddDomain` aaPanel (hanya `server_name` yang berubah; diff terhadap backup bersih). Vhost `.com` mendapat satu baris `if ($host = www.berumrah.com) { return 308 https://berumrah.com$request_uri; }` setelah include ACME.
- Sertifikat SAN baru (`berumrah.com`+`www.berumrah.com`, `berumrah.id`+`www.berumrah.id`, Let's Encrypt, HTTP validation, berlaku sampai `2027-02-23`) diterbitkan dengan modul ACME bawaan aaPanel dan disalin ke `vhost/cert/<domain>/`; kecocokan kunci/sertifikat diperiksa, `nginx -t` lolos sebelum reload. Backup sebelum perubahan: `before-www-aliases-20261125T155913Z/`.
- **Catatan penting:** pyOpenSSL terpasang (26.x) tidak lagi menyediakan `crypto.sign`/`X509Req`, sehingga modul ACME aaPanel gagal apa adanya. Penerbitan memakai shim hanya di proses skrip sementara (`verification-tools-closeout/www-cert-apply.py`); pustaka panel tidak diubah. Sertifikat tidak otomatis dipasang oleh panel (jumlah SAN berbeda), jadi dipasang manual. **Renewal otomatis kedua sertifikat ini belum terbukti** dan kemungkinan gagal karena masalah pyOpenSSL yang sama (juga berlaku untuk sertifikat panel lain). Tindakan: perpanjang manual atau perbaiki lingkungan ACME panel sebelum `2027-02-23`.
- Enam vhost Berumrah memisahkan blok HTTP/HTTPS dan mempertahankan jalur `/.well-known/acme-challenge/`.
- Uji challenge sementara: **24/24 lolos**, mencakup enam host, HTTP/HTTPS, origin/publik. File challenge uji sudah dihapus.
- HTTPS publik dan origin enam hostname aktif diuji tanpa `-k`. Kedua `www` juga diuji: sertifikat SAN apex+`www` untuk `.com` dan `.id` terpasang, `domain-verification-www.json` 32 pemeriksaan (publik+origin) tanpa kegagalan transport, redirect sesuai.
- Keberhasilan publik/origin bukan bukti isi record origin Cloudflare atau mode SSL pada dashboard. Akses akun Cloudflare belum tersedia untuk audit langsung.

### Proxy dan isolasi hostname

- Proxy aplikasi `.com` serta API `.id` menggunakan header host/protokol yang sesuai dan IP klien tersanitasi.
- Kepercayaan `CF-Connecting-IP` dibatasi pada rentang IP resmi Cloudflare melalui `berumrah-com-support/cloudflare-realip.inc`; bukan menerima header tersebut dari sembarang koneksi.
- `berumrah-com-support/proxy-app.inc` mematikan pewarisan `proxy_cache` pada aplikasi dinamis. Konfigurasi cache global tenant lain tidak diubah.
- Default HTTP menolak hostname asing dengan `444`; default HTTPS memakai `ssl_reject_handshake on`, bukan memberikan sertifikat/aplikasi tenant pertama.
- Host sah `ai.digyta.net` tetap merespons `307` ke `/dashboard`; health Nginx lokal tetap `200`.
- Perbandingan awal **64 hostname** tidak menemukan kegagalan baru. Setelah perubahan PWA, satu probe berbatas 8 detik ke `temanberobat.com` timeout; pemeriksaan langsung origin/publik berikutnya keduanya `200`. Pengulangan penuh 64 host dengan batas 15 detik/concurrency 4 tidak menemukan kegagalan request baru. Bukti timeout awal tetap disimpan, tidak ditimpa sebagai sukses. Perubahan respons sukses yang direncanakan adalah redirect apex/dashboard `.id`.
- Listener default IPv6 dikonfigurasi, tetapi IPv6 OS dinonaktifkan (`net.ipv6.conf.all.disable_ipv6=1`, loopback juga `1`). Uji koneksi IPv6 tidak membuktikan perilaku listener.
- Setiap reload yang dilakukan didahului `nginx -t` berhasil. Pemeriksaan ulang terakhir setelah perapian juga berhasil.

## 4. Konfigurasi dan release aplikasi

Hanya nilai domain berikut diperbarui; kredensial, database, port produksi, dan endpoint aset dipertahankan.

Backend `be-marketplace/.env`:

```dotenv
FRONTEND_URL=https://berumrah.com
BACKEND_URL=https://api.berumrah.com
DASHBOARD_URL=https://dash.berumrah.com
CORS_ALLOWED_ORIGINS=https://berumrah.com,https://dash.berumrah.com,https://berumrah.id,https://dash.berumrah.id
```

Frontend `fe-marketplace/.env`:

```dotenv
VITE_APP_URL=https://berumrah.com
VITE_API_URL=https://api.berumrah.com/api
```

Dashboard `dash-marketplace/.env`:

```dotenv
VITE_APP_URL=https://dash.berumrah.com
VITE_FRONTEND_URL=https://berumrah.com
VITE_API_BASE_URL=https://api.berumrah.com/api
```

- Frontend dan dashboard memakai API `.com` karena cookie refresh host-only dan `SameSite=Strict`; browser tidak memindahkan cookie/token dari `.id` ke `.com`. Pengguna perlu login ulang, bukan membuat akun/pesanan baru.
- Dua build berhasil di staging terpisah, kemudian dipromosikan ke `dist` produksi. Bundle kandidat memakai API `.com`; sourcemap tidak dipublikasikan.
- Aset hashed build lama dipertahankan untuk tab yang masih terbuka. Perbandingan rekursif terakhir pada `2026-11-25T15:05:40Z` menemukan seluruh **450 file aset frontend dan 221 file aset dashboard** dari backup tetap tersedia dengan bytes identik; tidak ada file hilang, berubah, atau diganti symlink. Entry JavaScript lama dari kedua host `.com` juga merespons `200`.
- Backend/frontend/dashboard di-reload dan worker existing di-restart dengan pembaruan environment; tidak membuat worker duplikat. Keempat proses PM2 berstatus `online` pada pemeriksaan terakhir. Jumlah restart adalah angka kumulatif, bukan seluruhnya insiden migrasi.
- Dua URL tujuan frontend di footer/konten kreator dan satu placeholder SEO dashboard diubah ke `.com`. Identifier kreator, nama merek, email, portal, serta URL aset tidak diganti global.

## 5. SEO, data, dan cache

- `app_settings` kategori `seo`, key `site_url`, diubah melalui `appSettingsService.updateSetting` menjadi `https://berumrah.com`.
- Tepat satu slider yang dicatat sebelum migrasi diubah dari `https://berumrah.id/tabungan` menjadi `https://berumrah.com/tabungan`; tidak melakukan penggantian massal DB.
- Invalidasi dibatasi pada cache app-settings, SEO, dan slider terkait. Tidak menggunakan tombol Clear Cache global, `FLUSHDB`, atau `FLUSHALL`.
- Invalidasi slider awal gagal karena koneksi Redis bersama sudah ditutup; invalidasi terpisah berikutnya berhasil. Pemeriksaan ulang key `berumrah-marketplace:seo:settings` menunjukkan URL `.com`.
- Homepage publik/origin memuat canonical `https://berumrah.com`.
- Sitemap publik/origin memuat **46 URL**, seluruh `<loc>` memakai `.com`.
- `robots.txt` situs utama tidak memblokir seluruh crawler; dashboard tetap memblokir crawler dan halaman signin memuat `noindex, nofollow`.
- Pengujian tersebut tidak berarti seluruh override canonical per artikel atau konfigurasi analytics eksternal sudah ditinjau pemilik akun.

## 6. Hasil pengujian dan batas bukti

| Pemeriksaan | Hasil / batas |
| --- | --- |
| Health website/API/dashboard `.com`, publik dan origin | Lolos, HTTP `200` |
| API `.id`, publik dan origin | Tetap HTTP `200`, tanpa redirect lintas domain |
| Redirect apex/dashboard `.id` | Lolos; path/query/encoding utuh |
| TLS host aktif tanpa `-k` | Lolos, termasuk kedua `www` |
| ACME challenge | 24/24 lolos; file uji dibersihkan |
| CORS empat origin frontend/dashboard `.com` dan `.id`, pada kedua host API | Preflight `204`, origin tepat, credentials `true` |
| CORS origin asing | Tidak mendapat allow-origin/credentials; backend existing memberi `500`, bukan kegagalan origin yang diizinkan |
| GET gambar/aset publik dan presigned GET dari origin lama/baru | Lolos; tidak mengubah konfigurasi server aset |
| Browser terisolasi: homepage/login/about/dashboard signin/redirect lama | Vue mounted, API publik/gambar termuat, tidak ada fatal page error |
| Google Login | **Terblokir**: GIS button `403`, `The given origin is not allowed for the given client ID.` |
| Service worker/PWA | Kandidat 4/4 lolos. Suite live lengkap `2026-11-25T16:11Z` (setelah `www`) **4/4 lolos**, 450 entry precache. Suite lengkap sebelumnya (`15:04Z`) 3/4 dengan satu timeout fresh worker 180 detik yang tetap **tak terjelaskan**; tiga uji fresh lain lolos. Hasil tidak konsisten secara historis (1 gagal dari 2 suite lengkap), sehingga risiko intermiten tidak dinyatakan hilang |
| Login password, logout, refresh token, role | Belum diuji dengan akun uji yang diizinkan |
| Upload file baru, form mutasi, pembayaran, webhook transaksi | Tidak dijalankan |
| 64 hostname pada server bersama | Tidak ada kegagalan request baru dibanding baseline |

Browser verifikasi memblokir permintaan mutasi dan tidak mengirim formulir. Request Cloudflare RUM yang diblokir pengujian bukan error aplikasi. Tidak mengklaim login, pembayaran, atau upload berhasil hanya dari halaman/form yang tampil.

### Temuan tambahan: service worker dan satu endpoint SEO

- Frontend lama dan build `.com` awal sama-sama mengecualikan HTML dari precache, sementara default Workbox tetap menunjuk `index.html`. `createHandlerBoundToURL("index.html")` menimbulkan `non-precached-url` saat inisialisasi. Worker dapat terpasang sebagian, sehingga pesan error ini bukan bukti semua navigasi gagal.
- `navigateFallback: null` sudah dibangun dan dipromosikan setelah **4/4 uji kandidat Chromium terisolasi lolos**. Ada 450 entry precache, tanpa HTML precache atau handler HTML terikat; strategi `NetworkFirst`/`NetworkOnly` tetap ada. Perbandingan bytes membuktikan hanya `sw.js` dan helper `workbox-64ecca59.js` berbeda dari build sebelumnya. Helper disalin lebih dahulu, `sw.js` diganti secara atomik; tidak mengganti seluruh dist atau menghapus chunk lama. Snapshot: `before-pwa-fix-20261125T135053Z/` dan `pwa-worker-promotion-15vyyhwt/` dalam backup privat.
- HTTPS `https://berumrah.id/sw.js` kini mendapat pengecualian exact location: **200 JavaScript**, `Cache-Control: no-store, no-cache, must-revalidate, max-age=0`, tanpa `Location`. Respons origin/publik dan varian query memiliki hash sama dengan source yang diuji. Halaman `.id` lain tetap `302` dengan encoding/path/query utuh. Source non-rahasia: `/root/copy/berumrah-id-retire-sw.js`; deployment: `/www/wwwroot/berumrah.com/.domain-migration/berumrah-id-retire-sw.js`. Tidak menghapus cache/storage atau memaksa `clients.navigate()`.
- `server.js` sekarang melewatkan `/index.html` eksplisit ke handler HTML dinamis, bukan cache statis setahun; HTML memakai `Cache-Control: no-cache, must-revalidate`. Frontend PM2 existing saja di-reload. Header origin/publik setelah reload sudah sesuai. Ini terpisah dari penyebab `non-precached-url`. Header HTTP tersebut tidak melarang Workbox menyajikan HTML dari Cache Storage: strategi existing `NetworkFirst` tetap memakai timeout jaringan 1 detik dan batas usia cache 1 hari.
- Uji kandidat membuktikan fresh worker `.com` aktif, `/` dan `/programs` mounted/reload melalui worker, serta `html-navigation-cache` terisi. Worker backup `.id` dan synthetic cached-navigation worker dapat diganti worker retirement pada script URL yang sama. Sebanyak 451 dan 2 entry cache masing-masing dipertahankan, bersama sentinel localStorage/sessionStorage/IndexedDB/cookie. Uji navigasi berikutnya dan new-tab pada context yang sama mencapai `.com` dengan encoded query utuh.
- Uji live pertama setelah deploy meloloskan header HTML/worker dan kedua skenario retirement memakai **bytes worker publik yang benar-benar dideploy**. Fresh worker `.com` belum mencapai aktivasi/controller dalam batas 45 detik. Kegagalan awal tetap disimpan.
- Uji live terfokus pada `2026-11-25T15:01:29Z` **2/2 lolos**, bukan suite lengkap: worker `.com` mencapai `activated`/controller setelah 42433 ms sejak penantian dimulai, 450 entry precache tersedia, `/` dan `/programs` mounted/reload melalui worker, dan `html-navigation-cache` berisi kedua URL. Tidak ada `non-precached-url` atau fatal page error. Error `no-response` untuk Google Fonts berasal dari domain pihak ketiga yang sengaja diblokir harness, bukan kegagalan precache lokal.
- Pengulangan suite live lengkap pada `2026-11-25T15:04:05Z` **3/4 lolos**: header dan kedua skenario retirement lolos; fresh worker `.com` timeout setelah 180000 ms. Snapshot akhir menunjukkan controller/active belum ada, worker masih `installing`, 174 dari 450 entry precache tersimpan, 177 request worker dimulai, 176 selesai dengan HTTP `200`, tanpa request gagal/error worker/fatal page error. Satu request terakhir masih berjalan sekitar 909 ms saat snapshot. Bukti tidak menunjukkan worker menjadi `redundant` atau gagal evaluasi; juga belum membuktikan instalasi akan selesai jika dibiarkan lebih lama. Hasil aktivasi publik tidak konsisten, sehingga **belum mengklaim installed-PWA publik lolos penuh**.
- Suite live lengkap setelah `www` aktif (`2026-11-25T16:11:42Z`): **4/4 lolos** (`pwa-full-suite-after-www.out`, `pwa-browser-verification-after-www.json`); fresh worker `.com` aktif, retirement real/synthetic `.id` lolos, SHA `sw.js` `57ffba73…`, 450 entry precache. Ini tidak menjelaskan penyebab timeout sebelumnya.
- Dua uji fresh-worker live terpisah (`15:38:36Z`, `15:39:36Z`; hanya `fresh`, bukan suite lengkap) **lolos**: aktivasi 47523 ms dan 51782 ms, 450 entry precache, `/` dan `/programs` mounted/reload melalui worker, tanpa `non-precached-url`/page error. Total fresh live: 3 lolos (42–52 detik), 1 timeout 180 detik (suite lengkap), 1 timeout 45 detik (batas lama). Aktivasi memakan sekitar 42–52 detik saat lolos, sehingga batas 45 detik terlalu ketat; satu kegagalan 180 detik belum terjelaskan dan tidak dihapus. Kemungkinan variasi jaringan/harness belum terbukti; tidak ada perubahan produksi.
- Sampel GET terpisah sesudah timeout berhasil pada publik dan origin, termasuk URL terakhir yang tertunda; enam GET Chromium statis juga HTTP `200` dalam 65–207 ms. Sampel tersebut bukan request saat instalasi gagal. Ringkasan log origin mencatat 175 request aset Chrome 156 selama jendela uji gagal, dibanding dua selama uji terfokus; Cloudflare HIT tidak harus mencapai origin. Perbedaan cache/jaringan/harness masih perlu ditelusuri; belum menetapkan akar penyebab atau mengubah precache/cache produksi. Diagnosis terbatas ini selesai dan bukti disimpan; tidak ada uji PWA masih berjalan.
- Batas uji: context sementara bukan profil pengguna atau sensus instalasi, old-origin memakai bootstrap/synthetic fixture bukan SPA/form asli, relaunch berupa new-tab bukan restart browser/OS. Listener `autoUpdate` existing tetap bisa me-reload halaman saat update aktif. Tidak ada janji transisi segera bagi semua pengguna atau tanpa interupsi formulir. PWA `.id` tidak berubah identitas menjadi instalasi `.com`; pemasangan `.com` terpisah dan login ulang mungkin diperlukan. Worker retirement tetap terdaftar dan mengarahkan navigasi, tanpa menyediakan fallback offline aplikasi `.id` meskipun cache lama dipertahankan. Redis/Cloudflare purge tidak mengganti worker yang sudah terpasang.
- GET endpoint `/api/seo/programs/umrah-sya-ban-plus-thaif-12-hari-2x-jumat-umrah-pro/keberangkatan-21-januari-2027-pro` masih memberi `500` pada **kedua** hostname API. Audit mengaitkan log persis kedua slug dengan `Cannot read properties of null (reading 'replace')`: `controllers/seoController.js:119–120` memanggil `.replace()` pada `batch.package.description`, sementara model `Package` mengizinkan `description=null`. Lookup tidak bergantung hostname; kedua host memakai backend port `3080` yang sama. Ini cacat penanganan nilai null/data aplikasi, bukan bukti routing domain gagal. Belum ada baseline endpoint sebelum migrasi untuk menyatakan pasti sudah ada. Tidak mengubah backend/data sebagai bagian audit ini; perbaikan terpisah masih diperlukan. Homepage, health, sitemap tetap berfungsi, tetapi fallback meta frontend dapat menutupi masalah halaman terkait.

Bukti non-rahasia disimpan di backup privat:

- `domain-verification-www.json` (32 pemeriksaan publik+origin termasuk `www`), `pwa-full-suite-after-www.out`, `pwa-browser-verification-after-www.json`
- `domain-verification-after.json`, `domain-verification-final.json`, `domain-verification-closeout.json` (pemeriksaan akhir 24/24 lolos tanpa `-k`)
- `browser-verification.json` (uji ulang setelah PWA; worker diblokir pada suite ini)
- `pwa-browser-verification.json` (riwayat uji kandidat/live, termasuk kegagalan verifier/timeout), `pwa-live-summary-closeout.json`
- `pwa-live-http-checks.json`, `retirement-http-closeout.json` (uji ulang worker/redirect 8/8), `cors-verification-final.json`
- `pwa-asset-timing-sample.json`, `pwa-asset-cache-request-sample.json`, `pwa-asset-browser-timing.json`, `pwa-origin-log-window-summary.json` (sampel diagnosis, bukan bukti akar penyebab)
- `final-runtime-and-assets.json` (empat proses PM2 online, aset backup identik, `nginx -t` lolos), `closeout-probes.json` (DNS `www` dan isolasi hostname)
- `pwa-staging-archive.json`, `pwa-temporary-listeners-closeout.json`, `approved-plan-closeout.json`, `git-and-additional-verifier-closeout.json`, `verification-tools-closeout/`
- `acme-routing-checks.json`, `acme-routing-final.json` (keduanya 24/24)
- `other-sites-baseline.json`, `other-sites-after.json`, `other-sites-final.json`, `other-sites-final-recheck.json`

## 7. Pekerjaan yang memerlukan pemilik akun

1. **Cloudflare DNS:** CNAME/record `www` untuk kedua zona sudah dibuat pemilik dan resolve. Alias aaPanel serta sertifikat SAN apex+`www` sudah dikonfigurasi dan diuji (lihat bagian sertifikat).
2. **Cloudflare routing/SSL:** verifikasi apex/API/dashboard `.com` memakai origin aplikasi `84.247.144.127`, bukan origin aset `109.123.236.101`; audit SSL, Origin Rules, Redirect Rules, Workers, Page Rules, dan cache. Jangan mengubah mode SSL tingkat zona `.id` tanpa memeriksa hostname lain. Token/password tidak dikirim melalui percakapan atau Git.
3. **Google Cloud Console:** pada OAuth client existing, tambahkan `https://berumrah.com` pada Authorized JavaScript origins dan `berumrah.com` pada Authorized domains; perbarui branding/homepage/privacy/terms bila masih lama. Pertahankan origin `.id`. Alur yang diperiksa memakai Google Identity Services callback JavaScript, bukan callback OAuth server baru.
4. **Penyedia pembayaran:** konfirmasi whitelist domain/callback/return Paylabs dan Doit. Environment baru menghasilkan notify Paylabs `https://api.berumrah.com/api/webhook/paylabs` serta return frontend `.com`. API `.id` tetap melayani callback transaksi lama. Jangan mengirim transaksi nyata atau webhook palsu ke produksi sebagai pemeriksaan.
5. **Penerimaan aplikasi:** gunakan akun uji yang diizinkan untuk password/Google login, logout, refresh, akses role, dokumen/upload, dan return pembayaran sesuai prosedur uji yang disetujui. Cookie/localStorage lintas domain tidak berpindah otomatis.
6. **Search Console dan tautan publik:** verifikasi properti `.com`, submit sitemap, lakukan Change of Address setelah syarat terpenuhi, lalu pantau crawl/indeks. Perbarui kampanye, profil sosial, analytics, dan tautan eksternal bertahap.

## 8. Rollback dan penerimaan akhir

**Rollback otomatis sengaja dinonaktifkan.** Versi awal ditolak karena pemulihan parsial dapat meninggalkan environment/build/Nginx tidak selaras. `/root/copy/rollback-berumrah-domain.sh` kini menjadi planner pasif; `--apply`, termasuk bila dipasangkan dengan `--confirm-production-rollback`, ditolak sebelum inspeksi atau perubahan apa pun. Transaksi pemulihan otomatis belum diuji runtime, sehingga tidak disediakan jalur eksekusi produksi yang berisiko.

Review ulang dan pengujian pasif lolos: `bash -n`, parse Python tersemat, default dry run, serta tiga guard apply di memori. Dry run memeriksa path/symlink/hardlink, rencana domain-only environment, keempat origin CORS, konflik aset hashed, backup vhost, dan metadata empat proses PM2 existing. Tidak menjalankan `nginx -t/reload`, PM2 CLI/reload/start, capture/staging, health probe, SQL, atau perubahan cache. Peringatan izin `.env` backend yang sudah world-readable dicatat; planner tidak mengubah izin.

Panduan operator terpisah dapat dicetak tanpa menjalankannya:

```bash
bash /root/copy/rollback-berumrah-domain.sh --manual
```

Panduan mencakup locking, snapshot privat unik, staging, langkah pemulihan komponen bila gagal, domain-only env, retensi aset lama, expected-current guards untuk SEO/slider, invalidasi cache terarah, serta pengecualian worker browser. Contoh operasi data hanya diperiksa sintaksnya, tidak dieksekusi. Pemulihan DB dan invalidasi Redis bukan transaksi atomik lintas layanan: perubahan row dapat sudah committed bila invalidasi berikutnya gagal, sehingga operator harus menangani keadaan parsial sesuai runbook. **Planner/runbook bukan rollback satu perintah dan bukan bukti rollback runtime berhasil.**

Backup sebelum migrasi tetap tersedia. Rollback domain tidak memerlukan restore seluruh DB atau metadata SQLite aaPanel. Pemulihan data SEO/slider harus dibatasi pada nilai dan row yang benar-benar diubah, dengan pemeriksaan nilai saat ini; cache hanya dihapus secara terarah. Aset hashed lama, layanan `.com`, dan keempat origin CORS perlu dipertahankan untuk kompatibilitas tab/link selama transisi. Cache browser/service worker perlu ditangani terpisah dari Redis/Cloudflare.

Worker retirement yang sudah terpasang dapat tetap mengarahkan `.id` ke `.com` setelah rollback server. URL yang **sama**, `https://berumrah.id/sw.js`, harus kembali melayani worker aplikasi `.id` yang sudah divalidasi, HTTPS `200` JavaScript dengan `no-store`, lalu browser perlu memperbarui dan mengaktifkannya. Pengecualian alias retirement harus diganti/dilepas secara sesuai, bukan membiarkan `/sw.js` ikut redirect. Worker backup memiliki cacat fallback HTML lama; jangan memulihkannya sebagai worker sehat tanpa validasi. Purge Redis/Cloudflare saja tidak memulihkan worker browser.

Checklist penerimaan:

- [x] Apex/API/dashboard `.com` melayani aplikasi yang benar.
- [x] API `.id` serta aset existing dipertahankan.
- [x] Redirect `.id` sementara bekerja tanpa kehilangan path/query.
- [x] TLS origin/publik enam host aktif, ACME, CORS, SEO dasar, dan shared-host comparison lolos.
- [x] Kedua `www` resolve, terdaftar, memiliki TLS sesuai, dan redirect ke apex `.com` (`308` untuk `.com`, `302` sementara untuk `.id`).
- [x] Audit source, perbaikan fallback, retirement `.id`, dan uji kandidat 4/4 selesai; cache/storage fixture dipertahankan.
- [ ] Penerimaan PWA publik konsisten: suite lengkap terbaru 4/4 lolos (`16:11Z`), tetapi suite sebelumnya 3/4 dengan timeout 180 detik tak terjelaskan. Perlu persetujuan penerimaan risiko atau pengulangan tambahan.
- [ ] Konfigurasi Google selesai dan login diuji dengan akun uji.
- [ ] Pemilik akun mengonfirmasi whitelist/callback/return pembayaran dan Cloudflare rules/SSL.
- [ ] Login/logout/refresh/role/upload diuji sesuai izin.
- [x] Script rollback direview ulang; apply otomatis dinonaktifkan, dry run pasif lolos, runbook dan batas runtime dicatat.
- [ ] Redirect lintas domain dipromosikan ke `301` setelah persetujuan penerimaan.
- [ ] Search Console dan pemantauan pascamigrasi ditangani pemilik akun.

## 9. Keadaan Git

Keadaan pada `2026-11-25T15:16:22Z`, setelah perbaikan dan pengarsipan staging PWA:

- `/root/copy`: plan sudah tracked pada commit existing `43f1ff0` (`wip`); laporan, planner rollback, dan `berumrah-id-retire-sw.js` masih untracked. Commit existing tidak diubah.
- `be-marketplace`: tracked working tree bersih; environment produksi ignored oleh Git.
- `fe-marketplace`: perubahan lokal `src/components/LandingPage/Footer.vue`, `src/pages/KontenKreator/Index.vue`, `vite.config.js`, dan `server.js`.
- `dash-marketplace`: perubahan lokal `src/views/Admin/AppSettings/SocialSeoSettings.vue`.
- Staging PWA tidak lagi untracked di frontend; arsip privat dan manifest hash tersedia. `git diff --check` lolos pada keempat repositori; pemeriksaan ini tidak memvalidasi file untracked.
- Build/environment/konfigurasi server tidak seluruhnya tercakup Git; backup privat tetap diperlukan.
- Tidak menjalankan commit atau push dalam pekerjaan migrasi ini.
