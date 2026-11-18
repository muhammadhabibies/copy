# Panduan Setup Core Travel

Panduan ini mencegah masalah domain `www`, fallback virtual host, SSL Cloudflare `526`, CORS `500`, dan SEO pada aplikasi travel berbasis frontend Node.js, backend Node.js, Nginx, Cloudflare, dan PM2.

## 1. Prinsip Dasar

Setiap aplikasi travel harus didaftarkan konsisten pada semua lapisan:

| Lapisan | Domain utama | Domain `www` |
|---|---|---|
| DNS Cloudflare | `travel.example.com` | `www.travel.example.com` |
| Nginx frontend | `server_name` | `server_name` |
| SSL origin | SAN | SAN |
| Frontend | URL utama/API | Origin browser |
| Backend CORS | Origin utama | Origin `www` |
| PM2 environment | Nilai aktif | Nilai aktif |
| Canonical SEO | Domain utama | Domain utama |
| Sitemap | Domain utama | Domain utama |

Jangan menganggap domain `www` otomatis mengikuti domain tanpa `www`. Setiap hostname harus dikonfigurasi eksplisit.

---

## 2. Variabel Setup

Tentukan nilai berikut sebelum mulai:

```text
APP_NAME=nama-aplikasi
DOMAIN=travel.example.com
WWW_DOMAIN=www.travel.example.com
API_DOMAIN=api.travel.example.com
DASHBOARD_DOMAIN=dash.travel.example.com
FRONTEND_PORT=6011
BACKEND_PORT=6010
FRONTEND_PATH=/www/wwwroot/nama-aplikasi/frontend
BACKEND_PATH=/www/wwwroot/nama-aplikasi/backend
```

Contoh nyata:

```text
APP_NAME=mudahkebaitullah
DOMAIN=mudahkebaitullah.com
WWW_DOMAIN=www.mudahkebaitullah.com
API_DOMAIN=api.mudahkebaitullah.com
DASHBOARD_DOMAIN=dash.mudahkebaitullah.com
```

Gunakan nama domain lengkap. Jangan mengganti `travel.example.com` dengan domain lain yang mirip.

---

## 3. Checklist DNS Cloudflare

Buat record berikut pada zone domain:

| Type | Name | Target | Proxy |
|---|---|---|---|
| A | `@` | IP origin server | Proxied |
| A atau CNAME | `www` | Target domain utama/origin | Proxied |
| A atau CNAME | `api` | Target backend/API | Proxied |
| A atau CNAME | `dash` | Target dashboard | Proxied |

Rekomendasi record `www`:

```text
Type: CNAME
Name: www
Target: travel.example.com
Proxy status: Proxied
```

Atau gunakan record A yang sama dengan domain utama.

Validasi:

```bash
dig +short A travel.example.com
dig +short A www.travel.example.com
dig +short A api.travel.example.com
dig +short A dash.travel.example.com
```

Semua hostname publik harus resolve sebelum menerbitkan SSL.

Jika `www` tidak menghasilkan output, jangan lanjut ke pengujian browser. Perbaiki DNS dahulu.

---

## 4. Checklist Nginx Frontend

File frontend biasanya berada di:

```text
/www/server/panel/vhost/nginx/travel.example.com.conf
```

Pastikan `server_name` memuat dua hostname:

```nginx
server_name travel.example.com www.travel.example.com;
```

Pastikan proxy mengarah ke port frontend aplikasi sendiri:

```nginx
location / {
    proxy_pass http://127.0.0.1:FRONTEND_PORT;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

Jangan memakai port aplikasi travel lain.

Cari konfigurasi yang salah:

```bash
sudo grep -RInE 'server_name|proxy_pass' \
/www/server/panel/vhost/nginx/
```

Pastikan tidak ada konfigurasi lain yang mengambil hostname aplikasi.

Tes konfigurasi:

```bash
sudo nginx -t
```

Terapkan perubahan:

```bash
sudo systemctl reload nginx
```

Gunakan `reload`, bukan restart, jika tidak diperlukan downtime.

---

## 5. Checklist Nginx API

File API biasanya berada di:

```text
/www/server/panel/vhost/nginx/api.travel.example.com.conf
```

Pastikan:

```nginx
server_name api.travel.example.com;
```

dan:

```nginx
proxy_pass http://127.0.0.1:BACKEND_PORT;
```

Port API harus sama dengan port backend PM2.

Tes langsung ke backend:

```bash
curl -sS http://127.0.0.1:BACKEND_PORT/health
```

Tes lewat domain API:

```bash
curl -ksS https://api.travel.example.com/health
```

Kedua request harus menghasilkan status sehat.

---

## 6. Checklist SSL Origin

Sertifikat origin frontend harus mencakup dua hostname:

```text
travel.example.com
www.travel.example.com
```

Sertifikat API harus mencakup:

```text
api.travel.example.com
```

Periksa sertifikat:

```bash
sudo openssl x509 \
  -in /www/server/panel/vhost/cert/travel.example.com/fullchain.pem \
  -noout -subject -issuer -dates -ext subjectAltName
