# Security Guide

This deployment prioritizes security through multiple layers of protection.

## Security Architecture

### 1. Rootless Container Execution
- All services run as non-root user
- Podman containers with user namespaces
- No privileged container access
- Limited system capabilities

### 2. fail2ban Intrusion Prevention

#### Matrix Protection
**Location**: `/etc/fail2ban/jail.d/matrix-synapse.conf`

Monitors:
- Failed login attempts to `/_matrix/client/r0/login`
- Registration abuse on `/_matrix/client/(r0|v3)/register`

**Settings**:
- Max retries: 5 attempts
- Find time: 10 minutes
- Ban time: 1 hour
- Action: Block all ports

#### Caddy Protection
**Location**: `/etc/fail2ban/jail.d/caddy.conf`

Monitors:
- HTTP 401/403 responses
- Authentication failures
- Brute force attempts

**Settings**:
- Max retries: 10 attempts
- Find time: 10 minutes
- Ban time: 1 hour

### 3. Firewall Configuration

#### Fedora/RHEL (firewalld)
```bash
# View current rules
sudo firewall-cmd --list-all

# Allowed services
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-port=8448/tcp  # Matrix federation
```

#### Debian/Ubuntu (UFW)
```bash
# View current rules
sudo ufw status verbose

# Allowed ports
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw allow 8448/tcp # Matrix federation
```

### 4. System Hardening

#### Kernel Security Parameters
**Location**: `/etc/sysctl.d/99-homodeus-security.conf`

```bash
# Network security
net.ipv4.conf.all.rp_filter = 1                    # Reverse path filtering
net.ipv4.icmp_echo_ignore_broadcasts = 1           # Ignore ping broadcasts
net.ipv4.conf.all.accept_source_route = 0          # Disable source routing
net.ipv4.conf.all.send_redirects = 0               # Disable ICMP redirects
net.ipv4.tcp_syncookies = 1                        # SYN flood protection
net.ipv4.conf.all.log_martians = 1                 # Log suspicious packets

# File system security
fs.file-max = 65535                                 # Increase file limits
```

#### Resource Limits
**Location**: `/etc/security/limits.d/podman.conf`

```bash
# Increase limits for container user
username soft nofile 65536
username hard nofile 65536
username soft nproc 4096
username hard nproc 4096
```

#### Disabled Services
```bash
# Unnecessary services are disabled
avahi-daemon    # Network discovery
cups           # Printing
bluetooth      # Bluetooth
```

### 5. Log Security

#### Encrypted Log Storage
All logs are encrypted using AES256:

**Log Locations**:
- `~/.local/share/homodeus-logs/` (encrypted logs)
- `/var/log/caddy/` (Caddy access logs)
- Container logs (encrypted in rotation)

**Encryption Key**: `~/.local/share/homodeus-secrets/.log_key`

#### Log Rotation
**Script**: `~/containers/rotate-logs.sh`
**Schedule**: Weekly on Sundays at 3 AM

```bash
# Manual log rotation
LOG_ENCRYPTION_PASSWORD=$(cat ~/.local/share/homodeus-secrets/.log_key) \
    ~/containers/rotate-logs.sh
```

### 6. Backup Security

#### Encrypted Backups
All backups use GPG AES256 encryption:

**Backup Components**:
- Database dumps (PostgreSQL)
- Data directories
- Application logs
- Secrets and configuration

**Backup Script**: `~/containers/backup.sh`

```bash
# Manual backup
~/containers/backup.sh
# Enter encryption password when prompted
```

**Important**: Store backup password securely and separately from server!

### 7. SSH Security

#### Key-Based Authentication
- SSH keys copied from root to deployment user
- Password authentication should be disabled
- Use strong SSH keys (RSA 4096-bit or Ed25519)

#### SSH Hardening (Recommended)
Edit `/etc/ssh/sshd_config`:

```bash
# Disable password authentication
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no

# Disable root login
PermitRootLogin no

# Limit users
AllowUsers your-deploy-user

# Change default port (optional)
Port 2222

# Restart SSH
sudo systemctl restart sshd
```

