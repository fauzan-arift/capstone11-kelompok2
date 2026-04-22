#!/bin/bash

source "$(dirname "$0")/.env-backup"

# =============================================================================
# KONFIGURASI
# =============================================================================
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DATE_TODAY=$(date +"%Y%m%d")
BACKUP_DIR="/backup"
FULL_DIR="$BACKUP_DIR/full"
INC_DIR="$BACKUP_DIR/incremental"
DIFF_DIR="$BACKUP_DIR/differential"
LOG_FILE="$BACKUP_DIR/logs/backup_$TIMESTAMP.log"
FULL_MARKER="$BACKUP_DIR/.last_full_timestamp"

CONTAINER="pg-primary"
PG_USER="admin"
DATABASES=("db_kependudukan" "db_full" "db_inc" "db_diff")

REPLICA_USER="capstone11"
REPLICA_IP="192.168.218.11"
REPLICA_BACKUP_DIR="home/capstone11/backup/received"
SSH_KEY="$HOME/.ssh/backup_key"

# AES-256 passphrase — diambil dari .env-backup
AES_PASSPHRASE="$BACKUP_AES_PASSPHRASE"

# =============================================================================
# FUNGSI UTILITAS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_deps() {
    log "Memeriksa dependencies..."
    for cmd in docker openssl ssh rsync; do
        if ! command -v $cmd &>/dev/null; then
            log "ERROR: $cmd tidak ditemukan. Install dulu."
            exit 1
        fi
    done
    log "Semua dependencies tersedia."
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER$"; then
        log "ERROR: Container $CONTAINER tidak berjalan."
        exit 1
    fi
    log "Container $CONTAINER aktif."
}

prepare_dirs() {
    mkdir -p "$FULL_DIR" "$INC_DIR" "$DIFF_DIR" "$BACKUP_DIR/logs"
    log "Direktori backup siap."
}

