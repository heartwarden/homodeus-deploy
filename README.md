# Homodeus Deploy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub release](https://img.shields.io/github/v/release/heartwarden/homodeus-deploy.svg)](https://github.com/heartwarden/homodeus-deploy/releases)
[![GitHub stars](https://img.shields.io/github/stars/heartwarden/homodeus-deploy.svg)](https://github.com/heartwarden/homodeus-deploy/stargazers)

🔒 Secure, production-ready deployment system for Matrix Synapse and PieFed with rootless Podman containers, fail2ban integration, and encrypted logs.

## Features

- ✅ One-command deployment from fresh server
- ✅ Automatic user creation with SSH key migration
- ✅ Rootless Podman containers
- ✅ fail2ban integration for intrusion prevention
- ✅ Encrypted logs and backups
- ✅ System hardening (firewall, kernel parameters)
- ✅ Caddy with automatic HTTPS
- ✅ Production-ready for 100-1000 concurrent users
- ✅ Docker Compose v2 compatibility

## Quick Start

> **Note**: Replace `YOUR_USERNAME` with your actual GitHub username in the commands below.

```bash
# Download and run deployment script
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homodeus-deploy/main/deploy.sh -o deploy.sh
chmod +x deploy.sh

# Deploy both Matrix and PieFed
./deploy.sh both yourdomain.com

# Or deploy individually
./deploy.sh matrix matrix.yourdomain.com
./deploy.sh piefed piefed.yourdomain.com
```

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md) - Get up and running in minutes
- [Security Guide](docs/SECURITY.md) - fail2ban and security configuration
- [Backup & Restore](docs/BACKUP_RESTORE.md) - Data protection procedures
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Architecture

This deployment system creates:

1. **Secure User Environment**: Automatically creates a non-root user with SSH key migration
2. **Rootless Containers**: Uses Podman for enhanced security
3. **Reverse Proxy**: Caddy with automatic HTTPS certificates
4. **Intrusion Prevention**: fail2ban monitoring key services
5. **Data Protection**: Encrypted logs and automated backups
6. **System Hardening**: Firewall rules and kernel security parameters

## Requirements

- Fresh Linux server (Fedora/RHEL/Rocky/Debian/Ubuntu)
- Root access (script creates non-root user)
- Domain name pointing to server
- 2GB+ RAM, 20GB+ storage

## Security Features

- Rootless container execution
- fail2ban intrusion prevention
- Encrypted log storage
- SSH key management
- Firewall configuration
- System hardening
- Automated security updates

## Support

- 📖 [Documentation](docs/)
- 🐛 [Issue Tracker](https://github.com/YOUR_USERNAME/homodeus-deploy/issues)
- 💬 [Discussions](https://github.com/YOUR_USERNAME/homodeus-deploy/discussions)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Matrix Synapse team for the excellent homeserver
- PieFed developers for the federation platform
- Podman team for rootless containers
- Caddy team for automatic HTTPS