### 8. Container Security

#### Podman Security Features
- **User namespaces**: Containers run as unprivileged user
- **SELinux/AppArmor**: Labels applied with `:Z` flag
- **No privileged access**: Containers cannot access host resources
- **Network isolation**: Separate networks per service

#### Container Updates
```bash
# Update container images
cd ~/containers/matrix
podman-compose pull
podman-compose up -d

cd ~/containers/piefed
podman-compose pull
podman-compose up -d
```

### 9. Matrix-Specific Security

#### Registration Security
- Shared secret for admin registration
- Rate limiting on registration endpoints
- Email verification can be enabled

#### Rate Limiting
- Message rate limiting: 0.1/second, burst 5
- Login rate limiting: 0.05/second, burst 5
- Registration rate limiting: 0.017/second, burst 3

#### Media Security
- Upload limit: 10MB
- URL preview disabled (prevents SSRF)
- Media repository isolated

### 10. Monitoring and Alerting

#### fail2ban Monitoring
```bash
# Check banned IPs
sudo fail2ban-client status matrix-synapse
sudo fail2ban-client status caddy-auth

# Unban IP if needed
sudo fail2ban-client set matrix-synapse unbanip 1.2.3.4
```

#### Log Monitoring
```bash
# Check recent fail2ban activity
sudo journalctl -u fail2ban -f

# Check Caddy access logs
sudo tail -f /var/log/caddy/access.log

# Check service logs
podman-compose logs -f synapse
```

#### System Monitoring
```bash
# Check resource usage
podman stats

# Check disk space
df -h

# Check memory usage
free -h

# Check active connections
ss -tulpn
```

## Security Maintenance

### Weekly Tasks
- Review fail2ban logs
- Check for banned IPs
- Verify backup completion
- Update container images

### Monthly Tasks
- Review encrypted logs
- Update system packages
- Rotate backup encryption keys
- Test backup restoration

### Security Updates
```bash
# System updates
sudo dnf update -y          # Fedora/RHEL
sudo apt update && sudo apt upgrade -y  # Debian/Ubuntu

# Container updates
cd ~/containers/matrix && podman-compose pull && podman-compose up -d
cd ~/containers/piefed && podman-compose pull && podman-compose up -d
```

## Incident Response

### Suspected Compromise
1. **Isolate**: Block suspicious IPs with fail2ban
2. **Investigate**: Check logs for unauthorized access
3. **Rotate**: Change all secrets and passwords
4. **Update**: Ensure all systems are patched
5. **Monitor**: Increase monitoring for 48 hours

### Recovery from Backup
```bash
# Stop services
cd ~/containers/matrix && podman-compose down
cd ~/containers/piefed && podman-compose down

# Restore from encrypted backup
gpg --decrypt backup_file.gpg | tar xzf -

# Restart services
podman-compose up -d
```

## Security Contacts

- **Report Issues**: [GitHub Issues](https://github.com/YOUR_USERNAME/homodeus-deploy/issues)
- **Security Vulnerabilities**: Email security@yourdomain.com
- **Matrix Security**: [Matrix Security Guide](https://matrix.org/docs/guides/security)

## Security Checklist

- [ ] fail2ban is active and monitoring
- [ ] Firewall rules are minimal and correct
- [ ] SSH is key-only authentication
- [ ] All services run as non-root
- [ ] Logs are encrypted and rotated
- [ ] Backups are encrypted and tested
- [ ] System is regularly updated
- [ ] Resource limits are configured
- [ ] Unnecessary services are disabled
- [ ] Container images are regularly updated

## Additional Hardening (Advanced)

### AppArmor/SELinux Profiles
- Create custom profiles for containers
- Restrict file system access
- Limit network capabilities

### Network Segmentation
- Use separate VLANs for services
- Implement network policies
- Monitor inter-service communication

### Certificate Management
- Use short-lived certificates
- Implement certificate pinning
- Monitor certificate transparency logs

This security configuration provides defense-in-depth against common attack vectors while maintaining operational simplicity.