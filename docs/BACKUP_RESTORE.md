# Backup & Restore Guide

Comprehensive backup and restoration procedures for your Matrix and PieFed deployment.

## Overview

The deployment creates automated, encrypted backups of:
- **Database dumps** (PostgreSQL data)
- **Data directories** (user content, media, configuration)
- **Application logs** (encrypted log files)
- **Secrets** (environment variables, keys)

All backups are encrypted using GPG AES256 encryption.

## Backup Strategy

### What Gets Backed Up

#### Matrix Synapse
- PostgreSQL database (`synapse` database)
- Data directory (`~/containers/matrix/data/`)
  - Homeserver configuration
  - Media repository
  - Log files
  - Redis data
- Secrets file (`~/.local/share/homodeus-secrets/matrix.env`)

#### PieFed
- PostgreSQL database (`piefed` database)
- Data directory (`~/containers/piefed/data/`)
  - Media uploads
  - Static files
  - Redis data
- Secrets file (`~/.local/share/homodeus-secrets/piefed.env`)

#### System Configuration
- Log encryption key (`~/.local/share/homodeus-secrets/.log_key`)
- All encrypted logs
- Container configurations (`compose.yml` files)

### Backup Location
- **Local backups**: `~/backups/`
- **Naming format**: `service_type_YYYYMMDD_HHMMSS.ext.gpg`

Examples:
```
matrix_db_20241007_020000.sql.gz.gpg
matrix_data_20241007_020000.tar.gz.gpg
piefed_db_20241007_020000.sql.gz.gpg
secrets_20241007_020000.tar.gz.gpg
```

## Manual Backup

### Interactive Backup
```bash
# Run the backup script (prompts for encryption password)
~/containers/backup.sh
```

### Scripted Backup
```bash
# Set encryption password in environment
export BACKUP_PASSWORD="your-secure-password"

# Run backup script non-interactively
echo "$BACKUP_PASSWORD" | ~/containers/backup.sh
```

### Individual Service Backup

#### Matrix Only
```bash
cd ~/containers/matrix

# Database backup
DB_PASS=$(grep MATRIX_POSTGRES_PASSWORD ~/.local/share/homodeus-secrets/matrix.env | cut -d= -f2)
podman-compose exec -T postgres \
    bash -c "PGPASSWORD='${DB_PASS}' pg_dump -U synapse synapse" | \
    gzip | \
    gpg --batch --yes --passphrase "your-password" \
    --symmetric --cipher-algo AES256 \
    --output ~/backups/matrix_manual_$(date +%Y%m%d_%H%M%S).sql.gz.gpg

# Data backup
tar czf - data/ | \
    gpg --batch --yes --passphrase "your-password" \
    --symmetric --cipher-algo AES256 \
    --output ~/backups/matrix_data_manual_$(date +%Y%m%d_%H%M%S).tar.gz.gpg
```

#### PieFed Only
```bash
cd ~/containers/piefed

# Database backup
DB_PASS=$(grep PIEFED_POSTGRES_PASSWORD ~/.local/share/homodeus-secrets/piefed.env | cut -d= -f2)
podman-compose exec -T postgres \
    bash -c "PGPASSWORD='${DB_PASS}' pg_dump -U piefed piefed" | \
    gzip | \
    gpg --batch --yes --passphrase "your-password" \
    --symmetric --cipher-algo AES256 \
    --output ~/backups/piefed_manual_$(date +%Y%m%d_%H%M%S).sql.gz.gpg

# Data backup
tar czf - data/ | \
    gpg --batch --yes --passphrase "your-password" \
    --symmetric --cipher-algo AES256 \
    --output ~/backups/piefed_data_manual_$(date +%Y%m%d_%H%M%S).tar.gz.gpg
```

## Automated Backup

### Crontab Configuration
```bash
# Edit crontab
crontab -e

# Add backup schedule (daily at 2 AM)
0 2 * * * ~/containers/backup.sh

# Alternative: Weekly backups on Sundays
0 2 * * 0 ~/containers/backup.sh

# With environment variable for password
0 2 * * * BACKUP_PASSWORD="$(cat ~/.backup_password)" ~/containers/backup.sh
```

### Systemd Timer (Alternative)
```bash
# Create backup service
cat > ~/.config/systemd/user/backup.service << EOF
[Unit]
Description=Homodeus Backup Service

[Service]
Type=oneshot
ExecStart=%h/containers/backup.sh
Environment=BACKUP_PASSWORD=%h/.backup_password
EOF

# Create backup timer
cat > ~/.config/systemd/user/backup.timer << EOF
[Unit]
Description=Daily Homodeus Backup
Requires=backup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable timer
systemctl --user daemon-reload
systemctl --user enable --now backup.timer
```

