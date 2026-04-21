#!/bin/bash

source .env

echo "================================================"
echo " Menunggu PostgreSQL siap..."
echo "================================================"
sleep 5

echo ""
echo "================================================"
echo " Reset semua tabel (jika ada data sebelumnya)"
echo "================================================"
docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'
DROP TABLE IF EXISTS bansos_umkm;
DROP TABLE IF EXISTS bpjs_kesehatan;
DROP TABLE IF EXISTS layanan_publik;
DROP TABLE IF EXISTS penduduk;
DROP TABLE IF EXISTS kartu_keluarga;
DROP TABLE IF EXISTS instansi;
DROP TABLE IF EXISTS staging_csv;
SQL

echo ""
echo "================================================"
echo " Membuat database tambahan"
echo "================================================"
docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'
CREATE DATABASE db_full;
CREATE DATABASE db_inc;
CREATE DATABASE db_diff;
SQL

echo ""
echo "================================================"
echo " Membuat tabel utama"
echo "================================================"
docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'

CREATE TABLE IF NOT EXISTS instansi (
    kode_instansi   VARCHAR(20) PRIMARY KEY,
    nama_instansi   VARCHAR(100),
    provinsi        VARCHAR(50),
    id_ddp          VARCHAR(20),
    kode_sds        VARCHAR(20),
    definisi        TEXT,
    satuan          VARCHAR(30)
);

CREATE TABLE IF NOT EXISTS kartu_keluarga (
    no_kk           VARCHAR(16) PRIMARY KEY,
    nik_kepala      VARCHAR(16),
    provinsi        VARCHAR(50),
    kota_kabupaten  VARCHAR(50),
    kecamatan       VARCHAR(50),
    kelurahan_desa  VARCHAR(50),
    rt              VARCHAR(5),
    rw              VARCHAR(5),
    kode_pos        VARCHAR(10)
);

