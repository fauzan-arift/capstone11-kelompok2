#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
LOG_DIR="/backup/logs"

echo "================================================"
echo " SETUP CRON JOB BACKUP OTOMATIS"
echo "================================================"

# Pastikan backup.sh executable
chmod +x "$BACKUP_SCRIPT"
echo "backup.sh sudah executable."

# Buat direktori log
mkdir -p "$LOG_DIR"

# Buat cron job baru
crontab -l > /tmp/crontab_backup_$(date +%Y%m%d) 2>/dev/null
echo "Crontab lama di-backup ke /tmp/"

# Hapus cron backup lama jika ada, lalu tambahkan yang baru
(crontab -l 2>/dev/null | grep -v "backup.sh"; cat <<EOF

# Full backup — setiap Minggu jam 01:00
0 1 * * 0 $BACKUP_SCRIPT full >> $LOG_DIR/cron_full.log 2>&1

# Incremental backup — setiap hari Senin-Sabtu jam 02:00
0 2 * * 1-6 $BACKUP_SCRIPT incremental >> $LOG_DIR/cron_incremental.log 2>&1

# Differential backup — setiap hari Senin-Sabtu jam 03:00
0 3 * * 1-6 $BACKUP_SCRIPT differential >> $LOG_DIR/cron_differential.log 2>&1

EOF
) | crontab -

echo ""
echo "Cron job berhasil ditambahkan:"
echo ""
crontab -l | grep -A1 "Capstone"
echo ""
crontab -l | grep "backup.sh"

echo "================================================"
echo " SETUP CRON SELESAI"
echo "================================================"
