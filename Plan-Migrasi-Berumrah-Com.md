# Plan migrasi Berumrah ke berumrah.com

Tanggal: 2026-11-25.
Status awal: eksekusi disetujui; langkah produksi dicatat pada laporan terpisah.
Domain utama: **https://berumrah.com**, tanpa `www`.

## 1. Target akhir

| Hostname | Perilaku akhir |
| --- | --- |
| `berumrah.com` | Frontend utama `127.0.0.1:3081` |
| `www.berumrah.com` | Redirect langsung ke `https://berumrah.com$request_uri` |
| `berumrah.id` | Redirect langsung ke `https://berumrah.com$request_uri` |
| `www.berumrah.id` | Redirect langsung ke `https://berumrah.com$request_uri` |
| `api.berumrah.com` | Backend `127.0.0.1:3080` |
| `api.berumrah.id` | Backend yang sama, tanpa redirect untuk webhook/klien lama |
| `dash.berumrah.com` | Dashboard utama `127.0.0.1:3082` |
| `dash.berumrah.id` | Redirect ke `https://dash.berumrah.com$request_uri` setelah pengujian |
| `assets.berumrah.id` | Tetap memakai origin aset sekarang |
| Portal/travel/login/hisar lainnya | Tidak berubah tanpa audit terpisah |
| Hostname/SNI tidak dikenal | Ditolak, bukan menampilkan 9router |

## 2. Temuan awal

- IP publik server aplikasi: `84.247.144.127`; Nginx aaPanel `1.24.0`.
- Apex/API/dashboard `.com` sudah proxied Cloudflare tetapi belum memiliki vhost/server_name aaPanel/Nginx.
- HTTPS `.com` jatuh ke vhost pertama, `ai.digyta.net`, yang menuju 9router pada port `20128`. Sertifikat origin yang diberikan masih milik `ai.digyta.net`.
- DNS `www.berumrah.com` dan `www.berumrah.id` belum ada; sertifikat origin apex `.id` belum mencakup `www`.
- Frontend/dashboard Vite menyimpan URL `.id` dalam build; keduanya harus dibangun ulang.
- CORS backend belum mengizinkan `.com`. Refresh cookie host-only memakai `SameSite=Strict`, sehingga frontend `.com` perlu API `.com`.
- Pengaturan publik `seo.site_url` masih `https://berumrah.id`; canonical artikel dapat mempunyai override.
- `assets.berumrah.id` menuju `109.123.236.101`, bukan server aplikasi. HTTPS publik valid. Jangan mengubah DNS aset ke IP aplikasi.
- Proxy cache global diwarisi dari `/www/server/nginx/conf/proxy.conf`; matikan cache eksplisit pada proxy dinamis aplikasi terkait, bukan mengubah cache semua layanan.
- Tiga repository Git terpisah: `be-marketplace`, `fe-marketplace`, `dash-marketplace`. `.env` dan `dist` ignored; backup tidak bisa bergantung pada Git.

## 3. Preflight dan backup

1. Verifikasi status terbaru DNS/Nginx/sertifikat/PM2/Git dan akses layanan eksternal.
2. Buat backup berizin terbatas untuk `.env`, vhost/include terkait, sertifikat yang diganti, metadata aaPanel, build aktif, PM2, serta nilai SEO yang berubah. Backup database sesuai prosedur sebelum perubahan data.
3. Tidak menjalankan reset/clean/pull otomatis, migrasi skema, seeder, upgrade dependensi, atau pembersihan Redis global.
4. Simpan ringkasan perubahan non-rahasia ke repository ini. Jangan menyimpan token, password, private key, isi `.env`, URL presigned, atau data pribadi di repository/laporan.
5. Catat setiap perubahan DNS/aturan Cloudflare untuk rollback. Jadwalkan pergantian terkoordinasi; restart proses dapat menimbulkan gangguan singkat.

## 4. DNS, aaPanel, dan TLS

1. Verifikasi record apex/API/dashboard `.com` menunjuk origin `84.247.144.127`, proxied.
2. Tambahkan `CNAME www -> berumrah.com` di zona `.com` dan `CNAME www -> berumrah.id` di zona `.id`, proxied, TTL Auto.
3. Pertahankan DNS `.id`, MX/TXT/email, dan aset. AAAA Cloudflare publik bukan alamat IPv6 origin dan tidak perlu dihapus.
4. Daftarkan situs/domain melalui mekanisme aaPanel yang didukung; jangan mengedit SQLite panel secara manual.
5. Tambahkan vhost `.com` untuk frontend/API/dashboard. Gunakan `Host $host`, `X-Forwarded-Host $host`, `X-Forwarded-Proto $scheme`, serta header IP sesuai rantai proxy yang dipercaya. Backend sudah memakai `trust proxy=1`; jangan memperluas kepercayaan tanpa audit.
6. Terbitkan TLS origin dengan renewal untuk apex+www `.com`, API `.com`, dashboard `.com`, dan apex+www `.id`. Diutamakan Let's Encrypt yang terintegrasi aaPanel.
7. Pertahankan `/.well-known/acme-challenge/` sebelum dan setelah redirect. Jangan memuat konfigurasi HTTPS yang merujuk berkas sertifikat belum tersedia.
8. Verifikasi sertifikat origin sebelum mengaktifkan Cloudflare `Full (strict)`. Perubahan SSL tingkat zona `.id` harus memeriksa hostname lain agar tidak terganggu.
9. Audit Origin Rules/Redirect Rules/Workers/Page Rules/cache bila akses tersedia; jangan mengasumsikan DNS cukup untuk seluruh routing.

