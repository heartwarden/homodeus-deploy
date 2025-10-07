# Quick Start Guide

Get your Matrix Synapse and PieFed services running in minutes!

## Prerequisites

- Fresh Linux server (Fedora/RHEL/Rocky/Debian/Ubuntu)
- Root access (script will create a non-root user)
- Domain name pointing to your server
- 2GB+ RAM, 20GB+ storage recommended

## One-Command Deployment

```bash
# Download and run deployment script
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homodeus-deploy/main/deploy.sh -o deploy.sh
chmod +x deploy.sh

# Deploy both Matrix and PieFed (recommended)
sudo ./deploy.sh both yourdomain.com

# Or deploy individually
sudo ./deploy.sh matrix matrix.yourdomain.com
sudo ./deploy.sh piefed piefed.yourdomain.com
```

## What the Script Does

1. **Creates Secure User**: Automatically creates a non-root user with SSH key migration
2. **Hardens System**: Configures firewall, fail2ban, and security settings
3. **Deploys Services**: Sets up Matrix/PieFed with Podman containers
4. **Configures Reverse Proxy**: Generates Caddy configuration for HTTPS
5. **Sets Up Monitoring**: Configures fail2ban and log encryption

## DNS Configuration

Point these records to your server IP:

```
A     yourdomain.com        YOUR_SERVER_IP
A     matrix.yourdomain.com YOUR_SERVER_IP
A     piefed.yourdomain.com YOUR_SERVER_IP
```

## After Deployment

### 1. Apply Caddy Configuration

```bash
# The script generates the config file
sudo cp ~/Caddyfile.generated /etc/caddy/Caddyfile
sudo systemctl enable --now caddy
sudo systemctl reload caddy
```

### 2. Create Admin Accounts

**Matrix Admin:**
```bash
cd ~/containers/matrix
podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml --admin http://localhost:8008
```

**PieFed Admin:**
- Visit https://piefed.yourdomain.com
- Register first account (becomes admin)

### 3. Test Your Services

- **Matrix**: https://matrix.yourdomain.com
- **Matrix Admin UI**: https://matrix.yourdomain.com/admin/
- **PieFed**: https://piefed.yourdomain.com

### 4. Setup Automated Backups

```bash
# Edit crontab
crontab -e

# Add daily backup at 2 AM
0 2 * * * ~/containers/backup.sh
```

## Security Features

✅ **Rootless Containers**: Services run as non-root user
✅ **Firewall**: Configured with minimal ports open
✅ **fail2ban**: Intrusion prevention system active
✅ **Encrypted Logs**: All logs encrypted at rest
✅ **Encrypted Backups**: Database and file backups encrypted
✅ **System Hardening**: Kernel parameters and service hardening
✅ **SSH Security**: Key-based authentication configured

## Troubleshooting

### Services Won't Start
```bash
# Check service status
cd ~/containers/matrix  # or ~/containers/piefed
podman-compose ps
podman-compose logs

# Restart services
podman-compose down
podman-compose up -d
```

### Can't Access Services
```bash
# Check firewall
sudo firewall-cmd --list-all  # Fedora/RHEL
sudo ufw status              # Debian/Ubuntu

# Check Caddy
sudo systemctl status caddy
sudo journalctl -u caddy -f
```

### Check fail2ban
```bash
# View status
sudo fail2ban-client status

# Check specific jail
sudo fail2ban-client status matrix-synapse
```

## Important Files

**Secrets (BACKUP THESE!):**
- `~/.local/share/homodeus-secrets/matrix.env`
- `~/.local/share/homodeus-secrets/piefed.env`
- `~/.local/share/homodeus-secrets/.log_key`

**Services:**
- `~/containers/matrix/compose.yml`
- `~/containers/piefed/compose.yml`

**Backups:**
- `~/backups/` (encrypted files)
- `~/containers/backup.sh` (backup script)

## Getting Help

- 📖 [Full Documentation](README.md)
- 🔒 [Security Guide](SECURITY.md)
- 💾 [Backup & Restore](BACKUP_RESTORE.md)
- 🐛 [Issue Tracker](https://github.com/YOUR_USERNAME/homodeus-deploy/issues)

## Next Steps

1. **Join Matrix Communities**: Connect with other Matrix users
2. **Configure PieFed**: Set up communities and moderation
3. **Monitor Logs**: Check encrypted logs regularly
4. **Update Services**: Keep containers updated
5. **Test Backups**: Verify backup restoration works

That's it! You now have a secure, production-ready Matrix and PieFed deployment. 🎉