CREATE TABLE IF NOT EXISTS penduduk (
    nik                 VARCHAR(16) PRIMARY KEY,
    no_kk               VARCHAR(16) REFERENCES kartu_keluarga(no_kk),
    nama_lengkap        VARCHAR(100),
    jenis_kelamin       CHAR(1),
    tempat_lahir        VARCHAR(50),
    tanggal_lahir       DATE,
    umur                INT,
    agama               VARCHAR(20),
    status_perkawinan   VARCHAR(20),
    golongan_darah      VARCHAR(3),
    pendidikan_terakhir VARCHAR(30),
    pekerjaan           VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS layanan_publik (
    id_layanan          VARCHAR(30) PRIMARY KEY,
    nik                 VARCHAR(16) REFERENCES penduduk(nik),
    nama_ddp            VARCHAR(100),
    sumber_referensi    VARCHAR(100),
    tahun_tersedia      INT,
    status_record       VARCHAR(20),
    tanggal_input       DATE,
    tanggal_update      DATE
);

CREATE TABLE IF NOT EXISTS bpjs_kesehatan (
    id_bpjs                 VARCHAR(30) PRIMARY KEY,
    nik                     VARCHAR(16) REFERENCES penduduk(nik),
    kode_sds                VARCHAR(20),
    versi_sds               VARCHAR(10),
    klasifikasi_penyajian   VARCHAR(50),
    metode                  VARCHAR(30),
    status_record           VARCHAR(20)
);

CREATE TABLE IF NOT EXISTS bansos_umkm (
    id_bansos           VARCHAR(30) PRIMARY KEY,
    nik                 VARCHAR(16) REFERENCES penduduk(nik),
    nama_ddp            VARCHAR(100),
    sumber_referensi    VARCHAR(100),
    kode_referensi      VARCHAR(20),
    status_record       VARCHAR(20),
    tanggal_input       DATE
);

CREATE TABLE IF NOT EXISTS staging_csv (
    nik                     VARCHAR(30),
    no_kk                   VARCHAR(30),
    nama_lengkap            VARCHAR(100),
    jenis_kelamin           VARCHAR(20),
    tempat_lahir            VARCHAR(50),
    tanggal_lahir           VARCHAR(20),
    umur                    VARCHAR(10),
    agama                   VARCHAR(20),
    status_perkawinan       VARCHAR(30),
    golongan_darah          VARCHAR(5),
    pendidikan_terakhir     VARCHAR(30),
    pekerjaan               VARCHAR(50),
    provinsi                VARCHAR(50),
    kota_kabupaten          VARCHAR(50),
    kecamatan               VARCHAR(50),
    kelurahan_desa          VARCHAR(50),
    rt                      VARCHAR(5),
    rw                      VARCHAR(5),
    kode_pos                VARCHAR(10),
    kode_instansi           VARCHAR(20),
    nama_instansi           VARCHAR(100),
    id_ddp                  VARCHAR(20),
    nama_ddp                VARCHAR(100),
    sumber_referensi        VARCHAR(100),
    tahun_tersedia          VARCHAR(10),
    kode_sds                VARCHAR(20),
    type_sds                VARCHAR(20),
    versi_sds               VARCHAR(10),
    definisi                TEXT,
    ukuran                  VARCHAR(20),
    satuan                  VARCHAR(30),
    klasifikasi_penyajian   VARCHAR(50),
    kode_referensi          VARCHAR(20),
    versi_kode_referensi    VARCHAR(10),
    metode                  VARCHAR(30),
    status_record           VARCHAR(20),
    tanggal_input           VARCHAR(20),
    tanggal_update          VARCHAR(20),
    checksum_md5            VARCHAR(32)
);

SQL

echo ""
echo "================================================"
echo " Mengecek apakah ada file CSV untuk diimport"
echo "================================================"
if [ -f ~/pg-setup/data.csv ]; then
    echo "File CSV ditemukan, mengimport..."

    docker cp ~/pg-setup/data.csv pg-primary:/tmp/data.csv

    docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB -c "\COPY staging_csv FROM '/tmp/data.csv' CSV HEADER;"

    echo ""
    echo "Total baris masuk ke staging:"
    docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT COUNT(*) AS total_staging FROM staging_csv;"

    echo ""
    echo "================================================"
    echo " Transform: memindahkan data ke tabel asli"
    echo "================================================"
    docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'

    CREATE OR REPLACE FUNCTION parse_date(d TEXT) RETURNS DATE AS $$
    BEGIN
        IF d IS NULL OR d = '' THEN RETURN NULL; END IF;
        IF d ~ '^\d{4}-\d{2}-\d{2}$' THEN
            RETURN d::DATE;
        ELSIF d ~ '^\d{1,2}/\d{1,2}/\d{4}$' THEN
            RETURN TO_DATE(d, 'MM/DD/YYYY');
        ELSE
            RETURN NULL;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;

    INSERT INTO instansi (kode_instansi, nama_instansi, provinsi, id_ddp, kode_sds, definisi, satuan)
    SELECT DISTINCT ON (TRIM(kode_instansi))
        TRIM(kode_instansi),
        TRIM(nama_instansi),
        TRIM(provinsi),
        TRIM(id_ddp),
        TRIM(kode_sds),
        TRIM(definisi),
        TRIM(satuan)
    FROM staging_csv
    WHERE kode_instansi IS NOT NULL AND TRIM(kode_instansi) != ''
    ON CONFLICT (kode_instansi) DO NOTHING;

    INSERT INTO kartu_keluarga (no_kk, nik_kepala, provinsi, kota_kabupaten, kecamatan, kelurahan_desa, rt, rw, kode_pos)
    SELECT DISTINCT ON (clean_no_kk)
        clean_no_kk,
        clean_no_kk,
        TRIM(provinsi),
        TRIM(kota_kabupaten),
        TRIM(kecamatan),
        TRIM(kelurahan_desa),
        TRIM(rt),
        TRIM(rw),
        TRIM(kode_pos)
    FROM (
        SELECT *,
            SUBSTRING(REGEXP_REPLACE(TRIM(no_kk), '\.0+$', ''), 1, 16) AS clean_no_kk
        FROM staging_csv
        WHERE no_kk IS NOT NULL AND TRIM(no_kk) != ''
    ) t
    ON CONFLICT (no_kk) DO NOTHING;

    INSERT INTO penduduk (nik, no_kk, nama_lengkap, jenis_kelamin, tempat_lahir, tanggal_lahir, umur, agama, status_perkawinan, golongan_darah, pendidikan_terakhir, pekerjaan)
    SELECT DISTINCT ON (clean_nik)
        clean_nik,
        clean_no_kk,
        TRIM(nama_lengkap),
        CASE TRIM(jenis_kelamin)
            WHEN 'Laki-laki' THEN 'L'
            WHEN 'Perempuan' THEN 'P'
            ELSE 'L'
        END,
        TRIM(tempat_lahir),
        parse_date(tanggal_lahir),
        CASE WHEN umur ~ '^\d+$' THEN umur::INT ELSE NULL END,
        TRIM(agama),
        TRIM(status_perkawinan),
        TRIM(golongan_darah),
        TRIM(pendidikan_terakhir),
        TRIM(pekerjaan)
    FROM (
        SELECT *,
            SUBSTRING(REGEXP_REPLACE(TRIM(nik), '\.0+$', ''), 1, 16) AS clean_nik,
            SUBSTRING(REGEXP_REPLACE(TRIM(no_kk), '\.0+$', ''), 1, 16) AS clean_no_kk
        FROM staging_csv
        WHERE nik IS NOT NULL AND TRIM(nik) != ''
    ) t
    WHERE clean_no_kk IN (SELECT no_kk FROM kartu_keluarga)
    ON CONFLICT (nik) DO NOTHING;

    INSERT INTO layanan_publik (id_layanan, nik, nama_ddp, sumber_referensi, tahun_tersedia, status_record, tanggal_input, tanggal_update)
    SELECT
        'LAY-' || ROW_NUMBER() OVER (ORDER BY nik),
        clean_nik,
        TRIM(nama_ddp),
        TRIM(sumber_referensi),
        CASE WHEN tahun_tersedia ~ '^\d+$' THEN tahun_tersedia::INT ELSE NULL END,
        TRIM(status_record),
        parse_date(tanggal_input),
        parse_date(tanggal_update)
    FROM (
        SELECT *,
            SUBSTRING(REGEXP_REPLACE(TRIM(nik), '\.0+$', ''), 1, 16) AS clean_nik
        FROM staging_csv
        WHERE nik IS NOT NULL AND TRIM(nik) != ''
    ) t
    WHERE clean_nik IN (SELECT nik FROM penduduk);

    INSERT INTO bpjs_kesehatan (id_bpjs, nik, kode_sds, versi_sds, klasifikasi_penyajian, metode, status_record)
    SELECT
        'BPJS-' || ROW_NUMBER() OVER (ORDER BY nik),
        clean_nik,
        TRIM(kode_sds),
        TRIM(versi_sds),
        TRIM(klasifikasi_penyajian),
        TRIM(metode),
        TRIM(status_record)
    FROM (
        SELECT *,
            SUBSTRING(REGEXP_REPLACE(TRIM(nik), '\.0+$', ''), 1, 16) AS clean_nik
        FROM staging_csv
        WHERE nik IS NOT NULL AND TRIM(nik) != ''
    ) t
    WHERE clean_nik IN (SELECT nik FROM penduduk);

    INSERT INTO bansos_umkm (id_bansos, nik, nama_ddp, sumber_referensi, kode_referensi, status_record, tanggal_input)
    SELECT
        'BNS-' || ROW_NUMBER() OVER (ORDER BY nik),
        clean_nik,
        TRIM(nama_ddp),
        TRIM(sumber_referensi),
        TRIM(kode_referensi),
        TRIM(status_record),
        parse_date(tanggal_input)
    FROM (
        SELECT *,
            SUBSTRING(REGEXP_REPLACE(TRIM(nik), '\.0+$', ''), 1, 16) AS clean_nik
        FROM staging_csv
        WHERE nik IS NOT NULL AND TRIM(nik) != ''
    ) t
    WHERE clean_nik IN (SELECT nik FROM penduduk);

SQL

    echo ""
    echo "================================================"
    echo " Truncate staging (tabel tetap ada, data dihapus)"
    echo "================================================"
    docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB -c "TRUNCATE TABLE staging_csv;"
    echo "Staging berhasil dikosongkan."

else
    echo "File CSV tidak ditemukan di ~/pg-setup/data.csv"
    echo "Mengisi dummy data saja..."

    docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'

    INSERT INTO instansi (kode_instansi, nama_instansi, provinsi, id_ddp, kode_sds, definisi, satuan)
    SELECT
        'INST' || LPAD(n::TEXT, 4, '0'),
        (ARRAY['Diskominfo','Dinkes','Disduk','BPJS','Kemensos'])[floor(random()*5+1)] || ' ' || n,
        (ARRAY['Jawa Barat','DKI Jakarta','Jawa Tengah','Banten'])[floor(random()*4+1)],
        'DDP' || n,
        'SDS' || (n % 10 + 1),
        'Instansi pemerintah nomor ' || n,
        'Unit'
    FROM generate_series(1, 50) AS n;

    INSERT INTO kartu_keluarga (no_kk, nik_kepala, provinsi, kota_kabupaten, kecamatan, kelurahan_desa, rt, rw, kode_pos)
    SELECT
        LPAD((3200000000000000 + n)::TEXT, 16, '0'),
        LPAD((3200000000000000 + n)::TEXT, 16, '0'),
        'Jawa Barat',
        (ARRAY['Bogor','Depok','Bekasi','Bandung'])[floor(random()*4+1)],
        'Kecamatan ' || (n % 10 + 1),
        'Kelurahan ' || (n % 20 + 1),
        LPAD((n % 15 + 1)::TEXT, 3, '0'),
        LPAD((n % 10 + 1)::TEXT, 3, '0'),
        '161' || LPAD((n % 100)::TEXT, 2, '0')
    FROM generate_series(1, 10000) AS n;

    INSERT INTO penduduk (nik, no_kk, nama_lengkap, jenis_kelamin, tempat_lahir, tanggal_lahir, umur, agama, status_perkawinan, golongan_darah, pendidikan_terakhir, pekerjaan)
    SELECT
        LPAD((3200000000000000 + n)::TEXT, 16, '0'),
        LPAD((3200000000000000 + n)::TEXT, 16, '0'),
        'Penduduk ' || n,
        (ARRAY['L','P'])[floor(random()*2+1)],
        (ARRAY['Bogor','Jakarta','Bandung','Depok','Bekasi'])[floor(random()*5+1)],
        ('1960-01-01'::DATE + (random()*22000)::INT),
        (EXTRACT(YEAR FROM NOW()) - EXTRACT(YEAR FROM ('1960-01-01'::DATE + (random()*22000)::INT)))::INT,
        (ARRAY['Islam','Kristen','Katolik','Hindu','Buddha'])[floor(random()*5+1)],
        (ARRAY['Belum Kawin','Kawin','Cerai Hidup','Cerai Mati'])[floor(random()*4+1)],
        (ARRAY['A','B','AB','O'])[floor(random()*4+1)],
        (ARRAY['SD','SMP','SMA','D3','S1','S2'])[floor(random()*6+1)],
        (ARRAY['PNS','Swasta','Wiraswasta','Petani','Tidak Bekerja'])[floor(random()*5+1)]
    FROM generate_series(1, 10000) AS n;

    INSERT INTO bpjs_kesehatan (id_bpjs, nik, kode_sds, versi_sds, klasifikasi_penyajian, metode, status_record)
    SELECT
        'BPJS' || LPAD(n::TEXT, 8, '0'),
        LPAD((3200000000000000 + n)::TEXT, 16, '0'),
        'SDS' || (n % 10 + 1),
        'v' || (n % 3 + 1) || '.0',
        (ARRAY['Individu','Agregat','Sampel'])[floor(random()*3+1)],
        (ARRAY['Sensus','Survei','Registrasi'])[floor(random()*3+1)],
        (ARRAY['Aktif','Nonaktif'])[floor(random()*2+1)]
    FROM generate_series(1, 10000) AS n;

    INSERT INTO layanan_publik (id_layanan, nik, nama_ddp, sumber_referensi, tahun_tersedia, status_record, tanggal_input, tanggal_update)
    SELECT
        'LAY' || LPAD(n::TEXT, 8, '0'),
        LPAD((3200000000000000 + (n % 10000 + 1))::TEXT, 16, '0'),
        (ARRAY['Pembuatan KTP','Akta Lahir','Kartu Keluarga','SIM','SKCK'])[floor(random()*5+1)],
        (ARRAY['Kemendagri','Disdukcapil','Polri'])[floor(random()*3+1)],
        2020 + (n % 5),
        (ARRAY['Aktif','Selesai','Proses'])[floor(random()*3+1)],
        NOW() - (random()*365)::INT * INTERVAL '1 day',
        NOW() - (random()*30)::INT * INTERVAL '1 day'
    FROM generate_series(1, 15000) AS n;

    INSERT INTO bansos_umkm (id_bansos, nik, nama_ddp, sumber_referensi, kode_referensi, status_record, tanggal_input)
    SELECT
        'BNS' || LPAD(n::TEXT, 8, '0'),
        LPAD((3200000000000000 + (n % 10000 + 1))::TEXT, 16, '0'),
        (ARRAY['BLT 2024','KUR Mikro','PKH','BPNT','Bansos Covid'])[floor(random()*5+1)],
        (ARRAY['Kemensos','Kemenkop','BI','BRI'])[floor(random()*4+1)],
        'REF' || LPAD(n::TEXT, 6, '0'),
        (ARRAY['Aktif','Selesai','Ditolak'])[floor(random()*3+1)],
        NOW() - (random()*365)::INT * INTERVAL '1 day'
    FROM generate_series(1, 12000) AS n;

SQL
fi

echo ""
echo "================================================"
echo " Verifikasi jumlah data"
echo "================================================"
docker exec -i pg-primary psql -U $POSTGRES_USER -d $POSTGRES_DB << 'SQL'
SELECT 'instansi'               AS tabel, COUNT(*) AS jumlah FROM instansi
UNION ALL
SELECT 'kartu_keluarga',                   COUNT(*) FROM kartu_keluarga
UNION ALL
SELECT 'penduduk',                         COUNT(*) FROM penduduk
UNION ALL
SELECT 'bpjs_kesehatan',                   COUNT(*) FROM bpjs_kesehatan
UNION ALL
SELECT 'layanan_publik',                   COUNT(*) FROM layanan_publik
UNION ALL
SELECT 'bansos_umkm',                      COUNT(*) FROM bansos_umkm
UNION ALL
SELECT 'staging_csv (harus 0)',            COUNT(*) FROM staging_csv;
SQL

echo ""
echo "================================================"
echo " Selesai! Database siap digunakan."
echo "================================================"
