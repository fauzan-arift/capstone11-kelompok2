# Recovery Drill (Simulasi Bencana Data) - Dokumentasi Bulan 3_4

Capstone 11 (Kelompok 2) - Capstone Project
Program Studi Ilmu Komputer IPB University 2026

Dokumen ini berisi panduan teknis dan laporan eksekusi dari fase **Recovery Drill**. Fase ini berfokus pada pengujian ketahanan sistem melalui *Chaos Engineering* (Skenario Negatif) dan pengukuran performa pemulihan data (Restoration Test) pada infrastruktur database PostgreSQL yang telah dibangun pada bulan sebelumnya.

## Deskripsi Eksekusi
Pengujian ini sepenuhnya diotomatisasi menggunakan skrip `recovery-drill.sh` yang menjalankan 9 skenario simulasi bencana, pemulihan data, dan anomali sistem secara terstruktur pada dataset kependudukan riil (> 2,1 juta baris).

## Pemetaan Skenario Pengujian (Berdasarkan Rencana Kerja)

### 1. Chaos Engineering (Negative Testing)
Menguji bagaimana sistem bereaksi terhadap kondisi abnormal. Mahasiswa berperan sebagai "perusak" sistem.

* **Skenario File Backup Dikorupsi**
  * *Tujuan:* Menguji apakah sistem mendeteksi kerusakan file sebelum proses *restore* (menghindari penulisan data sampah).
  * *Mekanisme:* Injeksi byte statis (`\xDE\xAD\xBE\xEF`) di tengah file `.enc`.
  * *Hasil:* Sistem `[PASS]` membatalkan *restore* berkat ketidakcocokan nilai *checksum* MD5.
* **Skenario Interupsi Jaringan Saat Backup**
  * *Tujuan:* Menguji apakah database menjadi *locking* atau memproduksi file korup saat koneksi SSH terputus tiba-tiba di angka 50%.
  * *Mekanisme:* Pemutusan proses `rsync` secara paksa (`pkill -f rsync`).
  * *Hasil:* Sistem `[PASS]` tidak menghasilkan file backup 0 KB, dan tabel database tetap responsif.
* **Skenario Disk Penuh di Site Primary**
  * *Tujuan:* Memastikan sistem memberikan *alert* dan tidak memaksa *backup* (menghasilkan file 0 KB).
  * *Mekanisme:* Eksekusi `fallocate` untuk menyisakan ruang < 30 MB.
  * *Hasil:* Sistem `[PASS]` mendeteksi ruang tidak cukup dan menggagalkan *backup* secara aman.

### 2. Skenario Bencana Utama
* **Skenario DROP TABLE CASCADE**
  * *Tujuan:* Simulasi kehilangan data (*Data Loss*) yang masif akibat *human error* atau SQL *Injection*.
  * *Mekanisme:* Tabel layanan_publik, bpjs_kesehatan, bansos_umkm, dan penduduk dihapus paksa dari sistem Primary.
  * *Hasil:* Tabel hilang di Primary `[PASS]`, dan efek replikasi asinkron (*Replication Lag*) merambat ke Replica.

### 3. Restoration Test (Uji Pemulihan & Downtime Measurement)
Mengukur RTO (Recovery Time Objective) dari berbagai strategi *backup*. (Pemulihan diuji dengan mengembalikan >2.1 juta baris data).

| Skenario | Target Restore | Data Terpulihkan | RTO (Estimasi Riil) | Integritas (Data Loss) |
| :--- | :--- | :--- | :--- | :--- |
| **Recovery Full Backup** | `db_full` | 2.199.747 baris | ~ 49 detik | 0 baris (100% Valid) |
| **Recovery Differential**| `db_diff` | 2.199.747 baris | ~ 413 detik | 0 baris (100% Valid) |
| **Recovery Incremental** | `db_inc`  | 2.199.747 baris | ~ 257 detik | 0 baris (100% Valid) |

### 4. Point-in-Time Recovery & Keamanan Tambahan
* **Skenario Point-in-Time Recovery (PITR)**
  * *Tujuan:* Mengembalikan status database persis seperti sebelum gelombang (*batch*) injeksi data masuk (Checkpoint T0).
  * *Hasil:* Sistem `[PASS]` merestorasi data ke jumlah T0 dengan tepat 2.199.747 baris dan dengan waktu RTO ~ 219 detik.
* **Skenario Uji Keamanan Enkripsi (Passphrase Salah)** *(Aktivitas Bulan 4)*
  * *Tujuan:* Membuktikan kekuatan enkripsi Data *at-rest*.
  * *Hasil:* Sistem `[PASS]` menolak akses total jika kunci AES-256 (OpenSSL) tidak cocok.

---

## Cara Menjalankan Recovery Drill
Pengujian dilakukan dengan menjalankan skrip melalui terminal `VM-PRIMARY-BOGOR`:

```bash
# 1. Masuk ke direktori
cd ~/pg-setup

# 2. Lakukan Inisialisasi Data Dasar (Membangun Checkpoint T0 - T3)
./recovery-drill.sh setup

# 3. Jalankan Seluruh Skenario Bencana
./recovery-drill.sh setup
./recovery-drill.sh 02
./recovery-drill.sh 03
./recovery-drill.sh 04
./recovery-drill.sh 05
./recovery-drill.sh 06
./recovery-drill.sh 07
./recovery-drill.sh 08
./recovery-drill.sh 09
```
## Evaluasi & Limitasi Sistem (Catatan)
Sistem ini disimulasikan menggunakan limitasi bawaan (native) dari `pg_dump` dan `pg_basebackup`. Dalam lingkungan PostgreSQL Enterprise sesungguhnya:
1. Differential backup secara logika biasanya tidak didukung langsung oleh tools native, sehingga skrip menyimulasikan efeknya dengan modifikasi dump.
2. Restorasi parsial untuk Incremental backup disimulasikan ke level artefak fisik `(.tar.gz.enc)`.
3. Penggunaan arsitektur Real-World direkomendasikan menggunakan peranti 3rd-party khusus seperti `pgBackRest`.
