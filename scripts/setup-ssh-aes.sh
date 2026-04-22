#!/bin/bash

source "$(dirname "$0")/.env-backup"

REPLICA_USER="capstone11"
REPLICA_IP="192.168.218.11"
SSH_KEY="$HOME/.ssh/backup_key"

echo "================================================"
echo " SETUP SSH KEY"
echo "================================================"

# Generate SSH key khusus backup
if [ ! -f "$SSH_KEY" ]; then
    echo "Membuat SSH key baru..."
    ssh-keygen -t ed25519 -C "backup-key-capstone11" -f "$SSH_KEY" -N ""
    echo "SSH key dibuat: $SSH_KEY"
else
    echo "SSH key sudah ada: $SSH_KEY (skip)"
fi

# Salin key ke Replica
echo ""
echo "Menyalin key ke Replica ($REPLICA_IP)..."
echo "Masukkan password $REPLICA_USER@$REPLICA_IP ketika diminta:"
ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no \
    "${REPLICA_USER}@${REPLICA_IP}"

if [ $? -ne 0 ]; then
    echo "ERROR: Gagal menyalin key. Cek koneksi ke Replica."
    exit 1
fi

# Test koneksi SSH
echo ""
echo "Test koneksi SSH ke Replica..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${REPLICA_USER}@${REPLICA_IP}" "echo 'SSH OK dari Primary ke Replica'"

if [ $? -ne 0 ]; then
    echo "ERROR: Koneksi SSH gagal."
    exit 1
fi
echo "Koneksi SSH berhasil!"

# Buat direktori backup di Replica
echo ""
echo "Membuat direktori backup di Replica..."
ssh -i "$SSH_KEY" "${REPLICA_USER}@${REPLICA_IP}" \
    "mkdir -p /backup/received/{full,incremental,differential}"
echo "Direktori backup di Replica siap."

echo ""
echo "================================================"
echo " SETUP DIREKTORI BACKUP DI PRIMARY"
echo "================================================"

sudo mkdir -p /backup/{full,incremental,differential,logs}
sudo chown -R "$USER:$USER" /backup
echo "Direktori /backup siap."

echo ""
echo "================================================"
echo " TEST ENKRIPSI AES-256"
echo "================================================"

# Pastikan OpenSSL tersedia
if ! command -v openssl &>/dev/null; then
    echo "OpenSSL tidak ditemukan. Install dulu:"
    echo "  sudo apt install openssl -y"
    exit 1
fi

echo "OpenSSL versi: $(openssl version)"

# Test enkripsi
echo "Data test backup capstone11" > /tmp/test_backup.txt

openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -in /tmp/test_backup.txt \
    -out /tmp/test_backup.enc \
    -pass pass:"$BACKUP_AES_PASSPHRASE"

if [ $? -ne 0 ]; then
    echo "ERROR: Enkripsi AES-256 gagal."
    exit 1
fi

# Test dekripsi
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
    -in /tmp/test_backup.enc \
    -out /tmp/test_backup_decrypted.txt \
    -pass pass:"$BACKUP_AES_PASSPHRASE"

if diff /tmp/test_backup.txt /tmp/test_backup_decrypted.txt &>/dev/null; then
    echo "Test enkripsi/dekripsi AES-256 BERHASIL."
else
    echo "ERROR: Test enkripsi/dekripsi GAGAL."
    exit 1
fi

# Test dengan passphrase salah 
echo ""
echo "Test dengan passphrase salah (harus gagal)..."
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
    -in /tmp/test_backup.enc \
    -out /tmp/test_wrong.txt \
    -pass pass:"passphrase_salah" 2>/dev/null

if [ $? -ne 0 ]; then
    echo "Passphrase salah → dekripsi ditolak. BENAR!"
else
    echo "WARNING: Dekripsi berhasil dengan passphrase salah. Cek konfigurasi."
fi

rm -f /tmp/test_backup.txt /tmp/test_backup.enc \
      /tmp/test_backup_decrypted.txt /tmp/test_wrong.txt

echo ""
echo "================================================"
echo " SETUP SELESAI"
echo "================================================"
echo ""