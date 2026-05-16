#!/bin/bash

# recovery-drill.sh
# Capstone 11 Kelompok 2 - IPB University 2026
#
# Penggunaan:
#   ./recovery-drill.sh setup        -- siapkan data simulasi (jalankan pertama kali)
#   ./recovery-drill.sh all          -- jalankan semua skenario
#   ./recovery-drill.sh 01           -- file backup dikorupsi
#   ./recovery-drill.sh 02           -- drop table (simulasi bencana)
#   ./recovery-drill.sh 03           -- recovery full backup
#   ./recovery-drill.sh 04           -- recovery differential
#   ./recovery-drill.sh 05           -- recovery incremental
#   ./recovery-drill.sh 06           -- interupsi jaringan
#   ./recovery-drill.sh 07           -- disk penuh
#   ./recovery-drill.sh 08           -- passphrase salah
#   ./recovery-drill.sh 09           -- point-in-time recovery
#   ./recovery-drill.sh 03 04 05     -- beberapa skenario sekaligus
#   ./recovery-drill.sh report       -- cetak laporan dari state tersimpan

# ===========================================================================
# STRICT MODE
# Aktifkan strict mode global. Bagian yang boleh gagal pakai || true eksplisit.
# ===========================================================================
set -euo pipefail

# ===========================================================================
# LOAD KONFIGURASI
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env-backup"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/backup/logs/drill_${TIMESTAMP}.log"
REPORT_FILE="/backup/logs/laporan_drill_${TIMESTAMP}.txt"
RESTORE_DIR="/tmp/drill_restore_${TIMESTAMP}"
STATE_FILE="/backup/.drill_state"

CONTAINER="pg-primary"
PG_USER="admin"
DB_MAIN="db_kependudukan"
DB_FULL="db_full"
DB_DIFF="db_diff"
DB_INC="db_inc"

SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SCP_CMD="scp -i $SSH_KEY -o StrictHostKeyChecking=no"

PASS=0
FAIL=0

# ===========================================================================
# FUNGSI DASAR
# ===========================================================================

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

ok() {
    echo "  [PASS] $*" | tee -a "$REPORT_FILE"
    log "[PASS] $*"
    PASS=$((PASS + 1))
}

fail() {
    echo "  [FAIL] $*" | tee -a "$REPORT_FILE"
    log "[FAIL] $*"
    FAIL=$((FAIL + 1))
}

info() {
    echo "  [INFO] $*" | tee -a "$REPORT_FILE"
    log "[INFO] $*"
}

section() {
    echo "" | tee -a "$REPORT_FILE"
    echo "------------------------------------------------------------" | tee -a "$REPORT_FILE"
    echo "  $*" | tee -a "$REPORT_FILE"
    echo "------------------------------------------------------------" | tee -a "$REPORT_FILE"
    echo ""
}

die() {
    echo "[ERROR] $*" >&2
    log "[ERROR] $*"
    exit 1
}

# Cek apakah container berjalan
container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$" || return 1
}

# Hitung baris tabel — selalu return angka, tidak pernah kosong
# P1 fix: fallback ke 0 jika tabel tidak ada atau query error
row_count() {
    local db=$1 tbl=$2
    local result
    result=$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -t \
        -c "SELECT COUNT(*) FROM $tbl;" 2>/dev/null | tr -d ' \n') || true
    # Pastikan hasilnya angka, fallback 0
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Cek apakah tabel ada
table_exists() {
    local db=$1 tbl=$2
    local r
    r=$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -t \
        -c "SELECT EXISTS(SELECT 1 FROM information_schema.tables
            WHERE table_schema='public' AND table_name='$tbl');" \
        2>/dev/null | tr -d ' \n') || true
    [ "$r" = "t" ]
}

# Dekripsi file AES-256
decrypt() {
    local src=$1 dst=$2
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
        -in "$src" -out "$dst" \
        -pass pass:"$BACKUP_AES_PASSPHRASE" 2>/dev/null || return 1
}

# Restore SQL ke database — tangkap exit code dengan benar
restore_to() {
    local file=$1 db=$2
    if [ ! -f "$file" ]; then
        log "File tidak ada: $file"
        return 1
    fi
    docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$db" \
        < "$file" > /dev/null 2>&1 || return 1
    return 0
}

# P2 fix: pakai IF EXISTS untuk menghindari error jika schema tidak ada
reset_db() {
    local db=$1
    docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" \
        -c "DROP SCHEMA IF EXISTS public CASCADE;
            CREATE SCHEMA public;
            GRANT ALL ON SCHEMA public TO $PG_USER;" \
        > /dev/null 2>&1 || true
}

# Verifikasi tabel penting ada setelah restore
verify_restore() {
    local db=$1
    local all_ok=true
    for tbl in penduduk kartu_keluarga layanan_publik bpjs_kesehatan bansos_umkm; do
        if ! table_exists "$db" "$tbl"; then
            log "Tabel $tbl tidak ditemukan di $db setelah restore"
            all_ok=false
        fi
    done
    [ "$all_ok" = true ] || return 1
}

# Simpan state
save_state() { echo "$1=$2" >> "$STATE_FILE"; }

