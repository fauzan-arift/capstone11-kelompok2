## 1. Perbedaan install docker compose
**Sebelum:** Menggunakan ```sudo apt install docker-compose-plugin -y```

**Sesudah:** Menggunakan ```sudo apt install docker-compose-v2 -y```

## 2. Perbedaan Subnet IP Jaringan
**Sebelum:** Menggunakan subnet ```192.168.218.x``` untuk seluruh infrastruktur.

**Sesudah:** Menggunakan subnet ```192.168.10.x``` (Primary) dan ```192.168.20.x``` (Replica) yang terhubung melalui VM Router.

## 3. Penyesuaian REPLICA_IP
**Sebelum:** Seluruh skrip (```.env-backup, backup.sh, setup-ssh-aes.sh```) mengarah ke ```192.168.218.11```.

**Sesudah:** Sudah diganti menjadi ```192.168.20.11``` agar sesuai dengan alamat IP VM Replica baru.

## 4. Jalur Direktori Backup (Absolute Path)
**Sebelum:** Menggunakan jalur relatif home/capstone11/... atau jalur root /backup/... yang menyebabkan masalah perizinan (Permission denied).

**Sesudah:** Diubah menjadi jalur absolut /home/capstone11/backup/received untuk memastikan rsync mendarat di lokasi yang tepat tanpa kendala izin akses.

## 5. Perbaikan Fungsi Log (log())
**Sebelum:** Fungsi ```log()``` mencetak teks ke jalur standar (stdout). Hal ini menyebabkan teks log "bocor" masuk ke dalam variabel nama file, sehingga perintah rsync error.

**Sesudah:** Sudah ditambahkan ```>&2``` pada ujung fungsi ```log()``` di ```backup.sh``` agar teks laporan dikirim ke jalur stderr, sehingga variabel nama file tetap bersih.

## 6. Koreksi Target File MD5
**Sebelum:** Skrip mencoba mengirim ```${encrypted_file}.md5```, padahal file MD5 yang dibuat oleh sistem bernama ```${output_file}.md5``` (berdasarkan file .sql asli).

**Sesudah:** Variabel pengiriman di ```backup.sh``` sudah diperbaiki agar merujuk ke file MD5 yang benar. Mengganti ```${encrypted_file}.md5``` menjadi ```${output_file}.md5``` untuk setiap tipe backup.

## 7. Konfigurasi Adapter VMware
**Sebelum:** Hanya menyebutkan penggunaan VMnet1 (Host-only).

**Sesudah:** Menggunakan kombinasi VMnet2 dan VMnet3 agar simulasi routing antar-site (Bogor ke DRC) lebih mendekati kondisi nyata di lapangan (network berbeda).