## Restore Procedures

### Full System Restore

#### 1. Stop Services
```bash
cd ~/containers/matrix && podman-compose down
cd ~/containers/piefed && podman-compose down
```

#### 2. Restore Secrets First
```bash
# Decrypt and restore secrets
gpg --decrypt ~/backups/secrets_YYYYMMDD_HHMMSS.tar.gz.gpg | \
    tar xzf - -C ~/.local/share/homodeus-secrets/
```

#### 3. Restore Data Directories
```bash
# Matrix data restore
cd ~/containers/matrix
rm -rf data/
gpg --decrypt ~/backups/matrix_data_YYYYMMDD_HHMMSS.tar.gz.gpg | tar xzf -

# PieFed data restore
cd ~/containers/piefed
rm -rf data/
gpg --decrypt ~/backups/piefed_data_YYYYMMDD_HHMMSS.tar.gz.gpg | tar xzf -
```

#### 4. Restore Databases
```bash
# Start only database containers
cd ~/containers/matrix
podman-compose up -d postgres
sleep 10

# Restore Matrix database
DB_PASS=$(grep MATRIX_POSTGRES_PASSWORD ~/.local/share/homodeus-secrets/matrix.env | cut -d= -f2)
gpg --decrypt ~/backups/matrix_db_YYYYMMDD_HHMMSS.sql.gz.gpg | \
    gunzip | \
    podman-compose exec -T postgres \
    bash -c "PGPASSWORD='${DB_PASS}' psql -U synapse synapse"

# Repeat for PieFed
cd ~/containers/piefed
podman-compose up -d postgres
sleep 10

DB_PASS=$(grep PIEFED_POSTGRES_PASSWORD ~/.local/share/homodeus-secrets/piefed.env | cut -d= -f2)
gpg --decrypt ~/backups/piefed_db_YYYYMMDD_HHMMSS.sql.gz.gpg | \
    gunzip | \
    podman-compose exec -T postgres \
    bash -c "PGPASSWORD='${DB_PASS}' psql -U piefed piefed"
```

#### 5. Start All Services
```bash
cd ~/containers/matrix && podman-compose up -d
cd ~/containers/piefed && podman-compose up -d
```

### Selective Restore

#### Database Only
```bash
# Stop service
cd ~/containers/matrix && podman-compose stop synapse

# Drop and recreate database
podman-compose exec postgres \
    bash -c "PGPASSWORD='${DB_PASS}' dropdb -U synapse synapse"
podman-compose exec postgres \
    bash -c "PGPASSWORD='${DB_PASS}' createdb -U synapse synapse"

# Restore database
gpg --decrypt ~/backups/matrix_db_YYYYMMDD_HHMMSS.sql.gz.gpg | \
    gunzip | \
    podman-compose exec -T postgres \
    bash -c "PGPASSWORD='${DB_PASS}' psql -U synapse synapse"

# Restart service
podman-compose start synapse
```

#### Media/Data Only
```bash
# Stop service
cd ~/containers/matrix && podman-compose stop synapse

# Backup current data (optional)
mv data/media data/media.backup

# Restore media from backup
mkdir -p data/media
gpg --decrypt ~/backups/matrix_data_YYYYMMDD_HHMMSS.tar.gz.gpg | \
    tar xzf - data/media --strip-components=1

# Restart service
podman-compose start synapse
```

## Remote Backup Storage

### Upload to Remote Storage
```bash
# Example: Upload to remote server via rsync
rsync -avz --progress ~/backups/ user@backup-server:/backups/homodeus/

# Example: Upload to cloud storage (rclone)
rclone copy ~/backups/ remote:homodeus-backups/
```

### Automated Remote Backup
```bash
# Add to backup script or create separate script
cat > ~/containers/remote-backup.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Sync local backups to remote
rsync -avz --delete \
    --include="*.gpg" \
    --exclude="*" \
    ~/backups/ \
    user@backup-server:/backups/homodeus/

echo "Remote backup sync completed"
EOF

chmod +x ~/containers/remote-backup.sh

# Add to crontab after local backup
0 3 * * * ~/containers/remote-backup.sh
```

## Backup Verification