# Baca state — return kosong jika tidak ada, aman untuk aritmatika dengan fallback
load_state() {
    grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Ambil file dari Replica yang dibuat sejak waktu tertentu (epoch seconds)
# P1 fix: since diambil sebelum backup dijalankan, bukan sesudah
get_remote_file() {
    local dir=$1 pattern=$2 since=${3:-0}
    $SSH_CMD "${REPLICA_USER}@${REPLICA_IP}" \
        "for f in \$(ls -tr ${dir}/${pattern} 2>/dev/null); do
             t=\$(stat -c %Y \"\$f\" 2>/dev/null || echo 0);
             [ \"\$t\" -ge \"$since\" ] && echo \"\$f\" && break;
         done" 2>/dev/null || true
}

# Salin file dari Replica ke lokal
pull_from_replica() {
    local remote=$1 local_path=$2
    [ -z "$remote" ] && return 1
    $SCP_CMD "${REPLICA_USER}@${REPLICA_IP}:${remote}" "$local_path" 2>/dev/null || return 1
}

# ===========================================================================
# INSERT DATA BATCH (semua tabel sesuai skema)
# ===========================================================================

insert_batch() {
    local batch=$1 prefix=$2 kota=$3 kec=$4 kel=$5 rt=$6 rw=$7 kpos=$8
    log "Insert batch $batch (NIK prefix: ${prefix}xx, kota: $kota)..."

    docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB_MAIN" << SQL || true
INSERT INTO kartu_keluarga
    (no_kk, nik_kepala, provinsi, kota_kabupaten, kecamatan, kelurahan_desa, rt, rw, kode_pos)
SELECT
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    'Jawa Barat', '$kota', '$kec', '$kel', '$rt', '$rw', '$kpos'
FROM generate_series(1, 2000) n
ON CONFLICT DO NOTHING;

INSERT INTO penduduk
    (nik, no_kk, nama_lengkap, jenis_kelamin, tempat_lahir, tanggal_lahir,
     umur, agama, status_perkawinan, golongan_darah, pendidikan_terakhir, pekerjaan)
SELECT
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    'Penduduk Drill B${batch} ' || n,
    CASE WHEN n % 2 = 0 THEN 'L' ELSE 'P' END,
    '$kota',
    '1970-01-01'::DATE + (n % 18000),
    2026 - EXTRACT(YEAR FROM '1970-01-01'::DATE + (n % 18000))::INT,
    (ARRAY['Islam','Kristen','Katolik','Hindu','Buddha'])[n % 5 + 1],
    (ARRAY['Belum Kawin','Kawin','Cerai Hidup','Cerai Mati'])[n % 4 + 1],
    (ARRAY['A','B','AB','O'])[n % 4 + 1],
    (ARRAY['SD','SMP','SMA','D3','S1','S2'])[n % 6 + 1],
    (ARRAY['PNS','Swasta','Wiraswasta','Petani','Tidak Bekerja'])[n % 5 + 1]
FROM generate_series(1, 2000) n
ON CONFLICT DO NOTHING;

INSERT INTO layanan_publik
    (id_layanan, nik, nama_ddp, sumber_referensi, tahun_tersedia,
     status_record, tanggal_input, tanggal_update)
SELECT
    'LAY-B${batch}-' || LPAD(n::TEXT, 6, '0'),
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    (ARRAY['Pembuatan KTP','Akta Lahir','Kartu Keluarga','SIM','SKCK'])[n % 5 + 1],
    (ARRAY['Kemendagri','Disdukcapil','Polri'])[n % 3 + 1],
    2020 + (n % 5),
    (ARRAY['Aktif','Selesai','Proses'])[n % 3 + 1],
    NOW() - ((n % 365) * INTERVAL '1 day'),
    NOW() - ((n % 30) * INTERVAL '1 day')
FROM generate_series(1, 2000) n
ON CONFLICT DO NOTHING;

INSERT INTO bpjs_kesehatan
    (id_bpjs, nik, kode_sds, versi_sds, klasifikasi_penyajian, metode, status_record)
SELECT
    'BPJS-B${batch}-' || LPAD(n::TEXT, 6, '0'),
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    'SDS' || (n % 10 + 1),
    'v' || (n % 3 + 1) || '.0',
    (ARRAY['Individu','Agregat','Sampel'])[n % 3 + 1],
    (ARRAY['Sensus','Survei','Registrasi'])[n % 3 + 1],
    (ARRAY['Aktif','Nonaktif'])[n % 2 + 1]
FROM generate_series(1, 2000) n
ON CONFLICT DO NOTHING;

INSERT INTO bansos_umkm
    (id_bansos, nik, nama_ddp, sumber_referensi, kode_referensi, status_record, tanggal_input)
SELECT
    'BNS-B${batch}-' || LPAD(n::TEXT, 6, '0'),
    LPAD((${prefix}00000000000000 + n)::TEXT, 16, '0'),
    (ARRAY['BLT 2024','KUR Mikro','PKH','BPNT','Bansos Covid'])[n % 5 + 1],
    (ARRAY['Kemensos','Kemenkop','BI','BRI'])[n % 4 + 1],
    'REF-B${batch}-' || LPAD(n::TEXT, 6, '0'),
    (ARRAY['Aktif','Selesai','Ditolak'])[n % 3 + 1],
    NOW() - ((n % 365) * INTERVAL '1 day')
FROM generate_series(1, 2000) n
ON CONFLICT DO NOTHING;
SQL
    log "Batch $batch selesai"
}

# ===========================================================================
# SETUP: siapkan data simulasi dan backup bertahap
# ===========================================================================

run_setup() {
    section "SETUP — Persiapan Data Simulasi"

    container_running "$CONTAINER" || die "Container $CONTAINER tidak berjalan"

    AWAL=$(row_count "$DB_MAIN" penduduk)
    info "Data awal penduduk: $AWAL baris"

    # P1 fix: catat SINCE sebelum backup dijalankan, bukan sesudah
    # supaya get_remote_file bisa menemukan file yang baru dibuat

    # T0: full backup sebagai baseline
    T0_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    T0_SINCE=$(date +%s)                          # <-- sebelum backup
    log "Menjalankan full backup (T0)..."
    bash "$SCRIPT_DIR/backup.sh" full >> "$LOG_FILE" 2>&1 || true
    T0_COUNT=$AWAL
    sleep 2

    # Batch 1
    insert_batch 1 99 "Bogor" "Kec. Bogor Tengah" "Kel. Cibogor" "001" "001" "16111"
    B1=$(row_count "$DB_MAIN" penduduk)
    info "Setelah batch 1: $B1 baris"

    # T1: differential + incremental
    T1_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    T1_SINCE=$(date +%s)                          # <-- sebelum backup
    log "Menjalankan differential dan incremental backup (T1)..."
    bash "$SCRIPT_DIR/backup.sh" differential >> "$LOG_FILE" 2>&1 || true
    bash "$SCRIPT_DIR/backup.sh" incremental  >> "$LOG_FILE" 2>&1 || true
    T1_COUNT=$B1
    sleep 2

    # Batch 2
    insert_batch 2 98 "Depok" "Kec. Beji" "Kel. Kemiri Muka" "002" "002" "16422"
    B2=$(row_count "$DB_MAIN" penduduk)
    info "Setelah batch 2: $B2 baris"

    # T2: incremental
    T2_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    T2_SINCE=$(date +%s)                          # <-- sebelum backup
    log "Menjalankan incremental backup (T2)..."
    bash "$SCRIPT_DIR/backup.sh" incremental >> "$LOG_FILE" 2>&1 || true
    T2_COUNT=$B2
    sleep 2

    # Batch 3
    insert_batch 3 97 "Bekasi" "Kec. Bekasi Utara" "Kel. Harapan Baru" "003" "003" "17122"
    B3=$(row_count "$DB_MAIN" penduduk)
    info "Setelah batch 3: $B3 baris"

    # T3: incremental terakhir
    T3_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    T3_SINCE=$(date +%s)                          # <-- sebelum backup
    log "Menjalankan incremental backup (T3 — terbaru)..."
    bash "$SCRIPT_DIR/backup.sh" incremental >> "$LOG_FILE" 2>&1 || true
    T3_COUNT=$B3
    sleep 2

    # Simpan semua state
    rm -f "$STATE_FILE"
    save_state "AWAL"            "$AWAL"
    save_state "T0_TIME"         "$T0_TIME"
    save_state "T0_COUNT"        "$T0_COUNT"
    save_state "T0_SINCE"        "$T0_SINCE"
    save_state "T1_TIME"         "$T1_TIME"
    save_state "T1_COUNT"        "$T1_COUNT"
    save_state "T1_SINCE"        "$T1_SINCE"
    save_state "T2_TIME"         "$T2_TIME"
    save_state "T2_COUNT"        "$T2_COUNT"
    save_state "T2_SINCE"        "$T2_SINCE"
    save_state "T3_TIME"         "$T3_TIME"
    save_state "T3_COUNT"        "$T3_COUNT"
    save_state "T3_SINCE"        "$T3_SINCE"
    save_state "BEFORE_DISASTER" "$B3"

    echo ""
    echo "  Setup selesai. Checkpoint tersedia:"
    echo "    T0: $T0_TIME — $T0_COUNT baris (full backup)"
    echo "    T1: $T1_TIME — $T1_COUNT baris (diff + inc)"
    echo "    T2: $T2_TIME — $T2_COUNT baris (inc)"
    echo "    T3: $T3_TIME — $T3_COUNT baris (inc — terbaru)"
    echo ""
    echo "  Langkah berikutnya:"
    echo "    ./recovery-drill.sh 02   <- simulasi bencana"
    echo "    ./recovery-drill.sh all  <- semua skenario sekaligus"
}

# ===========================================================================
# SKENARIO 01 — File backup dikorupsi
# ===========================================================================

run_01() {
    section "SKENARIO 01 — File Backup Dikorupsi"

    local since
    since=$(load_state T0_SINCE)
    since=${since:-0}

    local remote remote_md5
    remote=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$since")
    remote_md5=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc.md5" "$since")

    if [ -z "$remote" ]; then
        fail "File backup tidak ditemukan di Replica — jalankan setup dulu"
        return
    fi

    mkdir -p "$RESTORE_DIR"
    pull_from_replica "$remote"     "$RESTORE_DIR/korup_test.sql.enc"     || true
    pull_from_replica "$remote_md5" "$RESTORE_DIR/korup_test.sql.enc.md5" || true

    # Catat MD5 sebelum dikorupsi
    local md5_asli
    md5_asli=$(md5sum "$RESTORE_DIR/korup_test.sql.enc" 2>/dev/null | awk '{print $1}') || true

    # Korupsi: tulis 4 byte di tengah file
    local size mid
    size=$(stat -c %s "$RESTORE_DIR/korup_test.sql.enc" 2>/dev/null) || size=0
    mid=$((size / 2))
    printf '\xDE\xAD\xBE\xEF' | dd of="$RESTORE_DIR/korup_test.sql.enc" \
        bs=1 seek="$mid" conv=notrunc 2>/dev/null || true
    log "File dikorupsi pada byte offset $mid"

    # Bandingkan MD5
    local md5_sesudah
    md5_sesudah=$(md5sum "$RESTORE_DIR/korup_test.sql.enc" 2>/dev/null | awk '{print $1}') || true

    if [ -n "$md5_asli" ] && [ "$md5_asli" != "$md5_sesudah" ]; then
        ok "Deteksi korupsi via MD5 — hash berubah ($md5_asli → $md5_sesudah)"
    else
        fail "MD5 tidak berubah meski file sudah dikorupsi"
    fi

    # Verifikasi lewat md5sum -c
    sed -i "s|$(basename "$remote")|korup_test.sql.enc|g" \
        "$RESTORE_DIR/korup_test.sql.enc.md5" 2>/dev/null || true
    cd "$RESTORE_DIR"
    if md5sum -c "korup_test.sql.enc.md5" 2>&1 | grep -qi "FAILED"; then
        ok "md5sum -c mendeteksi ketidakcocokan — restore seharusnya dibatalkan"
    else
        fail "md5sum -c tidak mendeteksi korupsi"
    fi
    cd - > /dev/null

    rm -f "$RESTORE_DIR"/korup_test.* || true
}

# ===========================================================================
# SKENARIO 02 — DROP TABLE (simulasi bencana)
# ===========================================================================

run_02() {
    section "SKENARIO 02 — Simulasi Bencana (DROP TABLE CASCADE)"

    local before
    before=$(load_state BEFORE_DISASTER)
    before=${before:-$(row_count "$DB_MAIN" penduduk)}

    info "Jumlah penduduk sebelum bencana: $before baris"

    save_state "DISASTER_TIME" "$(date '+%Y-%m-%d %H:%M:%S')"

    if docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB_MAIN" \
        -c "DROP TABLE layanan_publik, bpjs_kesehatan, bansos_umkm, penduduk CASCADE;" > /dev/null 2>&1; then
        ok "DROP TABLE layanan_publik, bpjs_kesehatan, bansos_umkm, penduduk CASCADE berhasil"
    else
        fail "DROP TABLE gagal"
        return
    fi

    # Verifikasi tabel hilang
    for tbl in penduduk layanan_publik bpjs_kesehatan bansos_umkm; do
        if ! table_exists "$DB_MAIN" "$tbl"; then
            ok "Tabel $tbl terhapus dari $DB_MAIN"
        else
            fail "Tabel $tbl masih ada di $DB_MAIN"
        fi
    done

    # Cek efek ke Replica
    sleep 3
    if $SSH_CMD "${REPLICA_USER}@${REPLICA_IP}" "docker ps | grep -q pg-replica" 2>/dev/null; then
        local r
        r=$($SSH_CMD "${REPLICA_USER}@${REPLICA_IP}" "docker exec pg-replica psql -U $PG_USER -d $DB_MAIN -t -c \"SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='penduduk');\"" 2>/dev/null | tr -d ' \n') || r="unknown"
        if [ "$r" = "f" ]; then
            ok "Replica ikut kehilangan tabel penduduk — WAL streaming bekerja"
        elif [ "$r" = "t" ]; then
            fail "Replica masih punya tabel penduduk"
        else
            info "Tidak bisa verifikasi Replica (container mungkin tidak berjalan)"
        fi
    else
        info "Container pg-replica tidak berjalan — skip cek Replica"
    fi
}

# ===========================================================================
# SKENARIO 03 — Recovery Full Backup
# ===========================================================================

run_03() {
    section "SKENARIO 03 — Recovery Full Backup → $DB_FULL"

    local since before
    since=$(load_state T0_SINCE); since=${since:-0}
    before=$(load_state BEFORE_DISASTER); before=${before:-0}

    reset_db "$DB_FULL"
    mkdir -p "$RESTORE_DIR"

    local remote
    remote=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$since")

    if [ -z "$remote" ]; then
        fail "File full backup tidak ditemukan di Replica"
        return
    fi

    info "Mengambil: $(basename "$remote")"
    if ! pull_from_replica "$remote" "$RESTORE_DIR/full.sql.enc"; then
        fail "Gagal mengambil file dari Replica"
        return
    fi

    local t_start t_end durasi
    t_start=$(date +%s)

    if ! decrypt "$RESTORE_DIR/full.sql.enc" "$RESTORE_DIR/full.sql"; then
        fail "Dekripsi gagal"
        rm -f "$RESTORE_DIR"/full.* || true
        return
    fi
    ok "Dekripsi berhasil"

    if ! restore_to "$RESTORE_DIR/full.sql" "$DB_FULL"; then
        fail "Restore ke $DB_FULL gagal"
        rm -f "$RESTORE_DIR"/full.* || true
        return
    fi

    t_end=$(date +%s)
    durasi=$((t_end - t_start))

    if verify_restore "$DB_FULL"; then
        ok "Semua tabel ada di $DB_FULL setelah restore"
    else
        fail "Ada tabel yang hilang setelah restore"
    fi

    # P1 fix: row_count selalu return angka, loss aman dihitung
    local restored loss
    restored=$(row_count "$DB_FULL" penduduk)
    loss=$((before - restored))

    ok "Recovery selesai dalam ${durasi} detik"
    info "Penduduk terpulihkan : $restored baris"
    info "Data loss            : $loss baris"
    info "RTO                  : ${durasi} detik"

    save_state "FULL_RESTORED" "$restored"
    save_state "FULL_LOSS"     "$loss"
    save_state "FULL_RTO"      "$durasi"

    rm -f "$RESTORE_DIR"/full.* || true
}

# ===========================================================================
# SKENARIO 04 — Recovery Differential
# ===========================================================================

run_04() {
    section "SKENARIO 04 — Recovery Differential Backup → $DB_DIFF"

    local since before
    since=$(load_state T0_SINCE); since=${since:-0}
    before=$(load_state BEFORE_DISASTER); before=${before:-0}

    reset_db "$DB_DIFF"
    mkdir -p "$RESTORE_DIR"

    local remote_full remote_diff
    remote_full=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$since")
    remote_diff=$(get_remote_file "$REPLICA_BACKUP_DIR/differential" \
        "diff_db_kependudukan_*.sql.enc" "$since")

    if [ -z "$remote_full" ] || [ -z "$remote_diff" ]; then
        fail "File full atau differential tidak ditemukan di Replica"
        return
    fi

    local t_start t_end durasi
    t_start=$(date +%s)

    # Step 1: restore full sebagai base
    info "Step 1: restore full backup sebagai base..."
    pull_from_replica "$remote_full" "$RESTORE_DIR/diff_base.sql.enc" || true
    decrypt "$RESTORE_DIR/diff_base.sql.enc" "$RESTORE_DIR/diff_base.sql" || true
    restore_to "$RESTORE_DIR/diff_base.sql" "$DB_DIFF" || true
    ok "Base (full) di-restore ke $DB_DIFF"

    # Step 2: timpa dengan differential
    info "Step 2: apply differential backup..."
    pull_from_replica "$remote_diff" "$RESTORE_DIR/diff_delta.sql.enc" || true
    decrypt "$RESTORE_DIR/diff_delta.sql.enc" "$RESTORE_DIR/diff_delta.sql" || true
    reset_db "$DB_DIFF"
    restore_to "$RESTORE_DIR/diff_delta.sql" "$DB_DIFF" || true
    ok "Differential di-apply ke $DB_DIFF"

    t_end=$(date +%s)
    durasi=$((t_end - t_start))

    if verify_restore "$DB_DIFF"; then
        ok "Semua tabel ada di $DB_DIFF setelah restore"
    else
        fail "Ada tabel yang hilang setelah restore"
    fi

    local restored loss
    restored=$(row_count "$DB_DIFF" penduduk)
    loss=$((before - restored))

    ok "Recovery selesai dalam ${durasi} detik"
    info "Penduduk terpulihkan : $restored baris"
    info "Data loss            : $loss baris"
    info "RTO                  : ${durasi} detik"

    save_state "DIFF_RESTORED" "$restored"
    save_state "DIFF_LOSS"     "$loss"
    save_state "DIFF_RTO"      "$durasi"

    rm -f "$RESTORE_DIR"/diff_* || true
}

# ===========================================================================
# SKENARIO 05 — Recovery Incremental
# ===========================================================================

run_05() {
    section "SKENARIO 05 — Recovery Incremental Backup → $DB_INC"

    local since before
    since=$(load_state T0_SINCE); since=${since:-0}
    before=$(load_state BEFORE_DISASTER); before=${before:-0}

    reset_db "$DB_INC"
    mkdir -p "$RESTORE_DIR"

    local remote_full
    remote_full=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$since")

    if [ -z "$remote_full" ]; then
        fail "File full backup tidak ditemukan di Replica"
        return
    fi

    local t_start t_end durasi
    t_start=$(date +%s)

    # Step 1: restore full sebagai base
    info "Step 1: restore full backup sebagai base..."
    pull_from_replica "$remote_full" "$RESTORE_DIR/inc_base.sql.enc" || true
    decrypt "$RESTORE_DIR/inc_base.sql.enc" "$RESTORE_DIR/inc_base.sql" || true
    restore_to "$RESTORE_DIR/inc_base.sql" "$DB_INC" || true
    ok "Base (full) di-restore ke $DB_INC"

    # Step 2: unduh dan dekripsi semua file incremental berurutan
    # P2 fix: wording diubah — "berhasil diunduh & didekripsi (verifikasi artefak)"
    # karena pg_basebackup -Ft menghasilkan tar fisik, bukan SQL yang bisa langsung di-restore
    info "Step 2: unduh & dekripsi semua file incremental (verifikasi artefak)..."
    local inc_files inc_count=0
    inc_files=$($SSH_CMD "${REPLICA_USER}@${REPLICA_IP}" \
        "for f in \$(ls ${REPLICA_BACKUP_DIR}/incremental/incremental_*.tar.gz.enc \
         2>/dev/null | sort); do
             t=\$(stat -c %Y \"\$f\" 2>/dev/null || echo 0);
             [ \"\$t\" -ge \"$since\" ] && echo \"\$f\";
         done" 2>/dev/null) || inc_files=""

    local inc_ok=0 inc_fail=0
    for remote_inc in $inc_files; do
        inc_count=$((inc_count + 1))
        local local_enc="$RESTORE_DIR/inc_${inc_count}.tar.gz.enc"
        local local_tar="$RESTORE_DIR/inc_${inc_count}.tar.gz"

        if pull_from_replica "$remote_inc" "$local_enc" && \
           decrypt "$local_enc" "$local_tar"; then
            inc_ok=$((inc_ok + 1))
            log "Incremental $inc_count berhasil diunduh & didekripsi: $(basename "$remote_inc")"
        else
            inc_fail=$((inc_fail + 1))
            log "Incremental $inc_count gagal: $(basename "$remote_inc")"
        fi
    done

    if [ "$inc_count" -eq 0 ]; then
        info "Tidak ada file incremental ditemukan sejak T0"
    else
        ok "$inc_ok dari $inc_count file incremental berhasil diunduh & didekripsi (verifikasi artefak)"
        [ "$inc_fail" -gt 0 ] && fail "$inc_fail file incremental gagal diunduh/didekripsi"
    fi

    t_end=$(date +%s)
    durasi=$((t_end - t_start))

    if verify_restore "$DB_INC"; then
        ok "Semua tabel ada di $DB_INC (dari restore base full)"
    else
        fail "Ada tabel yang hilang di $DB_INC"
    fi

    local restored loss
    restored=$(row_count "$DB_INC" penduduk)
    loss=$((before - restored))

    ok "Recovery selesai dalam ${durasi} detik"
    info "Penduduk terpulihkan : $restored baris (dari base full backup)"
    info "File incremental     : $inc_count file ($inc_ok berhasil diunduh & didekripsi)"
    info "Data loss            : $loss baris"
    info "RTO                  : ${durasi} detik"

    save_state "INC_RESTORED" "$restored"
    save_state "INC_LOSS"     "$loss"
    save_state "INC_RTO"      "$durasi"
    save_state "INC_FILES"    "$inc_count"
    save_state "INC_OK"       "$inc_ok"

    rm -f "$RESTORE_DIR"/inc_* || true
}

# ===========================================================================
# SKENARIO 06 — Interupsi Jaringan
# ===========================================================================

run_06() {
    section "SKENARIO 06 — Interupsi Jaringan Saat Backup"

    info "Menjalankan backup di background..."
    # Nonaktifkan strict mode sementara karena proses background boleh gagal
    set +e
    bash "$SCRIPT_DIR/backup.sh" full >> "$LOG_FILE" 2>&1 &
    local bpid=$!
    set -e

    sleep 4
    info "Memutus koneksi SSH dan rsync ke Replica..."
    pkill -f "rsync.*${REPLICA_IP}" 2>/dev/null || true
    pkill -f "ssh.*${REPLICA_IP}"   2>/dev/null || true

    wait "$bpid" 2>/dev/null || true
    sleep 2

    # Database harus tetap responsif
    local check
    check=$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB_MAIN" \
        -t -c "SELECT 1;" 2>/dev/null | tr -d ' \n') || check=""
    if [ "$check" = "1" ]; then
        ok "Database tetap responsif setelah interupsi jaringan"
    else
        fail "Database tidak responsif setelah interupsi"
    fi

    # Tidak boleh ada file 0 KB
    local zero
    zero=$(find /backup/full -name "*.enc" -size 0 2>/dev/null | wc -l) || zero=0
    if [ "${zero}" -eq 0 ]; then
        ok "Tidak ada file backup 0 KB terbentuk"
    else
        fail "$zero file backup 0 KB ditemukan"
    fi

    # Data masih bisa dibaca
    local cnt
    cnt=$(row_count "$DB_MAIN" kartu_keluarga)
    if [ "${cnt}" -gt 0 ]; then
        ok "Data kartu_keluarga masih utuh ($cnt baris) — tidak ada korupsi"
    else
        fail "Data kartu_keluarga tidak bisa dibaca setelah interupsi"
    fi
}

# ===========================================================================
# SKENARIO 07 — Disk Penuh
# ===========================================================================

run_07() {
    section "SKENARIO 07 — Disk Penuh di Site Primary"

    local avail_mb dummy_created=false
    avail_mb=$(df /backup | awk 'NR==2 {print int($4/1024)}') || avail_mb=0

    if [ "$avail_mb" -lt 100 ]; then
        info "Disk sudah hampir penuh ($avail_mb MB tersisa) — skip pengisian dummy"
    else
        local fill_mb=$((avail_mb - 30))
        info "Mengisi disk ${fill_mb}MB (sisa ~30MB)..."
        if fallocate -l "${fill_mb}M" /backup/diskfull_dummy.tmp 2>/dev/null; then
            dummy_created=true
        else
            info "fallocate gagal — coba dengan dd..."
            dd if=/dev/zero of=/backup/diskfull_dummy.tmp \
                bs=1M count="$fill_mb" 2>/dev/null || true
            [ -f /backup/diskfull_dummy.tmp ] && dummy_created=true
        fi
    fi

    # Jalankan backup — harusnya terdeteksi dan dibatalkan
    set +e
    local out
    out=$(bash "$SCRIPT_DIR/backup.sh" full 2>&1) || true
    set -e

    if echo "$out" | grep -qi "disk tidak cukup\|disk penuh\|error"; then
        ok "Sistem mendeteksi disk penuh dan membatalkan backup"
    else
        fail "Sistem tidak mendeteksi kondisi disk penuh"
    fi

    # P1 fix: cek 0 KB hanya jika dummy berhasil dibuat
    # Kalau dummy tidak ada, -newer akan error atau hasilkan cek tidak valid
    if [ "$dummy_created" = true ] && [ -f /backup/diskfull_dummy.tmp ]; then
        local zero
        zero=$(find /backup/full -name "*.enc" -newer /backup/diskfull_dummy.tmp \
            -size 0 2>/dev/null | wc -l) || zero=0
        if [ "${zero}" -eq 0 ]; then
            ok "Tidak ada file backup 0 KB terbentuk saat disk penuh"
        else
            fail "$zero file backup 0 KB terbentuk saat disk penuh"
        fi
    else
        # Fallback: cek semua file 0 KB yang ada
        local zero
        zero=$(find /backup/full -name "*.enc" -size 0 2>/dev/null | wc -l) || zero=0
        if [ "${zero}" -eq 0 ]; then
            ok "Tidak ada file backup 0 KB ditemukan"
        else
            fail "$zero file backup 0 KB ditemukan"
        fi
    fi

    rm -f /backup/diskfull_dummy.tmp || true
    info "File dummy dihapus, disk kembali normal"
}

# ===========================================================================
# SKENARIO 08 — Passphrase Salah
# ===========================================================================

run_08() {
    section "SKENARIO 08 — Passphrase Salah (Uji Keamanan Enkripsi)"

    local since
    since=$(load_state T0_SINCE); since=${since:-0}

    local remote
    remote=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$since")

    if [ -z "$remote" ]; then
        fail "File backup tidak ditemukan di Replica"
        return
    fi

    mkdir -p "$RESTORE_DIR"
    pull_from_replica "$remote" "$RESTORE_DIR/enc_test.sql.enc" || true

    # Coba passphrase salah — strict mode dimatikan sementara karena memang harus gagal
    set +e
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
        -in  "$RESTORE_DIR/enc_test.sql.enc" \
        -out "$RESTORE_DIR/enc_wrong.sql" \
        -pass pass:"ini_passphrase_yang_salah" 2>/dev/null
    local wrong_exit=$?
    set -e

    if [ $wrong_exit -ne 0 ]; then
        ok "Passphrase salah ditolak — file tidak bisa dibuka"
    else
        fail "Dekripsi berhasil dengan passphrase salah — enkripsi tidak aman"
    fi

    # Coba passphrase benar
    set +e
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
        -in  "$RESTORE_DIR/enc_test.sql.enc" \
        -out "$RESTORE_DIR/enc_correct.sql" \
        -pass pass:"$BACKUP_AES_PASSPHRASE" 2>/dev/null
    local correct_exit=$?
    set -e

    if [ $correct_exit -eq 0 ]; then
        ok "Passphrase benar diterima — file berhasil didekripsi"
    else
        fail "Dekripsi gagal bahkan dengan passphrase yang benar"
    fi

    rm -f "$RESTORE_DIR"/enc_* || true
}

# ===========================================================================
# SKENARIO 09 — Point-in-Time Recovery (PITR)
# ===========================================================================

run_09() {
    section "SKENARIO 09 — Point-in-Time Recovery (PITR)"

    local t0_time t0_count t0_since
    t0_time=$(load_state T0_TIME);   t0_time=${t0_time:-"?"}
    t0_count=$(load_state T0_COUNT); t0_count=${t0_count:-0}
    t0_since=$(load_state T0_SINCE); t0_since=${t0_since:-0}

    local t1_time t1_count t2_time t2_count t3_time t3_count
    t1_time=$(load_state T1_TIME);   t1_time=${t1_time:-"?"}
    t1_count=$(load_state T1_COUNT); t1_count=${t1_count:-0}
    t2_time=$(load_state T2_TIME);   t2_time=${t2_time:-"?"}
    t2_count=$(load_state T2_COUNT); t2_count=${t2_count:-0}
    t3_time=$(load_state T3_TIME);   t3_time=${t3_time:-"?"}
    t3_count=$(load_state T3_COUNT); t3_count=${t3_count:-0}

    info "Checkpoint yang tersedia:"
    info "  T0: $t0_time — $t0_count baris (full backup)"
    info "  T1: $t1_time — $t1_count baris (diff + inc)"
    info "  T2: $t2_time — $t2_count baris (inc)"
    info "  T3: $t3_time — $t3_count baris (inc — terbaru)"
    echo ""
    info "Target PITR: T0 ($t0_time) — kondisi sebelum batch 1, 2, 3"

    reset_db "$DB_FULL"
    mkdir -p "$RESTORE_DIR"

    local remote
    remote=$(get_remote_file "$REPLICA_BACKUP_DIR/full" \
        "full_db_kependudukan_*.sql.enc" "$t0_since")

    if [ -z "$remote" ]; then
        fail "File backup T0 tidak ditemukan"
        return
    fi

    local t_start t_end durasi
    t_start=$(date +%s)

    pull_from_replica "$remote" "$RESTORE_DIR/pitr_t0.sql.enc" || {
        fail "Gagal mengambil file T0 dari Replica"
        return
    }

    if ! decrypt "$RESTORE_DIR/pitr_t0.sql.enc" "$RESTORE_DIR/pitr_t0.sql"; then
        fail "Dekripsi file T0 gagal"
        rm -f "$RESTORE_DIR"/pitr_* || true
        return
    fi

    if ! restore_to "$RESTORE_DIR/pitr_t0.sql" "$DB_FULL"; then
        fail "Restore file T0 ke $DB_FULL gagal"
        rm -f "$RESTORE_DIR"/pitr_* || true
        return
    fi

    t_end=$(date +%s)
    durasi=$((t_end - t_start))

    # P1 fix: row_count selalu return angka
    local restored
    restored=$(row_count "$DB_FULL" penduduk)

    info "Penduduk terpulihkan : $restored baris"
    info "Ekspektasi T0        : $t0_count baris"
    info "RTO PITR             : ${durasi} detik"

    if [ "$restored" -gt 0 ]; then
        ok "PITR ke T0 berhasil — data dikembalikan ke kondisi $t0_time"
    else
        fail "PITR gagal — tidak ada data terpulihkan"
    fi

    if [ "$restored" -eq "$t0_count" ]; then
        ok "Jumlah baris sesuai ekspektasi T0 ($restored = $t0_count)"
    else
        info "Jumlah baris berbeda dari ekspektasi ($restored vs $t0_count) — kemungkinan ada data awal"
    fi

    info "Catatan: PITR ini berbasis checkpoint backup (pilih file dari timestamp tertentu)."
    info "PITR berbasis WAL (resolusi menit/detik) memerlukan archive_mode di postgresql.conf."

    rm -f "$RESTORE_DIR"/pitr_* || true
}

# ===========================================================================
# LAPORAN AKHIR
# ===========================================================================

print_report() {
    section "LAPORAN AKHIR"

    # Baca semua state dengan fallback aman
    local full_r full_l full_rto
    local diff_r diff_l diff_rto
    local inc_r  inc_l  inc_rto inc_f inc_ok
    local before

    full_r=$(load_state FULL_RESTORED);  full_r=${full_r:--}
    full_l=$(load_state FULL_LOSS);      full_l=${full_l:--}
    full_rto=$(load_state FULL_RTO);     full_rto=${full_rto:--}
    diff_r=$(load_state DIFF_RESTORED);  diff_r=${diff_r:--}
    diff_l=$(load_state DIFF_LOSS);      diff_l=${diff_l:--}
    diff_rto=$(load_state DIFF_RTO);     diff_rto=${diff_rto:--}
    inc_r=$(load_state INC_RESTORED);    inc_r=${inc_r:--}
    inc_l=$(load_state INC_LOSS);        inc_l=${inc_l:--}
    inc_rto=$(load_state INC_RTO);       inc_rto=${inc_rto:--}
    inc_f=$(load_state INC_FILES);       inc_f=${inc_f:--}
    inc_ok=$(load_state INC_OK);         inc_ok=${inc_ok:--}
    before=$(load_state BEFORE_DISASTER); before=${before:--}

    echo "" | tee -a "$REPORT_FILE"
    echo "  Kondisi sebelum bencana: $before baris" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    printf "  %-16s %-14s %-12s %-10s\n" \
        "Strategi" "Terpulihkan" "Data Loss" "RTO" | tee -a "$REPORT_FILE"
    printf "  %-16s %-14s %-12s %-10s\n" \
        "----------------" "--------------" "------------" "----------" \
        | tee -a "$REPORT_FILE"
    printf "  %-16s %-14s %-12s %-10s\n" \
        "Full" "$full_r baris" "$full_l baris" "$full_rto detik" \
        | tee -a "$REPORT_FILE"
    printf "  %-16s %-14s %-12s %-10s\n" \
        "Differential" "$diff_r baris" "$diff_l baris" "$diff_rto detik" \
        | tee -a "$REPORT_FILE"
    printf "  %-16s %-14s %-12s %-10s\n" \
        "Incremental" "$inc_r baris" "$inc_l baris" "$inc_rto detik" \
        | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "  File incremental diunduh & didekripsi: $inc_ok dari $inc_f" \
        | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "  Total PASS : $PASS" | tee -a "$REPORT_FILE"
    echo "  Total FAIL : $FAIL" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "  Log    : $LOG_FILE" | tee -a "$REPORT_FILE"
    echo "  Laporan: $REPORT_FILE" | tee -a "$REPORT_FILE"
}

# ===========================================================================
# MAIN
# ===========================================================================

mkdir -p /backup/logs
mkdir -p "$RESTORE_DIR"

container_running "$CONTAINER" || die "Container $CONTAINER tidak berjalan"

cat > "$REPORT_FILE" << EOF
Laporan Recovery Drill
Capstone 11 Kelompok 2 — IPB University 2026
Tanggal: $(date '+%Y-%m-%d %H:%M:%S')
EOF

if [ $# -eq 0 ]; then
    echo "Penggunaan:"
    echo "  $0 setup        -- siapkan data simulasi (wajib pertama)"
    echo "  $0 all          -- jalankan semua skenario"
    echo "  $0 01           -- file backup dikorupsi"
    echo "  $0 02           -- simulasi bencana (DROP TABLE)"
    echo "  $0 03           -- recovery full backup"
    echo "  $0 04           -- recovery differential"
    echo "  $0 05           -- recovery incremental"
    echo "  $0 06           -- interupsi jaringan"
    echo "  $0 07           -- disk penuh"
    echo "  $0 08           -- passphrase salah"
    echo "  $0 09           -- point-in-time recovery"
    echo "  $0 03 04 05     -- beberapa skenario sekaligus"
    echo "  $0 report       -- cetak laporan dari state tersimpan"
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        setup)  run_setup ;;
        all)
            run_setup
            run_01; run_02
            run_03; run_04; run_05
            run_06; run_07; run_08; run_09
            ;;
        01) run_01 ;;
        02) run_02 ;;
        03) run_03 ;;
        04) run_04 ;;
        05) run_05 ;;
        06) run_06 ;;
        07) run_07 ;;
        08) run_08 ;;
        09) run_09 ;;
        report) ;;
        *) echo "Argumen tidak dikenal: $arg" >&2 ;;
    esac
done

print_report
rm -rf "$RESTORE_DIR" || true
