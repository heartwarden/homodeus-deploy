# Troubleshooting Guide

Common issues and solutions for your Matrix Synapse and PieFed deployment.

## Quick Diagnostics

### Check Service Status
```bash
# Check running containers
podman ps -a

# Check specific service logs
cd ~/containers/matrix && podman-compose logs synapse
cd ~/containers/piefed && podman-compose logs piefed

# Check system services
systemctl --user status matrix.service
systemctl --user status piefed.service
sudo systemctl status caddy
sudo systemctl status fail2ban
```

### Check Network Connectivity
```bash
# Test local services
curl -I http://localhost:8008/_matrix/client/versions  # Matrix
curl -I http://localhost:8080/                        # PieFed

# Test external access
curl -I https://matrix.yourdomain.com/_matrix/client/versions
curl -I https://piefed.yourdomain.com/
```

### Check Resource Usage
```bash
# Container resources
podman stats

# System resources
htop
df -h
free -h

# Check disk space in containers
podman exec matrix-synapse df -h /data
podman exec piefed-app df -h /app
```

## Container Issues

### Containers Won't Start

#### Problem: Services fail to start
```bash
# Check container status
cd ~/containers/matrix
podman-compose ps

# Check logs for errors
podman-compose logs postgres
podman-compose logs synapse
```

**Common causes and solutions:**

1. **Port conflicts**
   ```bash
   # Check what's using the port
   sudo ss -tlnp | grep 8008

   # Kill conflicting process or change port
   sudo kill PID
   ```

2. **Permission issues**
   ```bash
   # Fix ownership
   sudo chown -R $(whoami):$(whoami) ~/containers/
   chmod 755 ~/containers/
   ```

3. **Insufficient disk space**
   ```bash
   # Clean up old containers and images
   podman system prune -f

   # Check available space
   df -h ~/
   ```

#### Problem: Database connection failures
```bash
# Check if postgres is ready
podman-compose exec postgres pg_isready -U synapse

# Reset postgres container
podman-compose stop postgres
podman-compose rm postgres
podman-compose up -d postgres
```

### Container Networking Issues

#### Problem: Services can't reach each other
```bash
# Check network configuration
podman network ls
podman network inspect matrix_matrix_net

# Recreate network
cd ~/containers/matrix
podman-compose down
podman-compose up -d
```

#### Problem: DNS resolution fails
```bash
# Test container DNS
podman-compose exec synapse nslookup postgres
podman-compose exec synapse ping postgres

# Restart networking
sudo systemctl restart systemd-resolved  # systemd systems
sudo systemctl restart networking        # other systems
```

## Matrix Issues

### Matrix Synapse Won't Start

#### Problem: Homeserver configuration invalid
```bash
# Check configuration syntax
cd ~/containers/matrix
podman run --rm -v ./data:/data:Z \
    docker.io/matrixdotorg/synapse:latest \
    python -m synapse.config.homeserver --help

# Validate homeserver.yaml
python3 -c "import yaml; yaml.safe_load(open('./data/homeserver.yaml'))"
```

#### Problem: Database migration fails
```bash
# Check database logs
podman-compose logs postgres

# Manual database migration
podman-compose exec synapse python -m synapse.app.homeserver \
    --config-path /data/homeserver.yaml \
    --upgrade-db
```

### Matrix Federation Issues

#### Problem: Federation not working
```bash
# Test federation port
curl -I https://matrix.yourdomain.com:8448/_matrix/federation/v1/version

# Check .well-known endpoints
curl https://yourdomain.com/.well-known/matrix/server
curl https://yourdomain.com/.well-known/matrix/client

# Test with Matrix federation tester
# Visit: https://federationtester.matrix.org/
```

#### Problem: Unable to join rooms
```bash
# Check Matrix logs for federation errors
cd ~/containers/matrix
podman-compose logs synapse | grep -i federation

# Test DNS resolution
dig _matrix._tcp.example.com SRV
```

### Matrix Performance Issues

#### Problem: Slow response times
```bash
# Check database performance
podman-compose exec postgres \
    psql -U synapse -c "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"

# Check Redis connection
podman-compose exec redis redis-cli ping

# Analyze synapse metrics (if enabled)
curl http://localhost:9000/metrics | grep synapse
```

