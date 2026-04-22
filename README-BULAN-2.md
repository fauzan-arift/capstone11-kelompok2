# Implementasi Strategi Backup & Replikasi - Dokumentasi Bulan 2

Capstone 11 (Kelompok 2) - Capstone Project  
Program Studi Ilmu Komputer IPB University 2026

Dokumen ini berisi dokumentasi sementara untuk implementasi replikasi data PostgreSQL antara Primary Database di VM-PRIMARY-BOGOR dan Replica Database di VM-REPLICA-DRC.

## Deskripsi

Bulan 2 berfokus pada implementasi dua sistem utama di atas infrastruktur yang sudah dibangun pada Bulan 1:

1. **Streaming Replication** — sinkronisasi data real-time dari Primary ke Replica menggunakan mekanisme WAL (Write-Ahead Log) PostgreSQL.
2. **Backup Otomatis** — skrip backup terjadwal dengan tiga strategi (Full, Incremental, Differential), enkripsi AES-256, dan pengiriman terenkripsi ke Replica via SSH.

## Arsitektur

```
VM Primary (192.168.218.10)              VM Replica (192.168.218.11)
┌─────────────────────────┐              ┌─────────────────────────┐
│  Docker Container       │              │  Docker Container       │
│  pg-primary (R/W)       │──WAL Stream─▶│  pg-replica (Read-only) │
│                         │              │                         │
│  db_kependudukan        │              │  db_kependudukan        │
│  db_full                │              │  db_full                │
│  db_inc                 │              │  db_inc                 │
│  db_diff                │              │  db_diff                │
└─────────────────────────┘              └─────────────────────────┘
         │                                         │
         │  backup.sh (cron)                       │
         ▼                                         ▼
  /backup/full/                     ~/backup/received/full/
  /backup/incremental/              ~/backup/received/incremental/
  /backup/differential/             ~/backup/received/differential/
         │                                         ▲
         └──── rsync + SSH (TLS encrypted) ────────┘
```

| Komponen | IP Address | Peran |
| :--- | :--- | :--- |
| VM-PRIMARY-BOGOR | `192.168.218.10` | Primary database, menerima transaksi tulis |
| VM-REPLICA-DRC | `192.168.218.11` | Replica database, menerima streaming WAL dan bersifat read-only |

Kedua VM terhubung melalui jaringan Host-only VMware (`VMnet1`).


## Bagian 1 - Konfigurasi di Primary

### 1.1 Aktifkan Parameter Replikasi

Masuk ke container `pg-primary`:

```bash
docker exec -it pg-primary bash
```

Tambahkan konfigurasi berikut ke file `postgresql.conf`:

```bash
echo "wal_level = replica" >> /var/lib/postgresql/data/postgresql.conf
echo "max_wal_senders = 10" >> /var/lib/postgresql/data/postgresql.conf
echo "wal_keep_size = 64" >> /var/lib/postgresql/data/postgresql.conf
echo "hot_standby = on" >> /var/lib/postgresql/data/postgresql.conf
exit
```

Penjelasan singkat:
- `wal_level = replica` mencatat perubahan data yang dibutuhkan untuk replikasi.
- `max_wal_senders = 10` membatasi jumlah koneksi replikasi yang aktif.
- `wal_keep_size = 64` menyimpan WAL agar replica tidak tertinggal.
- `hot_standby = on` mengizinkan replica melayani query read-only saat standby.

### 1.2 Buat User Replikasi

```bash
docker exec -it pg-primary psql -U admin -d postgres
```

```sql
CREATE USER repl_user WITH REPLICATION PASSWORD 'repl_pass';
\q
```

### 1.3 Izinkan Akses dari Replica

Tambahkan rule berikut ke `pg_hba.conf`:

```bash
docker exec -it pg-primary bash
echo "host replication repl_user 192.168.218.11/32 md5" >> /var/lib/postgresql/data/pg_hba.conf
exit
```

### 1.4 Restart Container

```bash
docker restart pg-primary
```

## Bagian 2 - Konfigurasi di Replica

### 2.1 Bersihkan Data Lama

```bash
docker stop pg-replica 2>/dev/null
docker rm pg-replica 2>/dev/null
sudo rm -rf /opt/postgres-data
sudo mkdir -p /opt/postgres-data
sudo chmod 777 /opt/postgres-data
```

### 2.2 Ambil Base Backup dari Primary

```bash
docker run --rm \
  -v /opt/postgres-data:/var/lib/postgresql/data \
  -e PGPASSWORD=repl_pass \
  postgres:15 \
  pg_basebackup -h 192.168.218.10 -U repl_user -D /var/lib/postgresql/data -P -R -X stream -v
```

Parameter penting:
- `-R` membuat file `standby.signal` dan `primary_conninfo` otomatis.
- `-X stream` memastikan WAL ikut tersalin saat backup.

### 2.3 Jalankan Container Replica

Buat file `~/pg-replica/docker-compose.yml`:

```yaml
version: '3.8'

services:
  pg-replica:
    image: postgres:15
    container_name: pg-replica
    restart: unless-stopped
    ports:
      - "5432:5432"
    volumes:
      - /opt/postgres-data:/var/lib/postgresql/data
    env_file:
      - .env
```

Buat file `.env`:

```env
POSTGRES_PASSWORD=admin123
```

Lalu jalankan:

```bash
docker compose up -d
```

## Bagian 3 - Verifikasi Replikasi

### 3.1 Cek Status Streaming

