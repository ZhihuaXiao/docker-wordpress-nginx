# 备份与恢复操作手册

[English](BACKUP.md) | [简体中文](BACKUP_CN.md)

本项目提供两种备份 Docker WordPress 站点的方式：

| 备份方式 | 适用场景与内容 |
| :--- | :--- |
| [`scripts/backup.sh`](scripts/backup.sh) | **全量服务器快照**：完整数据库、全量站点文件、Nginx 配置、Docker Compose、`.env` 密钥、TLS 证书 |
| [WordPress 后台插件备份](#从-wordpress-后台备份) | **应用层备份**：适合在 WordPress 仪表盘直接操作（数据库 + `wp-content` 目录） |
| [`scripts/restore.sh`](scripts/restore.sh) | **自动化快照还原**：一键还原 `backup.sh` 生成的全量快照 |

> **提示：** 备份脚本采用标准的 `mysqldump` 逻辑导出与文件打包机制，**不会**在数据库运行期间去拷贝底层的原始 InnoDB 数据文件（`data/dbdata`），保障了数据一致性。

---

## 备份包内容清单

每次运行 `./scripts/backup.sh` 都会在 `backups/YYYYMMDD-HHMMSS/` 下（或通过 `--output-dir` 自定义目录）生成独立快照：

| 文件名称 | 包含内容 |
| :--- | :--- |
| `wordpress_db.sql.gz` | `wordpress_db` 数据库的 gzip 压缩转储 (utf8mb4) |
| `wordpress.tar.gz` | `data/wordpress` 下的所有核心文件、主题、插件与上传媒体 |
| `nginx-conf.tar.gz` | Nginx HTTP 与 HTTPS 配置模板 |
| `docker-compose.yml` | 备份时刻的容器编排配置文件 |
| `env.backup` | `.env` 环境变量副本（包含数据库连接凭据） |
| `certbot-etc.tar.gz` | Let's Encrypt 证书及私钥归档（如具备读取权限） |
| `MANIFEST.txt` | 快照元信息清单（时间戳、主机名、包含的备份文件状态） |

---

## 1. 使用脚本进行全量备份

在项目根目录下操作：

```bash
chmod +x scripts/backup.sh scripts/restore.sh   # 首次赋予可执行权限
./scripts/backup.sh
```

由于 `mysqldump` 需要与 MySQL 容器通信，执行前请确保服务处于运行状态：

```bash
docker compose up -d
./scripts/backup.sh
```

### 常用运行参数

```bash
# 指定输出目录（例如挂载的外部存储盘或迁移盘）
./scripts/backup.sh --output-dir /mnt/backups/wordpress

# 跳过 TLS 证书归档（还原后可随时通过 Certbot 重新签发）
./scripts/backup.sh --skip-certs

# 若普通用户无 Docker 权限，可显式指定 sudo：
DOCKER_COMPOSE="sudo docker compose" ./scripts/backup.sh
# 或者直接：
sudo ./scripts/backup.sh
```

### 权限与安全说明
`scripts/backup.sh` 在执行过程中会自动应用严格的权限防护：
- 快照目录权限强制收紧为 `0700` (`chmod 700`)。
- 敏感凭证 `env.backup` 与数据库转储 `wordpress_db.sql.gz` 权限收紧为 `0600` (`chmod 600`)。
- 如果通过 `sudo ./scripts/backup.sh` 执行，脚本会在完成时自动将快照的所有权归还给调用 `sudo` 的原始系统用户，方便您日常查看与离线复制。

> **重要警示：** `env.backup` 包含明文数据库密码。仅保存在本台云服务器上的备份**不能算作**合格的灾难恢复计划，请务必将备份快照目录同步复制到异地（对象存储 S3、远程 SFTP 服务器或个人电脑）。

---

## 2. 从 WordPress 后台备份

当您具备 WordPress 管理员登录权限、希望无需登录 SSH 终端即可下载备份时，推荐使用此方式。它涵盖 WordPress 数据库和插件配置的文件，但**不包括** Docker 编排配置、Nginx、`.env` 或 Let's Encrypt 证书。

后台登录地址：`https://yourdomain.com/wp-admin/`（或 `https://yourdomain.com/wp-login.php`）。

### 步骤 1：安装备份插件
1. 登录 WordPress 管理员账号。
2. 进入 **插件 (Plugins) → 安装插件 (Add Plugin)**。
3. 搜索常见成熟插件，如 **UpdraftPlus**。
4. 点击 **现在安装**，然后点击 **启用**。

### 步骤 2：执行备份
1. 点击 **设置 (Settings) → UpdraftPlus Backups**。
2. 确认已勾选：数据库、插件、主题、上传文件及其他 `wp-content` 目录。
3. 点击 **立即备份 (Backup Now)**。
4. 等待进度条走完提示备份成功。

### 步骤 3：下载备份到异地本地
1. 在同一界面下方的“现有备份”列表中找到刚生成的备份。
2. 依次点击下载各分卷（数据库、插件、主题、上传文件等）。
3. 妥善保存在本地硬盘，切勿只保留在服务器上。

---

## 3. 使用脚本进行全量还原

> **警告：** 还原操作会覆盖当前运行的站点数据。在还原前若现有数据还有价值，请务必先做一次最新的备份快照。

在还原执行任何删除或停止服务操作前，`scripts/restore.sh` 会自动预先执行**归档完整性校验**（针对数据库转储进行 `gzip -t` 测试，针对文件进行 `tar -tzf` 测试）。如果快照文件损坏或中途传输中断，脚本会立即安全退出，防止破坏现有正常运行的生产系统。

```bash
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```

执行后终端会提示确认，需手动输入大写的 `YES` 方可继续（若为自动化脚本可传入 `--yes` 跳过交互提示）。

### 还原操作会覆盖的内容：
- `data/wordpress/` 站点程序及媒体文件
- `nginx-conf/` 下的 Nginx 配置文件
- MySQL 数据库 `wordpress_db`（重新导入转储）

### 可选参数说明：

```bash
# 从快照中一并恢复 .env 文件（在新服务器上首次部署时推荐使用）
./scripts/restore.sh --restore-env backups/YYYYMMDD-HHMMSS

# 从快照中一并恢复 docker-compose.yml 配置文件
./scripts/restore.sh --restore-compose backups/YYYYMMDD-HHMMSS

# 自动化/无人值守模式（免去键盘输入 YES 确认）
./scripts/restore.sh --yes backups/YYYYMMDD-HHMMSS

# 保留服务器现有证书（不恢复备份包中的证书）
./scripts/restore.sh --skip-certs backups/YYYYMMDD-HHMMSS
```

> **注意：** `--restore-env` 恢复的数据库账号密码必须与 `data/dbdata` 现有的数据库用户匹配。在同一台运行正常的服务器上做版本回退时，通常不需要加 `--restore-env`。

还原完成后访问站点进行验证：
- 站点主页：`https://yourdomain.com/`
- 后台管理：`https://yourdomain.com/wp-admin/`

若恢复后 HTTPS 报错，可快速执行证书重新签发：
```bash
docker compose run --rm certbot
docker compose restart webserver
```

---

## 典型运维场景实战

### 场景 A：在进行高风险操作前（安装复杂插件/切换主题/大幅改版）

```bash
# 1. 快速制作整机快照
./scripts/backup.sh

# 2. 前往 wp-admin 进行改动测试

# 3. 若系统异常需要一键回滚：
./scripts/restore.sh backups/刚生成的快照文件夹
```

### 场景 B：迁移到全新服务器 / 空磁盘冷启动

1. 在新机器上克隆本项目仓库代码。
2. 将备份文件夹复制传输到新机器上。
3. 执行一键完整恢复（同时还原环境与配置）：

```bash
./scripts/restore.sh --yes --restore-env --restore-compose /path/to/backups/YYYYMMDD-HHMMSS
```

脚本会自动拉起 `db` 容器完成初始化，随后无缝将数据库转储和网站文件全量灌入。

---

## 常见问题与排查指南

- **无法登录 wp-admin 后台进行插件备份：**
  直接使用 SSH 终端执行 `./scripts/backup.sh`，脚本不需要任何 WordPress 登录态。
- **提示 `permission denied while trying to connect to the Docker daemon socket`：**
  请将用户加入 `docker` 用户组（`sudo usermod -aG docker $USER && newgrp docker`），或者使用 `sudo ./scripts/backup.sh`。
- **备份时提示跳过了证书 (certs: skipped)：**
  `data/certbot-etc` 权限通常受 root 保护。建议使用 `sudo ./scripts/backup.sh` 运行，即可正常将证书打包。
- **还原后访问页面仍显示旧版或旧缓存：**
  使用快捷键 `Ctrl+F5` / `Cmd+Shift+R` 强制刷新浏览器缓存；若接入了 Cloudflare 代理，需前往 Cloudflare 仪表盘清除缓存 (Purge Cache)。
- **Git 仓库安全提示：**
  快照所在的 `./backups/` 文件夹已被默认 `.gitignore`，切勿强制提交快照至 GitHub，以免泄露数据库真实密码与个人站点数据。