#### Problem: High memory usage
```bash
# Check Matrix memory usage
podman stats matrix-synapse

# Adjust worker configuration (advanced)
# Edit homeserver.yaml to add worker processes
```

## PieFed Issues

### PieFed Won't Start

#### Problem: Django configuration errors
```bash
# Check PieFed logs
cd ~/containers/piefed
podman-compose logs piefed

# Check environment variables
podman-compose exec piefed env | grep -E "(DATABASE|REDIS|SECRET)"
```

#### Problem: Database migration issues
```bash
# Run Django migrations manually
podman-compose exec piefed python manage.py migrate

# Check database status
podman-compose exec piefed python manage.py showmigrations
```

### PieFed Federation Issues

#### Problem: ActivityPub federation not working
```bash
# Check PieFed federation logs
podman-compose logs piefed | grep -i activitypub

# Test federation endpoint
curl https://piefed.yourdomain.com/.well-known/nodeinfo

# Check Celery worker
podman-compose logs celery
```

#### Problem: Media uploads failing
```bash
# Check media directory permissions
ls -la ~/containers/piefed/data/media/

# Fix permissions
sudo chown -R 1000:1000 ~/containers/piefed/data/media/
```

## Reverse Proxy Issues

### Caddy Issues

#### Problem: Caddy won't start
```bash
# Check Caddy configuration syntax
sudo caddy validate --config /etc/caddy/Caddyfile

# Check Caddy logs
sudo journalctl -u caddy -f

# Test configuration
sudo caddy run --config /etc/caddy/Caddyfile
```

#### Problem: SSL certificate issues
```bash
# Check certificate status
sudo caddy list-certificates

# Force certificate renewal
sudo systemctl stop caddy
sudo caddy run --config /etc/caddy/Caddyfile
```

#### Problem: 502 Bad Gateway errors
```bash
# Check if backend services are running
curl http://localhost:8008/_matrix/client/versions
curl http://localhost:8080/

# Check Caddy proxy configuration
sudo journalctl -u caddy | grep -i proxy
```

### DNS Issues

#### Problem: Domain not resolving
```bash
# Check DNS resolution
dig yourdomain.com A
dig matrix.yourdomain.com A
dig piefed.yourdomain.com A

# Check from external DNS
nslookup yourdomain.com 8.8.8.8
```

#### Problem: HTTPS certificate validation fails
```bash
# Check domain accessibility
curl -I https://yourdomain.com
openssl s_client -connect yourdomain.com:443 -servername yourdomain.com

# Verify DNS propagation
# Use online tools like whatsmydns.net
```

## Security Issues

### fail2ban Issues

#### Problem: fail2ban not blocking attackers
```bash
# Check fail2ban status
sudo fail2ban-client status

# Check specific jail
sudo fail2ban-client status matrix-synapse

# Manually ban IP
sudo fail2ban-client set matrix-synapse banip 1.2.3.4

# Check fail2ban logs
sudo journalctl -u fail2ban -f
```

#### Problem: Legitimate users getting banned
```bash
# Unban IP address
sudo fail2ban-client set matrix-synapse unbanip 1.2.3.4

# Add IP to whitelist
sudo tee -a /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 YOUR.TRUSTED.IP.ADDRESS
EOF

sudo systemctl restart fail2ban
```

### Firewall Issues

#### Problem: Services not accessible
```bash
# Check firewall status
sudo firewall-cmd --list-all  # Fedora/RHEL
sudo ufw status verbose       # Debian/Ubuntu

# Temporarily disable firewall for testing
sudo systemctl stop firewalld  # Fedora/RHEL
sudo ufw disable               # Debian/Ubuntu
```

#### Problem: Container networking blocked
```bash
# Check iptables rules
sudo iptables -L -n

# Check if podman rules are present
sudo iptables -L CNI-ADMIN -n

# Restart podman networking
podman system reset --force
```

## Performance Issues

### High CPU Usage

#### Problem: Containers using too much CPU
```bash
# Identify resource-heavy containers
podman stats

# Check specific processes
podman exec matrix-synapse top
podman exec piefed-app top

# Limit container resources
# Edit compose.yml to add resource limits:
# deploy:
#   resources:
#     limits:
#       cpus: '1.0'
#       memory: 1G
```