```

Output harus memuat:

```text
DNS:travel.example.com
DNS:www.travel.example.com
```

Jika `www` belum ada, terbitkan sertifikat baru setelah DNS aktif.

Di aaPanel:

```text
Website → travel.example.com → SSL → Let's Encrypt
```

Pilih hostname:

```text
travel.example.com
www.travel.example.com
```

Setelah pemasangan:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Cloudflare SSL mode yang disarankan:

```text
Full (strict)
```

Jangan memakai `Flexible` sebagai solusi permanen.

---

## 7. Checklist Backend `.env`

File:

```text
/www/wwwroot/nama-aplikasi/backend/.env
```

Isi minimal:

```env
FRONTEND_URL=https://travel.example.com
BACKEND_URL=https://api.travel.example.com
DASHBOARD_URL=https://dash.travel.example.com
PORT=BACKEND_PORT
NODE_ENV=production
CORS_ALLOWED_ORIGINS=${FRONTEND_URL},https://www.travel.example.com,${DASHBOARD_URL}
```

Pastikan origin ditulis lengkap dengan:

- `https://`
- hostname tepat
- tanpa slash terakhir

Benar:

```text
https://www.travel.example.com
```

Salah:

```text
www.travel.example.com/
https://www.travel.example.com/
http://www.travel.example.com
```

Backend CORS biasanya menggunakan pencocokan string persis.

Kode CORS umum:

```javascript
const allowedOrigins = (process.env.CORS_ALLOWED_ORIGINS || '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

app.use(cors({
  origin: (origin, callback) => {
    if (!origin || allowedOrigins.includes(origin)) {
      return callback(null, true);
    }
    return callback(new Error('Not allowed by CORS'));
  },
  credentials: true
}));
```

Jangan membuka CORS dengan wildcard `*` jika aplikasi memakai credentials/cookie.

---

## 8. Restart PM2 dengan Benar

Edit `.env` saja tidak cukup jika PM2 masih menyimpan environment lama.

Backup dahulu:

```bash
cp -a /www/wwwroot/nama-aplikasi/backend/.env \
/www/wwwroot/nama-aplikasi/backend/.env.bak.$(date +%Y%m%d-%H%M%S)
```

Restart dengan `--update-env`:

```bash
pm2 restart nama-aplikasi-backend --update-env
pm2 save
```

Jika environment PM2 tetap lama, berikan nilai secara eksplisit:

```bash
CORS_ALLOWED_ORIGINS='https://travel.example.com,https://www.travel.example.com,https://dash.travel.example.com' \
pm2 restart nama-aplikasi-backend --update-env

pm2 save
```

Periksa environment tersimpan:

```bash
pm2 jlist | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item["name"] == "nama-aplikasi-backend":
        print(item.get("pm2_env", {}).get("env", {}).get("CORS_ALLOWED_ORIGINS"))
'
```

Periksa status:

```bash
pm2 status
pm2 logs nama-aplikasi-backend --lines 80 --nostream
```

Jangan restart semua aplikasi jika hanya satu aplikasi yang berubah.

---

## 9. Checklist Frontend API

Frontend harus memakai API domain aplikasi sendiri:

```text
https://api.travel.example.com
```

Jangan hardcode API domain aplikasi lain.

Cari referensi API:

```bash
grep -RInE 'api\.|API_URL|BACKEND_URL|VITE_.*API|NEXT_PUBLIC_.*API' \
/www/wwwroot/nama-aplikasi/frontend \
/www/wwwroot/nama-aplikasi/.env* 2>/dev/null
```

Setelah mengubah environment frontend, rebuild/restart frontend sesuai metode deployment aplikasi.

Validasi dari HTML:

```bash
curl -ksS https://www.travel.example.com/ | \
grep -oE 'https?://[^" ]+' | grep -i api | head
```

---

## 10. Urutan Deployment yang Aman