Masuk ke replica:

```bash
docker exec -it pg-replica psql -U admin -d postgres
```

Jalankan:

```sql
SELECT * FROM pg_stat_wal_receiver;
```

Kolom `status` harus bernilai `streaming`.

### 3.2 Uji Sinkronisasi Data

Di primary:

```sql
CREATE TABLE test_repl (id SERIAL PRIMARY KEY, pesan VARCHAR(50));
INSERT INTO test_repl (pesan) VALUES ('Replikasi berhasil!');
```

Di replica:

```sql
SELECT * FROM test_repl;
```

Data harus muncul dalam beberapa detik.

### 3.3 Verifikasi Database

```sql
\l
```

Pastikan database utama seperti `db_kependudukan`, `db_full`, `db_inc`, dan `db_diff` muncul di daftar.

## Bagian 4 - Backup Otomatis

### Strategi Backup

| Tipe | Frekuensi | Isi | Ukuran Relatif |
|---|---|---|---|
| Full | Setiap Minggu 01:00 | Seluruh database | Besar |
| Incremental | Setiap Sen-Sab 02:00 | Perubahan sejak backup sebelumnya | Kecil |
| Differential | Setiap Sen-Sab 03:00 | Perubahan sejak full terakhir | Sedang |

### Keamanan

Sistem backup menggunakan **dua lapis enkripsi**:

| Lapis | Metode | Fungsi |
|---|---|---|
| File backup | AES-256-CBC (OpenSSL) | Enkripsi isi file — at-rest |
| Jalur transfer | SSH/TLS (rsync+ssh) | Enkripsi jalur pengiriman — in-transit |

File `.sql` plaintext **tidak pernah tersimpan permanen** — langsung dihapus setelah dienkripsi menjadi `.sql.enc`.

### Struktur File

```text
~/pg-setup/
├── backup.sh           ← skrip utama backup
├── .env-backup         ← konfigurasi & passphrase (jangan di-commit ke Git)
├── setup-ssh-aes.sh    ← setup SSH key & test AES (jalankan sekali)
└── setup-cron.sh       ← setup jadwal otomatis (jalankan sekali)

/backup/
├── full/
│   ├── full_db_kependudukan_YYYYMMDD_HHMMSS.sql.enc
│   ├── full_db_kependudukan_YYYYMMDD_HHMMSS.sql.enc.md5
│   └── ... (4 database)
├── incremental/
│   └── incremental_YYYYMMDD_HHMMSS.tar.gz.enc
├── differential/
│   └── diff_db_kependudukan_since_YYYYMMDD_YYYYMMDD_HHMMSS.sql.enc
└── logs/
  └── backup_YYYYMMDD_HHMMSS.log
```

### Setup (Jalankan Sekali)

**Prasyarat:**

```bash
sudo apt install -y openssl rsync openssh-client
```

**1. Setup SSH key dan test enkripsi:**

```bash
chmod +x setup-ssh-aes.sh backup.sh setup-cron.sh
./setup-ssh-aes.sh
```

Skrip ini akan:
- Generate SSH key di `~/.ssh/backup_key`
- Kirim public key ke Replica (diminta password sekali)
- Buat direktori `/backup` di Primary
- Buat direktori `~/backup/received` di Replica
- Test enkripsi/dekripsi AES-256
- Test bahwa passphrase salah ditolak

**2. Isi `.env-backup`:**

```env
PG_USER=admin
PG_PASSWORD=admin123
CONTAINER=pg-primary
REPLICA_USER=capstone11
REPLICA_IP=192.168.218.11
REPLICA_BACKUP_DIR=/home/capstone11/backup/received
SSH_KEY=$HOME/.ssh/backup_key
BACKUP_AES_PASSPHRASE=C4pst0ne11_AES_S3cur3!
BACKUP_DIR=/backup
```

> **Penting:** Jangan commit `.env-backup` ke Git. Tambahkan ke `.gitignore`.

**3. Test backup manual:**

```bash
./backup.sh full
```

**4. Aktifkan jadwal otomatis:**

```bash
./setup-cron.sh
crontab -l
```

### Penggunaan Manual

```bash
./backup.sh full          # Full backup semua database
./backup.sh incremental   # Incremental backup
./backup.sh differential  # Differential backup
```

### Verifikasi Backup

**Cek file di Primary:**

```bash
ls -lh /backup/full/
```

**Cek integritas checksum:**

```bash
cd /backup/full/
md5sum -c *.enc.md5
```

**Test dekripsi:**

```bash
source ~/pg-setup/.env-backup

openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
  -in /backup/full/full_db_kependudukan_*.sql.enc \
  -out /tmp/test_decrypt.sql \
  -pass pass:"$BACKUP_AES_PASSPHRASE"

head -20 /tmp/test_decrypt.sql
rm /tmp/test_decrypt.sql
```

**Pantau log:**

```bash
tail -f /backup/logs/backup_*.log
```

---

## Bagian 5 - Hasil Verifikasi

### Replikasi

| Pengujian | Hasil |
|---|---|
| Status WAL streaming | `streaming` |
| Sinkronisasi data real-time | Berhasil — data di Primary langsung muncul di Replica |
| Jumlah database tersinkronisasi | 4 database |

### Backup

| Pengujian | Hasil |
|---|---|
| Full backup 4 database | Berhasil |
| Enkripsi AES-256 | Berhasil |
| Transfer via SSH ke Replica | Berhasil |
| Test passphrase salah | Ditolak  |

---