### Test Backup Integrity
```bash
# Verify backup files can be decrypted
for backup in ~/backups/*.gpg; do
    echo "Testing: $backup"
    if gpg --batch --yes --passphrase "your-password" --decrypt "$backup" > /dev/null 2>&1; then
        echo "✓ OK"
    else
        echo "✗ FAILED"
    fi
done
```

### Test Restore Process
```bash
# Create test environment
mkdir -p ~/test-restore/{matrix,piefed}

# Test Matrix data restore
cd ~/test-restore/matrix
gpg --decrypt ~/backups/matrix_data_LATEST.tar.gz.gpg | tar tzf - | head -10

# Test database restore
gpg --decrypt ~/backups/matrix_db_LATEST.sql.gz.gpg | gunzip | head -20
```

## Backup Monitoring

### Backup Status Check
```bash
# Create backup monitoring script
cat > ~/containers/check-backups.sh << 'EOF'
#!/bin/bash

BACKUP_DIR=~/backups
TODAY=$(date +%Y%m%d)
REQUIRED_BACKUPS=("matrix_db" "matrix_data" "piefed_db" "piefed_data" "secrets")

echo "Backup Status Check - $(date)"
echo "=================================="

for backup_type in "${REQUIRED_BACKUPS[@]}"; do
    if ls "$BACKUP_DIR"/${backup_type}_${TODAY}_*.gpg >/dev/null 2>&1; then
        echo "✓ $backup_type - Found"
    else
        echo "✗ $backup_type - Missing"
    fi
done

echo ""
echo "Total backup files: $(ls -1 "$BACKUP_DIR"/*.gpg 2>/dev/null | wc -l)"
echo "Disk usage: $(du -sh "$BACKUP_DIR" | cut -f1)"
EOF

chmod +x ~/containers/check-backups.sh

# Run backup check
~/containers/check-backups.sh
```

### Cleanup Old Backups
```bash
# Manual cleanup (keep 30 days)
find ~/backups -name "*.gpg" -mtime +30 -delete

# Automated cleanup in backup script
cat >> ~/containers/backup.sh << 'EOF'

# Cleanup old backups (keep 30 days)
find "$BACKUP_DIR" -name "*.gpg" -mtime +30 -delete
echo "Old backups cleaned up"
EOF
```

## Disaster Recovery

### Complete Server Rebuild
1. **Fresh server setup**: Run deployment script
2. **Stop new services**: `podman-compose down` in both directories
3. **Copy backup files**: Transfer from remote storage
4. **Restore secrets**: Decrypt and restore secrets first
5. **Restore data**: Follow full restore procedure
6. **Update DNS**: Point domain to new server
7. **Verify services**: Test all functionality

### Recovery Time Objectives (RTO)
- **Matrix**: 30 minutes (database + data restore)
- **PieFed**: 20 minutes (smaller dataset)
- **Full system**: 1 hour (including server provisioning)

### Recovery Point Objectives (RPO)
- **Daily backups**: Up to 24 hours data loss
- **Hourly backups**: Up to 1 hour data loss (for critical deployments)

## Backup Security

### Encryption Best Practices
- Use strong, unique backup passwords
- Store passwords separately from backups
- Consider using key files instead of passwords
- Rotate encryption keys annually

### Access Control
```bash
# Secure backup directory
chmod 700 ~/backups
chmod 600 ~/backups/*.gpg

# Secure backup script
chmod 700 ~/containers/backup.sh
```

### Backup Integrity
```bash
# Add checksums to backups
for file in ~/backups/*.gpg; do
    sha256sum "$file" >> ~/backups/checksums.txt
done

# Verify checksums
cd ~/backups && sha256sum -c checksums.txt
```

## Troubleshooting

### Common Issues

#### "Permission denied" during restore
```bash
# Fix ownership after restore
sudo chown -R $(whoami):$(whoami) ~/containers/
```

#### Database connection failed
```bash
# Check if postgres is ready
podman-compose exec postgres pg_isready -U synapse

# Wait for database startup
sleep 30 && retry restore
```

#### Insufficient disk space
```bash
# Check available space
df -h ~/

# Clean up old logs and temporary files
podman system prune -f
```

### Backup Recovery Testing

Create a monthly test schedule to verify backup integrity and restoration procedures:

1. **Week 1**: Test backup file integrity
2. **Week 2**: Test database restoration
3. **Week 3**: Test full data restoration
4. **Week 4**: Test complete disaster recovery

Regular testing ensures your backups will work when you need them most.