Gunakan urutan berikut:

1. Buat DNS domain utama, `www`, `api`, dan `dash`.
2. Tunggu sampai semua hostname resolve.
3. Buat website/backend/frontend di server.
4. Buat Nginx `server_name` dengan domain utama dan `www`.
5. Pasang SSL origin dengan SAN lengkap.
6. Set `.env` backend dan masukkan origin `www` ke CORS.
7. Set frontend API URL ke API aplikasi sendiri.
8. Jalankan `nginx -t`.
9. Reload Nginx.
10. Restart backend dengan `pm2 restart --update-env`.
11. Jalankan `pm2 save`.
12. Tes domain utama dan `www`.
13. Tes API dengan dua origin.
14. Tes SEO HTML, canonical, robots, dan sitemap.
15. Daftarkan domain utama di Google Search Console.

Jangan menunggu sampai browser menemukan error untuk memeriksa hostname.

---

## 11. Checklist Validasi Lengkap

Ganti nilai placeholder terlebih dahulu:

```bash
DOMAIN=travel.example.com
WWW_DOMAIN=www.travel.example.com
API_DOMAIN=api.travel.example.com
```

### DNS

```bash
dig +short A "$DOMAIN"
dig +short A "$WWW_DOMAIN"
dig +short A "$API_DOMAIN"
```

### Website

```bash
curl -ksS -I "https://$DOMAIN/"
curl -ksS -I "https://$WWW_DOMAIN/"
```

Keduanya harus menghasilkan `HTTP 200` atau redirect yang memang direncanakan.

### Konten website

```bash
curl -ksS "https://$DOMAIN/" | grep -oE '<title[^>]*>[^<]*' | head -1
curl -ksS "https://$WWW_DOMAIN/" | grep -oE '<title[^>]*>[^<]*' | head -1
```

### API tanpa `www`

```bash
curl -ksS -D- \
  -H "Origin: https://$DOMAIN" \
  "https://$API_DOMAIN/api/app-settings/public"
```

### API dengan `www`

```bash
curl -ksS -D- \
  -H "Origin: https://$WWW_DOMAIN" \
  "https://$API_DOMAIN/api/app-settings/public"
```

Response yang diharapkan:

```text
HTTP 200
Access-Control-Allow-Origin: https://www.travel.example.com
Access-Control-Allow-Credentials: true
```

### SSL origin

```bash
sudo openssl x509 \
  -in /www/server/panel/vhost/cert/$DOMAIN/fullchain.pem \
  -noout -dates -ext subjectAltName
```

### Nginx

```bash
sudo nginx -t
sudo nginx -T 2>/dev/null | grep -n -A20 -B5 "$WWW_DOMAIN"
```

### PM2

```bash
pm2 status
pm2 logs nama-aplikasi-backend --lines 80 --nostream
```

Tidak boleh ada error:

```text
Not allowed by CORS
```

---

## 12. Canonical SEO

Tetapkan domain tanpa `www` sebagai canonical:

```html
<link rel="canonical" href="https://travel.example.com">
```

Frontend versi `www` boleh menampilkan konten yang sama, tetapi canonical tetap ke domain utama.

Sediakan:

```text
https://travel.example.com/robots.txt
https://travel.example.com/sitemap.xml
```

Pastikan sitemap menggunakan domain utama, bukan hostname acak atau domain aplikasi lain.

Validasi:

```bash
curl -ksS https://travel.example.com/robots.txt
curl -ksS https://travel.example.com/sitemap.xml | head
```

Setelah deployment:

1. Submit sitemap di Google Search Console.
2. Jalankan URL Inspection.
3. Klik `Request Indexing`.
4. Tunggu Google crawl ulang.

Google dapat menulis ulang title dan description walau metadata HTML sudah benar.

---

## 13. Rekomendasi Redirect Canonical

Jika `www` hanya dipakai sebagai alias, arahkan ke domain utama:

```nginx
server {
    listen 443 ssl;
    server_name www.travel.example.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;

    return 301 https://travel.example.com$request_uri;
}
```

Namun sertifikat tetap harus mencakup `www` karena TLS terjadi sebelum redirect HTTP dapat berjalan.

Jika aplikasi membutuhkan `www` tetap aktif, gunakan satu virtual host seperti:

```nginx
server_name travel.example.com www.travel.example.com;
```

Pilih satu strategi. Jangan mencampur redirect `www` dan konten aktif tanpa alasan.

---

## 14. Kesalahan yang Harus Dihindari