check_disk_space() {
    local required_mb=$1
    local available_mb=$(df "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        log "ERROR: Disk tidak cukup. Tersedia: ${available_mb}MB, Dibutuhkan: ${required_mb}MB"
        send_alert "DISK PENUH" "Backup dibatalkan. Sisa disk: ${available_mb}MB"
        exit 1
    fi
    log "Disk OK. Tersedia: ${available_mb}MB"
}

send_alert() {
    local subject="[BACKUP ALERT] $1"
    local message="$2"
    log "ALERT: $subject — $message"
}

get_db_size() {
    local db=$1
    docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -t -c \
        "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null | tr -d ' '
}

verify_backup() {
    local file=$1
    if [ ! -f "$file" ]; then
        log "ERROR: File backup tidak ditemukan: $file"
        return 1
    fi
    local size=$(stat -c%s "$file")
    if [ "$size" -lt 100 ]; then
        log "ERROR: File backup terlalu kecil (${size} bytes) — kemungkinan kosong/korup"
        send_alert "BACKUP KORUP" "File $file hanya ${size} bytes"
        return 1
    fi
    local md5=$(md5sum "$file" | awk '{print $1}')
    echo "$md5  $(basename $file).enc" > "${file}.md5"
    log "Checksum MD5: $md5"
    log "Ukuran file : $(du -sh "$file" | cut -f1)"
    return 0
}

encrypt_file() {
    local input=$1
    local output="${input}.enc"
    log "Mengenkripsi dengan AES-256-CBC: $(basename $input)..."

    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$input" \
        -out "$output" \
        -pass pass:"$AES_PASSPHRASE"

    if [ $? -ne 0 ]; then
        log "ERROR: Enkripsi AES-256 gagal untuk $input"
        return 1
    fi

    rm -f "$input"
    log "Enkripsi berhasil: $(basename $output)"
    echo "$output"
}

send_to_replica() {
    local file=$1
    local dest_dir=$2
    log "Mengirim ke Replica via SSH/rsync (jalur terenkripsi TLS)..."

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "${REPLICA_USER}@${REPLICA_IP}" \
        "mkdir -p ${REPLICA_BACKUP_DIR}/${dest_dir}"

    rsync -avz --progress \
        --rsh="ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
        "$file" \
        "${REPLICA_USER}@${REPLICA_IP}:${REPLICA_BACKUP_DIR}/${dest_dir}/"

    if [ $? -eq 0 ]; then
        log "Transfer berhasil: $(basename $file) → Replica:${REPLICA_BACKUP_DIR}/${dest_dir}/"
    else
        log "ERROR: Transfer gagal untuk $(basename $file)"
        send_alert "TRANSFER GAGAL" "Gagal mengirim $(basename $file) ke Replica"
        return 1
    fi
}

# =============================================================================
# FULL BACKUP
# =============================================================================

do_full_backup() {
    log "============================================"
    log "MEMULAI FULL BACKUP — $TIMESTAMP"
    log "============================================"

    check_disk_space 2048

    local success_count=0
    local fail_count=0

    for db in "${DATABASES[@]}"; do
        log "--- Backup database: $db ---"
        log "Ukuran database: $(get_db_size $db)"

        local output_file="$FULL_DIR/full_${db}_${TIMESTAMP}.sql"

        docker exec "$CONTAINER" pg_dump \
            -U "$PG_USER" \
            -d "$db" \
            --format=plain \
            --no-password \
            > "$output_file" 2>>"$LOG_FILE"

        if [ $? -ne 0 ]; then
            log "ERROR: pg_dump gagal untuk database $db"
            fail_count=$((fail_count + 1))
            continue
        fi

        verify_backup "$output_file"
        if [ $? -ne 0 ]; then
            fail_count=$((fail_count + 1))
            continue
        fi

        local encrypted_file=$(encrypt_file "$output_file")
        send_to_replica "$encrypted_file" "full"
        send_to_replica "${encrypted_file}.md5" "full"

        success_count=$((success_count + 1))
        log "Database $db selesai."
    done

    echo "$TIMESTAMP" > "$FULL_MARKER"
    echo "$DATE_TODAY" >> "$FULL_MARKER"

    log "============================================"
    log "FULL BACKUP SELESAI. Berhasil: $success_count, Gagal: $fail_count"
    log "============================================"

    if [ "$fail_count" -gt 0 ]; then
        send_alert "FULL BACKUP PARSIAL" "$fail_count database gagal di-backup"
    fi
}

# =============================================================================
# INCREMENTAL BACKUP
# =============================================================================

do_incremental_backup() {
    log "============================================"
    log "MEMULAI INCREMENTAL BACKUP — $TIMESTAMP"
    log "============================================"

    check_disk_space 512

    local output_file="$INC_DIR/incremental_${TIMESTAMP}.tar.gz"

    log "Menjalankan pg_basebackup..."

    docker exec "$CONTAINER" pg_basebackup \
        -U "$PG_USER" \
        -D /tmp/inc_backup_$TIMESTAMP \
        -Ft -z -Xs -P \
        2>>"$LOG_FILE"

    if [ $? -ne 0 ]; then
        log "ERROR: pg_basebackup gagal"
        exit 1
    fi

    docker cp "$CONTAINER:/tmp/inc_backup_$TIMESTAMP/base.tar.gz" "$output_file"
    docker exec "$CONTAINER" rm -rf "/tmp/inc_backup_$TIMESTAMP"

    verify_backup "$output_file"
    if [ $? -ne 0 ]; then
        log "ERROR: Incremental backup gagal verifikasi"
        exit 1
    fi

    local encrypted_file=$(encrypt_file "$output_file")
    send_to_replica "$encrypted_file" "incremental"
    send_to_replica "${encrypted_file}.md5" "incremental"

    log "============================================"
    log "INCREMENTAL BACKUP SELESAI"
    log "============================================"
}

# =============================================================================
# DIFFERENTIAL BACKUP
# =============================================================================

do_differential_backup() {
    log "============================================"
    log "MEMULAI DIFFERENTIAL BACKUP — $TIMESTAMP"
    log "============================================"

    check_disk_space 1024

    if [ ! -f "$FULL_MARKER" ]; then
        log "PERINGATAN: Belum ada full backup. Menjalankan full backup dulu..."
        do_full_backup
        return
    fi

    local last_full_ts=$(head -1 "$FULL_MARKER")
    local last_full_date=$(tail -1 "$FULL_MARKER")
    log "Referensi full backup terakhir: $last_full_ts ($last_full_date)"

    local success_count=0
    local fail_count=0

    for db in "${DATABASES[@]}"; do
        log "--- Differential backup database: $db ---"

        local output_file="$DIFF_DIR/diff_${db}_since_${last_full_date}_${TIMESTAMP}.sql"

        docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -c \
            "SELECT pg_switch_wal();" > /dev/null 2>&1

        docker exec "$CONTAINER" pg_dump \
            -U "$PG_USER" \
            -d "$db" \
            --format=plain \
            --no-password \
            > "$output_file" 2>>"$LOG_FILE"

        if [ $? -ne 0 ]; then
            log "ERROR: Differential backup gagal untuk $db"
            fail_count=$((fail_count + 1))
            continue
        fi

        verify_backup "$output_file"
        if [ $? -ne 0 ]; then
            fail_count=$((fail_count + 1))
            continue
        fi

        local encrypted_file=$(encrypt_file "$output_file")
        send_to_replica "$encrypted_file" "differential"
        send_to_replica "${encrypted_file}.md5" "differential"

        success_count=$((success_count + 1))
    done

    log "============================================"
    log "DIFFERENTIAL BACKUP SELESAI. Berhasil: $success_count, Gagal: $fail_count"
    log "============================================"
}

# =============================================================================
# MAIN
# =============================================================================

mkdir -p "$BACKUP_DIR/logs"
log "===== BACKUP SCRIPT START ====="
log "Tipe backup : $1"
log "Host        : $(hostname)"
log "Enkripsi    : AES-256-CBC (OpenSSL)"

check_deps
check_container
prepare_dirs

case "$1" in
    full)
        do_full_backup
        ;;
    incremental)
        do_incremental_backup
        ;;
    differential)
        do_differential_backup
        ;;
    *)
        echo "Penggunaan: $0 {full|incremental|differential}"
        echo ""
        echo "  full          → Full backup semua database (jalankan mingguan)"
        echo "  incremental   → Incremental backup via WAL (jalankan harian)"
        echo "  differential  → Differential backup sejak full terakhir"
        exit 1
        ;;
esac

log "===== BACKUP SCRIPT SELESAI ====="
exit 0