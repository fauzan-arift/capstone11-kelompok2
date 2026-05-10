# Recovery Drill (Simulasi Bencana Data) - Dokumentasi Bulan 3

Capstone 11 (Kelompok 2) - Capstone Project
Program Studi Ilmu Komputer IPB University 2026

Dokumen ini berisi panduan teknis untuk melakukan simulasi bencana dan pemulihan data pada infrastruktur database PostgreSQL yang telah dibangun pada bulan sebelumnya.

## Deskripsi
Bulan 3 berfokus pada pengujian skenario kegagalan (**Chaos Engineering**) untuk memastikan sistem deteksi kerusakan file, integritas backup, dan prosedur pemulihan berjalan sesuai dengan metrik keberhasilan yang telah ditentukan.

## Arsitektur Simulasi Bencana

```
VM Primary (Bogor)                     VM Replica (DRC)
┌─────────────────┐                   ┌─────────────────┐
│ [Bencana!]      │                   │ [Recovery Store]│
│ - Drop Table    │                   │ - Backup Enc    │
│ - Disk Full     │ <--- Restore ---- │ - MD5 Check     │
│ - Network Cut   │                   │ - Decryption    │
└─────────────────┘                   └─────────────────┘
```

## Bagian 1 - Chaos Engineering (Skenario Kerusakan)

### 1.1 Skenario File Backup Korup
Menguji kemampuan sistem dalam mendeteksi integritas data menggunakan *checksum* MD5 sebelum proses restorasi dilakukan.

**Langkah Kerja:**
1. Masuk ke direktori backup di Replica.
2. Modifikasi file `.enc` secara ilegal (simulasi kerusakan bit):
   ```
   echo "tamper" >> full_db_kependudukan_XXXX.sql.enc
   ```
3. Jalankan verifikasi:
   ```
   md5sum -c *.md5
   ```

   Hasil yang diharapkan: Status FAILED muncul, menandakan sistem berhasil mendeteksi perubahan ilegal pada file backup.

### 1.2 Skenario Penghapusan Tabel (Data Loss)
Mensimulasikan kesalahan manusia atau serangan yang menghapus data kritis pada database utama.

**Langkah Kerja:**
1. Hapus tabel kritis di Primary:
  ```
  DROP TABLE penduduk CASCADE;
  ```
2. Verifikasi di Replica: Data akan hilang secara real-time karena efek streaming replication.

## Bagian 2 - Prosedur Restoration & Downtime Measurement
### 2.1 Dekripsi Data (Security Engineer)

Memastikan data benar-benar terproteksi dan hanya bisa dibuka dengan kunci yang sah sebelum di-restore.  
  ```
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
    -in /home/capstone11/backup/received/full/full_db_kependudukan_XXXX.sql.enc \
    -out /tmp/restore_penduduk.sql \
    -pass pass:"$BACKUP_AES_PASSPHRASE"
  ```
### 2.2 Restoration Test
Melakukan proses impor data kembali ke database Primary untuk mengembalikan layanan.

**Metrik yang diukur:**

- **Recovery Time Objective (RTO)**: Waktu total dari terjadinya bencana hingga sistem kembali online.

- **Recovery Point Objective (RPO)**: Jumlah data yang hilang (ditargetkan 0% data loss).

## Bagian 3 - Pengujian Kondisi Abnormal

| Skenario | Langkah | Pengujian |
| :--- | :--- | :--- |
| **Interupsi Jaringan** | Matikan adapter VMnet saat proses pengiriman backup mencapai 50%. | Menguji apakah database menjadi locking, corrupt, atau bisa melakukan rollback. |
| **Disk Full** |	Gunakan fallocate -l 10G /backup/full/dummy untuk memenuhi disk. | Memastikan sistem memberi alert yang tepat dan tidak menghasilkan file backup kosong (0 KB). |
| **Salah Kunci** |	Mencoba dekripsi dengan passphrase yang salah.	| Memastikan data benar-benar tidak bisa dibaca tanpa kunci yang sah (menjamin fungsi keamanan). |

## Bagian 4 - Output & Laporan
Hasil dari aktivitas bulan ini dirangkum dalam Laporan Hasil Recovery Drill yang mencakup:

1. Log keberhasilan deteksi file korup melalui MD5. (belum)
2. Catatan waktu pemulihan (Downtime Measurement). (belum)
3. Verifikasi jumlah baris data pasca-pemulihan menggunakan COUNT(*) (Integritas 100%). (belum)