### Salah 1 — Mengedit config aplikasi lain

Jangan mengedit file seperti:

```text
dev-fe.berumrah.id.conf
```

kecuali domain memang milik aplikasi tersebut.

### Salah 2 — Hanya menambah `www` di Nginx

Nginx bisa benar, tetapi API tetap error jika CORS belum memuat `www`.

### Salah 3 — Hanya mengubah `.env`

PM2 mungkin masih memakai environment lama. Selalu gunakan:

```bash
pm2 restart nama-aplikasi-backend --update-env
pm2 save
```

### Salah 4 — Menghapus cache sebagai solusi utama

Cache browser atau Cloudflare bukan solusi untuk:

- virtual host salah;
- sertifikat origin salah;
- CORS tidak cocok;
- DNS belum ada.

### Salah 5 — Menerbitkan SSL sebelum DNS aktif

HTTP-01 Let’s Encrypt memerlukan hostname dapat diakses publik.

### Salah 6 — Menggunakan wildcard CORS

Jangan mengganti CORS menjadi:

```javascript
origin: '*'
```

jika aplikasi menggunakan cookie atau credentials.

### Salah 7 — Memakai domain mirip

Pastikan:

```text
travel.example.com
```

tidak tertukar dengan:

```text
travel-example.com
travel.example.id
www.travel.example.com
```

---

## 15. Template Checklist Deployment

Salin checklist ini untuk setiap aplikasi baru:

```text
[ ] Domain utama sudah ditentukan
[ ] Domain www sudah ditentukan
[ ] API domain sudah ditentukan
[ ] Dashboard domain sudah ditentukan
[ ] DNS domain utama resolve
[ ] DNS www resolve
[ ] DNS API resolve
[ ] DNS dashboard resolve
[ ] Nginx server_name memuat domain utama dan www
[ ] Nginx proxy_pass menuju port frontend yang benar
[ ] API Nginx proxy_pass menuju port backend yang benar
[ ] Sertifikat origin memuat domain utama dan www
[ ] FRONTEND_URL benar
[ ] BACKEND_URL benar
[ ] DASHBOARD_URL benar
[ ] CORS_ALLOWED_ORIGINS memuat domain utama
[ ] CORS_ALLOWED_ORIGINS memuat www
[ ] PM2 backend direstart dengan --update-env
[ ] pm2 save dijalankan
[ ] nginx -t sukses
[ ] Nginx reload sukses
[ ] Website tanpa www HTTP 200
[ ] Website dengan www HTTP 200
[ ] API tanpa www HTTP 200
[ ] API dengan www HTTP 200
[ ] Header Access-Control-Allow-Origin benar
[ ] Tidak ada error Not allowed by CORS
[ ] robots.txt tersedia
[ ] sitemap.xml tersedia
[ ] canonical memakai domain utama
[ ] URL utama dikirim ke Google Search Console
```

---

## 16. Struktur Dokumentasi Per Aplikasi

Simpan data non-rahasia per aplikasi:

```text
/root/copy/apps/nama-aplikasi.md
```

Isi:

```markdown
# Nama Aplikasi

## Domains

- Main: https://travel.example.com
- WWW: https://www.travel.example.com
- API: https://api.travel.example.com
- Dashboard: https://dash.travel.example.com

## Ports

- Frontend: 6011
- Backend: 6010

## Nginx

- Frontend config: /www/server/panel/vhost/nginx/travel.example.com.conf
- API config: /www/server/panel/vhost/nginx/api.travel.example.com.conf

## PM2

- Backend process: nama-aplikasi-backend
- Frontend process: nama-aplikasi-frontend

## Validation date

YYYY-MM-DD
```

Jangan menyimpan password DB, token API, private key, JWT secret, atau credential Cloudflare di dokumen ini.

---

## 17. Target Kondisi Akhir

Setup dianggap selesai jika semua kondisi berikut benar:

```text
https://travel.example.com/       → aplikasi travel yang benar
https://www.travel.example.com/   → aplikasi sama atau redirect canonical
https://api.travel.example.com/   → backend aplikasi yang benar
```

Dan:

```text
DNS resolve
SSL valid
Nginx server_name lengkap
proxy_pass benar
CORS origin lengkap
PM2 environment terbaru
API HTTP 200
SEO canonical benar
sitemap aktif
```

Dengan checklist ini, hostname `www` tidak lagi jatuh ke virtual host aplikasi lain dan tidak menghasilkan error CORS setelah deployment.
