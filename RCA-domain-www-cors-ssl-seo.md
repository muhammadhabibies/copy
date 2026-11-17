# Root Cause Analysis (RCA)

## 1. Ringkasan

Terjadi beberapa masalah pada domain Hisar Global Indonesia dan Aisyiyah Travel:

1. `www.hisarglobalindonesia.com` menampilkan website Aisyiyah Travel.
2. `www.aisyiyahtravel.com` mengalami Cloudflare `526 Invalid SSL certificate`.
3. Website versi `www` terbuka, tetapi request API menghasilkan `500 Internal Server Error`.
4. Hasil SEO di Google masih menampilkan title dan description lama.

Masalah disebabkan oleh konfigurasi hostname `www` yang belum lengkap pada Nginx, SSL origin, dan CORS backend. SEO Google hanya membutuhkan crawl/index ulang setelah metadata publik diperbaiki.

> Catatan: `hisarglobal.com` berbeda dari `hisarglobalindonesia.com`. Domain `hisarglobal.com` mengarah ke HugeDomains, bukan ke server Hisar Global Indonesia.

---

## 2. Domain Terkait

### Hisar Global Indonesia

```text
hisarglobalindonesia.com
www.hisarglobalindonesia.com
api.hisarglobalindonesia.com
dash.hisarglobalindonesia.com
```

### Aisyiyah Travel

```text
aisyiyahtravel.com
www.aisyiyahtravel.com
api.aisyiyahtravel.com
dash.aisyiyahtravel.com
```

### Domain berbeda

```text
hisarglobal.com
www.hisarglobal.com
```

Kedua domain tersebut menuju HugeDomains dan bukan konfigurasi Hisar Global Indonesia.

---

## 3. Dampak

### Hisar Global Indonesia

- `www.hisarglobalindonesia.com` sebelumnya menampilkan Aisyiyah Travel.
- Request API dari origin `www` gagal dengan status `500`.
- Website versi `www` tidak berfungsi normal.

### Aisyiyah Travel

- `www.aisyiyahtravel.com` sebelumnya gagal dengan Cloudflare `526`.
- Setelah SSL diperbaiki, API masih gagal sampai CORS diperbaiki.

### SEO

- Data SEO dashboard sudah benar.
- Google masih dapat menampilkan title dan description lama sampai crawl ulang.

---

## 4. Temuan Teknis

### 4.1 Virtual host Hisar belum memuat `www`

File:

```text
/www/server/panel/vhost/nginx/node_fehisar.conf
```

Konfigurasi awal:

```nginx
server_name hisarglobalindonesia.com;
```

Karena `www.hisarglobalindonesia.com` tidak terdaftar, Nginx memilih virtual host lain/default. Request akhirnya menampilkan website Aisyiyah.

### 4.2 Virtual host Aisyiyah belum memuat `www`

File:

```text
/www/server/panel/vhost/nginx/aisyiyahtravel.com.conf
```

Konfigurasi awal:

```nginx
server_name aisyiyahtravel.com;
```

### 4.3 Sertifikat SSL origin Aisyiyah tidak memuat `www`

Sertifikat awal hanya memiliki SAN:

```text
DNS:aisyiyahtravel.com
```

Cloudflare tidak dapat memvalidasi hostname `www.aisyiyahtravel.com` ke origin. Hasilnya:

```text
526 Invalid SSL certificate
```

### 4.4 CORS backend tidak mengizinkan origin `www`

Kode backend menggunakan daftar `CORS_ALLOWED_ORIGINS` dan menolak origin yang tidak terdaftar:

```javascript
return callback(new Error('Not allowed by CORS'));
```

Error berada pada:

```text
/www/wwwroot/hisar/backend/server.js:45
/www/wwwroot/aisyiyahtravel/backend/server.js:45
```

Browser mengirim:

```http
Origin: https://www.hisarglobalindonesia.com
Origin: https://www.aisyiyahtravel.com
```

Backend awal hanya mengizinkan domain tanpa `www` dan dashboard.

### 4.5 PM2 masih menyimpan environment lama

Setelah file `.env` diubah, PM2 masih membawa nilai environment lama. Restart biasa belum cukup karena environment proses lama memiliki prioritas.

Environment PM2 kemudian diperbarui langsung dengan `--update-env` dan disimpan menggunakan `pm2 save`.

### 4.6 SEO Google masih memakai index lama

HTML publik sudah mengirim metadata SEO terbaru. Google tetap dapat menampilkan data lama sampai crawl berikutnya. Google juga dapat menulis ulang title atau description berdasarkan query pencarian.

---

## 5. Perbaikan yang Dilakukan

### 5.1 Perbaikan Nginx Hisar

File:

```text
/www/server/panel/vhost/nginx/node_fehisar.conf
```

Perubahan:

```nginx
server_name hisarglobalindonesia.com www.hisarglobalindonesia.com;
```

Proxy tetap mengarah ke frontend Hisar:

```nginx
proxy_pass http://127.0.0.1:2001;
```

### 5.2 Perbaikan Nginx Aisyiyah

File:

```text
/www/server/panel/vhost/nginx/aisyiyahtravel.com.conf
```

Perubahan:

```nginx
server_name aisyiyahtravel.com www.aisyiyahtravel.com;
```

Proxy tetap mengarah ke frontend Aisyiyah:

```nginx
proxy_pass http://localhost:6021;
```

### 5.3 Penerbitan SSL baru Aisyiyah