### High Memory Usage

#### Problem: Out of memory errors
```bash
# Check memory usage
free -h
podman stats

# Check container logs for OOM
dmesg | grep -i "killed process"

# Increase swap if needed
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Disk Space Issues

#### Problem: Running out of disk space
```bash
# Check disk usage
df -h
du -sh ~/containers/*/data/

# Clean up container data
podman system prune -f

# Clean up logs
sudo journalctl --vacuum-time=7d

# Move data to larger disk (if needed)
sudo systemctl stop podman
rsync -av ~/containers/ /new/location/
ln -sf /new/location ~/containers
```

## Backup and Recovery Issues

### Backup Problems

#### Problem: Backup script fails
```bash
# Check backup script logs
~/containers/backup.sh 2>&1 | tee backup.log

# Test GPG encryption
echo "test" | gpg --symmetric --cipher-algo AES256 --output test.gpg
gpg --decrypt test.gpg
```

#### Problem: Can't decrypt backups
```bash
# Verify backup file integrity
file ~/backups/matrix_db_*.gpg

# Test decryption with verbose output
gpg --verbose --decrypt ~/backups/matrix_db_*.gpg | head
```

### Restore Problems

#### Problem: Restore fails with permissions
```bash
# Fix ownership after restore
sudo chown -R $(whoami):$(whoami) ~/containers/

# Fix SELinux contexts (if applicable)
sudo restorecon -R ~/containers/
```

## Log Analysis

### Centralized Log Checking
```bash
# Create log analysis script
cat > ~/check-logs.sh << 'EOF'
#!/bin/bash
echo "=== CADDY LOGS ==="
sudo tail -20 /var/log/caddy/access.log

echo -e "\n=== MATRIX LOGS ==="
cd ~/containers/matrix && podman-compose logs --tail=20 synapse

echo -e "\n=== PIEFED LOGS ==="
cd ~/containers/piefed && podman-compose logs --tail=20 piefed

echo -e "\n=== FAIL2BAN STATUS ==="
sudo fail2ban-client status

echo -e "\n=== SYSTEM RESOURCES ==="
df -h | grep -v tmpfs
free -h
EOF

chmod +x ~/check-logs.sh
~/check-logs.sh
```

### Error Pattern Analysis
```bash
# Common error patterns to search for
grep -i "error\|fail\|exception" ~/containers/matrix/data/homeserver.log
grep -i "error\|fail\|exception" /var/log/caddy/access.log
sudo journalctl -u fail2ban | grep -i "ban\|found"
```

## Recovery Procedures

### Service Recovery
```bash
# Complete service restart
cd ~/containers/matrix && podman-compose down && podman-compose up -d
cd ~/containers/piefed && podman-compose down && podman-compose up -d
sudo systemctl restart caddy

# Database recovery
cd ~/containers/matrix
podman-compose stop synapse
podman-compose exec postgres pg_dump -U synapse synapse > backup.sql
# Fix issues then restore if needed
```

### Emergency Procedures

#### Problem: Complete system failure
1. **Check system logs**: `sudo journalctl -xe`
2. **Check disk space**: `df -h`
3. **Check memory**: `free -h`
4. **Restart services systematically**
5. **Restore from backup if needed**

#### Problem: Data corruption suspected
1. **Stop all services immediately**
2. **Create emergency backup**
3. **Run database integrity checks**
4. **Restore from known good backup**
5. **Investigate root cause**

## Getting Help

### Information to Collect
When seeking help, gather:
- Container logs (`podman-compose logs`)
- System logs (`journalctl`)
- Configuration files (sanitized)
- Error messages (exact text)
- Steps to reproduce

### Community Resources
- **GitHub Issues**: Report bugs and get help
- **Matrix Community**: Join #homodeus-deploy:matrix.org
- **Documentation**: Check all docs/ files first

### Professional Support
For production deployments, consider:
- Monitoring solutions (Prometheus, Grafana)
- Log aggregation (ELK stack)
- Professional Matrix hosting providers
- DevOps consultation services

Remember: Most issues can be resolved by carefully reading log files and checking the basics (disk space, network connectivity, permissions).