## 5. Konfigurasi aplikasi

Backend `.env` pada `/www/wwwroot/berumrah-marketplace/be-marketplace`:

```dotenv
FRONTEND_URL=https://berumrah.com
BACKEND_URL=https://api.berumrah.com
DASHBOARD_URL=https://dash.berumrah.com
CORS_ALLOWED_ORIGINS=https://berumrah.com,https://dash.berumrah.com,https://berumrah.id,https://dash.berumrah.id
```

Frontend `.env` pada `fe-marketplace`:

```dotenv
VITE_APP_URL=https://berumrah.com
VITE_API_URL=https://api.berumrah.com/api
```

Dashboard `.env` pada `dash-marketplace`:

```dotenv
VITE_APP_URL=https://dash.berumrah.com
VITE_FRONTEND_URL=https://berumrah.com
VITE_API_BASE_URL=https://api.berumrah.com/api
```

- Pertahankan database, port, kredensial, Redis prefix, dan `MINIO_ENDPOINT=assets.berumrah.id`.
- Jangan shell-source `.env`; aplikasi memakai dotenv/dotenv-expand.
- Pertahankan origin `.id` selama kompatibilitas dan `SameSite=Strict`; tidak memakai wildcard credentials.
- Audit URL utama hardcoded di footer/konten kreator, default slider/popup, dan SEO. Jangan mengganti identifier `/creator/berumrah.id`, label pembanding, email, atau tautan portal/aset secara global. Jangan rerun seeder.

## 6. Integrasi dan pekerjaan pemilik akun

### Google Cloud Console

- OAuth client yang saat ini dipakai: tambah `https://berumrah.com` pada **Authorized JavaScript origins**.
- Tambahkan `berumrah.com` pada **Authorized domains** dan perbarui homepage/privacy/terms sesuai halaman aktif.
- Origin `.id` tetap dipertahankan selama transisi.
- Implementasi yang diperiksa memakai callback JavaScript Google Identity Services. Redirect URI baru hanya diperlukan bila alur aktif lain memakainya.
- Tidak membuat client ID baru atau mengganti kredensial tanpa alasan.

### Cloudflare

- Memerlukan akses/token terbatas untuk dua zona. Jika tidak tersedia aman di server, pemilik akun menambah record `www` dan memeriksa SSL lewat dashboard.
- Jangan mengirim password/token melalui percakapan atau memasukkannya ke Git.

### Pembayaran

- Verifikasi whitelist/registrasi webhook Paylabs dan Doit serta URL kembali pelanggan. Environment baru menghasilkan callback Paylabs di `https://api.berumrah.com/api/webhook/paylabs` dan return URL `.com`.
- Endpoint `.id` tetap hidup untuk transaksi lama. Audit callback/return POST pada apex/dashboard sebelum redirect menyeluruh; pertahankan handler yang diperlukan.
- Jangan mengubah endpoint SIT/live atau membuat transaksi nyata/callback palsu ke produksi tanpa persetujuan terpisah.
- Periksa payment-return setelah login baru karena domain baru tidak membawa sesi browser lama.

### Aset eksternal

- Upload berjalan lewat backend, tetapi browser mempunyai direct presigned GET download dan gambar crossorigin.
- Verifikasi CORS GET dari `https://berumrah.com` dan `https://dash.berumrah.com`; tambahkan hanya jika kebijakan lama belum meliputnya. Pertahankan origin lama.
- Tidak membuka browser PUT tanpa kebutuhan dan tidak memindahkan bucket/DNS aset.

### Search Console

- Setelah situs siap: verifikasi properti `.com`, submit sitemap baru, Change of Address sesuai syarat Google, pantau indeks/crawl.
- Perbarui kampanye, profil sosial, analytics, dan tautan publik secara bertahap.

## 7. Build dan release kandidat