File sertifikat aktif:

```text
/www/server/panel/vhost/cert/aisyiyahtravel.com/fullchain.pem
/www/server/panel/vhost/cert/aisyiyahtravel.com/privkey.pem
```

SAN sertifikat baru:

```text
DNS:aisyiyahtravel.com
DNS:www.aisyiyahtravel.com
```

Masa berlaku saat penerbitan:

```text
17 November 2026 – 15 Februari 2027
```

### 5.4 Perbaikan CORS Hisar

File:

```text
/www/wwwroot/hisar/backend/.env
```

Nilai akhir:

```env
CORS_ALLOWED_ORIGINS=${FRONTEND_URL},https://www.hisarglobalindonesia.com,${DASHBOARD_URL}
```

### 5.5 Perbaikan CORS Aisyiyah

File:

```text
/www/wwwroot/aisyiyahtravel/backend/.env
```

Nilai akhir:

```env
CORS_ALLOWED_ORIGINS=${FRONTEND_URL},https://www.aisyiyahtravel.com,${DASHBOARD_URL}
```

### 5.6 Pembaruan environment PM2

Process yang direstart:

```text
hisarglobal-backend
aisyiyahtravel-backend
```

Environment baru diterapkan menggunakan:

```bash
CORS_ALLOWED_ORIGINS='https://hisarglobalindonesia.com,https://www.hisarglobalindonesia.com,https://dash.hisarglobalindonesia.com' \
pm2 restart hisarglobal-backend --update-env

CORS_ALLOWED_ORIGINS='https://aisyiyahtravel.com,https://www.aisyiyahtravel.com,https://dash.aisyiyahtravel.com' \
pm2 restart aisyiyahtravel-backend --update-env

pm2 save
```

---

## 6. Validasi Setelah Perbaikan

### 6.1 Website

```text
https://hisarglobalindonesia.com/       → HTTP 200
https://www.hisarglobalindonesia.com/   → HTTP 200
https://aisyiyahtravel.com/             → HTTP 200
https://www.aisyiyahtravel.com/         → HTTP 200
```

### 6.2 API

Hisar:

```text
https://api.hisarglobalindonesia.com/api/app-settings/public → HTTP 200
```

Aisyiyah:

```text
https://api.aisyiyahtravel.com/api/app-settings/public → HTTP 200
```

### 6.3 CORS

Hisar:

```http
Access-Control-Allow-Origin: https://hisarglobalindonesia.com
Access-Control-Allow-Origin: https://www.hisarglobalindonesia.com
```

Aisyiyah:

```http
Access-Control-Allow-Origin: https://aisyiyahtravel.com
Access-Control-Allow-Origin: https://www.aisyiyahtravel.com
```

### 6.4 Nginx

```text
nginx: configuration file syntax is ok
nginx: configuration file test is successful
```

### 6.5 SEO HTML

HTML publik kedua website sudah memuat:

```html
<title>...</title>
<meta name="description" content="...">
<meta property="og:title" content="...">
<meta property="og:description" content="...">
<link rel="canonical" href="https://domain-tanpa-www">
```

Sitemap tersedia:

```text
https://hisarglobalindonesia.com/sitemap.xml
https://aisyiyahtravel.com/sitemap.xml
```

---

## 7. Backup

Backup konfigurasi Nginx:

```text
/www/server/panel/vhost/nginx/node_fehisar.conf.bak.20261117-110615
/www/server/panel/vhost/nginx/aisyiyahtravel.com.conf.bak.20261117-110909
```

Backup environment:

```text
/www/wwwroot/hisar/backend/.env.bak.20261117-113312
/www/wwwroot/aisyiyahtravel/backend/.env.bak.20261117-113312
```

---

## 8. Status Akhir

| Komponen | Status |
|---|---|
| Nginx virtual host Hisar | Selesai |
| Nginx virtual host Aisyiyah | Selesai |
| SSL `www.aisyiyahtravel.com` | Selesai |
| Website Hisar tanpa `www` | Normal |
| Website Hisar dengan `www` | Normal |
| Website Aisyiyah tanpa `www` | Normal |
| Website Aisyiyah dengan `www` | Normal |
| Backend API Hisar | Normal |
| Backend API Aisyiyah | Normal |
| CORS domain `www` | Normal |
| SEO metadata HTML | Normal |
| Google Search result | Menunggu crawl/index ulang |

---

## 9. Rekomendasi Pencegahan

1. Daftarkan `domain.com` dan `www.domain.com` secara konsisten pada:
   - Nginx `server_name`
   - Sertifikat SSL
   - CORS backend
   - `FRONTEND_URL`
   - Sitemap
   - Canonical URL
   - Google Search Console

2. Tetapkan domain tanpa `www` sebagai URL canonical:

   ```text
   https://hisarglobalindonesia.com
   https://aisyiyahtravel.com
   ```

3. Setelah mengubah `.env`, selalu gunakan:

   ```bash
   pm2 restart <process> --update-env
   pm2 save
   ```

4. Tes CORS setelah deployment:

   ```bash
   curl -ksS -D- \
   -H 'Origin: https://www.hisarglobalindonesia.com' \
   https://api.hisarglobalindonesia.com/api/app-settings/public
   ```

5. Setelah perubahan SEO:
   - Kirim sitemap di Google Search Console.
   - Jalankan URL Inspection.
   - Klik `Request Indexing`.
   - Tunggu crawl ulang Google.
