# Replikasi Data PostgreSQL - Dokumentasi Bulan 2

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


## 1. Konfigurasi di Primary

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

## 2. Konfigurasi di Replica

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

## 3. Verifikasi Replikasi

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

## 4. Jadwal Cron Backup

Jadwal otomatis backup yang digunakan:

| Jenis Backup | Waktu | Format Cron |
| :--- | :--- | :--- |
| Full | Minggu, 01:00 | `0 1 * * 0` |
| Incremental | Senin-Sabtu, 02:00 | `0 2 * * 1-6` |
| Differential | Senin-Sabtu, 03:00 | `0 3 * * 1-6` |

Contoh isi `crontab -e`:

```cron
0 1 * * 0 /home/capstone11/pg-setup/backup.sh full >> /backup/logs/cron_full.log 2>&1
0 2 * * 1-6 /home/capstone11/pg-setup/backup.sh incremental >> /backup/logs/cron_incremental.log 2>&1
0 3 * * 1-6 /home/capstone11/pg-setup/backup.sh differential >> /backup/logs/cron_differential.log 2>&1
```

## 5. Mekanisme Backup

Alur kerja backup otomatis:

1. Cron memicu `backup.sh` sesuai mode (`full`, `incremental`, atau `differential`).
2. Skrip melakukan dump database sesuai strategi backup yang dipilih.
3. File hasil dump langsung dienkripsi menggunakan AES-256.
4. Sistem membuat checksum MD5 untuk file terenkripsi (`.enc.md5`).
5. File backup terenkripsi ditransfer ke Replica melalui `rsync` via SSH.
6. File SQL plaintext dihapus setelah enkripsi selesai.
7. Aktivitas backup disimpan ke log untuk audit dan troubleshooting.

## 6. Ringkasan Keamanan Backup

| Komponen Keamanan | Implementasi |
| :--- | :--- |
| Enkripsi file backup | AES-256 |
| Enkripsi jalur transfer | SSH (rsync over SSH) |
| Validasi integritas | MD5 checksum |
| Kontrol kerahasiaan | Hanya file terenkripsi yang disimpan permanen |

## 7. Status Sementara Bulan 2

| Indikator | Status |
| :--- | :--- |
| Streaming replication Primary ke Replica | Aktif |
| Full backup terjadwal | Aktif |
| Incremental backup terjadwal | Aktif |
| Differential backup terjadwal | Aktif |
| Transfer backup ke Replica | Aktif |