1. Node aktif `/www/server/nodejs/v22.19.0/bin/node` memenuhi manifest/Vite. Gunakan npm/lockfile saat ini tanpa upgrade.
2. Build frontend/dashboard memakai `npm run build` ke direktori staging terpisah; jangan menghapus/menimpa `dist` aktif saat pengguna mengakses `.id`.
3. Hindari `npm start` frontend/dashboard karena juga membangun dan menjalankan server lain. Backend tidak punya build.
4. Jangan memakai `be-marketplace/pullnbuild.sh` untuk perubahan domain terisolasi karena ikut pull/install/sinkronisasi data/cache dan pekerjaan lain.
5. Uji kandidat `.com` melalui HTTPS publik menggunakan proses loopback sementara bila perlu. `.id` tetap melayani build/API `.id` selama uji.
6. Periksa CSP/cache/service worker bila ada; simpan build/chunk lama untuk rollback dan tab lama.
7. Promosikan hanya setelah kedua build dan uji kandidat berhasil. Restart/reload proses yang ada, bukan membuat worker duplikat:
   - `berumrah-marketplace-backend`
   - `berumrah-marketplace-workers`
   - `berumrah-marketplace-frontend`
   - `berumrah-marketplace-dashboard`
8. Web processes cluster, worker fork. Pastikan env PM2 tidak menimpa nilai `.env` baru.

## 8. SEO, cache, dan pergantian

1. Backup dan ubah `seo.site_url` menjadi `https://berumrah.com` melalui API/admin service yang didukung.
2. Update satu pengaturan hanya menghapus cache `app_settings:*`; hapus juga **hanya** Redis key `berumrah-marketplace:seo:settings`. Cache in-memory frontend/dashboard ikut diperbarui saat pergantian proses.
3. Jangan memakai tombol Save/Clear Cache global dashboard: operasi itu dapat menghapus refresh token dan magic-link token. Jangan memakai FLUSHDB/FLUSHALL.
4. Audit canonical artikel internal, sitemap, robots, Open Graph, structured data, serta tautan dari data aktif. Tidak mengganti massal seluruh database.
5. Setelah `.com` benar-benar siap, koordinasikan promosi build dan redirect `.id` agar frontend `.id` tidak melayani build API `.com` lintas situs.
6. Gunakan `302` sementara untuk validasi, lalu `301` setelah lulus. Target redirect tetap dan `$request_uri` mempertahankan path/query. API `.id`/aset `.id` tidak di-redirect. HTTP API bila di-upgrade memakai same-host redirect yang mempertahankan method, misalnya `308`.
7. Purge hanya cache terkait. Jangan cache respons personal/autentikasi/webhook bersama.
8. Pengguna perlu login ulang pada `.com`; akun/pesanan/database tidak hilang. Cookie/localStorage/sessionStorage tidak berpindah antar-domain. Jangan memindahkan token lewat URL.

## 9. Default Nginx

- Audit default listener IPv4/IPv6 dan health check IP.
- Tolak hostname HTTP asing dan gunakan default TLS `ssl_reject_handshake on` pada Nginx 1.24.0.
- `ai.digyta.net` tetap berfungsi untuk hostname sah. Jangan mengubah aplikasi 9router.
- Uji sebelum reload:

```sh
/www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf
```

- Reload hanya bila valid, lalu uji ulang hostname sah lain pada server bersama.

## 10. Kriteria penerimaan

- HTTP/HTTPS empat variasi `.id`/`.com` dengan/tanpa www berakhir di `https://berumrah.com` tanpa loop, dengan path/query/encoding tetap.
- Sertifikat edge/origin sesuai setiap hostname, termasuk hostname redirect. `curl -k` bukan bukti TLS berhasil.
- API/dashboard `.com` tidak menampilkan 9router; origin asing tidak diberi CORS credentials.
- Login/logout/refresh/reload/role/Google bekerja memakai akun uji yang diizinkan. Google Login tetap pending sampai konfigurasi akun selesai.
- Upload/gambar/unduhan dokumen/presigned GET berfungsi di origin baru.
- Webhook lama tetap tersedia tanpa redirect; konfigurasi return/callback baru benar tanpa tes transaksi nyata tak disetujui.
- Canonical/sitemap `.com`, dashboard tetap noindex, noindex sementara situs utama tidak tertinggal.
- Hostname asing ditolak, hostname sah lain normal, tidak ada kenaikan error signifikan.

## 11. Rollback dan pemantauan

1. Jangan aktifkan `301` sebelum uji tuntas karena cache browser dapat menyulitkan rollback.
2. Jika gagal, pulihkan build/env/SEO/vhost dan hanya record/rule yang diubah; pulihkan `.id` tanpa redirect loop.
3. Uji Nginx sebelum reload. Verifikasi API/login/aset/webhook lama. Restore seluruh DB tidak diperlukan untuk konfigurasi domain saja.
4. Simpan backup/release lama, pantau log, pertahankan API `.id` selama dipakai transaksi/link/klien lama.
5. Pertahankan domain lama, sertifikat, dan redirect minimal satu tahun, idealnya selama masih dimiliki. Ranking/indeks dapat berfluktuasi sementara.
6. Catat hasil nyata, langkah yang tidak dapat dijalankan tanpa akses eksternal, dan pekerjaan pengguna pada laporan eksekusi. Jangan mengklaim pengujian login/pembayaran berhasil tanpa bukti.
