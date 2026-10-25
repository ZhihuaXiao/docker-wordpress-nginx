# Docker 生产级 WordPress 部署栈

[English](README.md) | [简体中文](README_CN.md)

一套开箱即用、安全加固的 Docker Compose 生产级 WordPress 运行环境，基于 **WordPress (PHP-FPM)**、**Nginx** 反向代理、**MySQL 8.0** 以及通过 Certbot 实现的 **Let's Encrypt** SSL/TLS 自动化证书管理。

---

## 项目概述

本项目为 WordPress 提供了企业级、高便携性的容器化部署方案，包含自动化备份与灾难恢复脚本、生产环境安全加固、容器日志轮转以及自动化 TLS 证书管理。

### 架构拓扑

```
                       互联网流量 (Internet)
                               │
                        ┌──────▼──────┐
                        │    Nginx    │  (:80 / :443)
                        │ (webserver) │
                        └──────┬──────┘
                               │
               ┌───────────────┴───────────────┐
               │ (静态文件与资源直出)          │ (PHP 请求通过 FastCGI 转发)
               ▼                               ▼
        /var/www/html                 ┌─────────────────┐
(绑定宿主机: ./data/wordpress)         │  WordPress FPM  │  (:9000 内部通信)
                                      │   (wordpress)   │
                                      └────────┬────────┘
                                               │
                                               ▼
                                      ┌─────────────────┐
                                      │     MySQL 8     │  (:3306 内部通信)
                                      │      (db)       │
                                      └─────────────────┘
```

### 服务矩阵

| 服务名称 | Docker 镜像 | 容器内部端口 | 宿主机映射端口 | 职责说明 |
| :--- | :--- | :--- | :--- | :--- |
| **`webserver`** | `nginx:1.27-alpine` | `80`, `443` | `80:80`, `443:443` | 反向代理、TLS 终端卸载、静态资源长效缓存 |
| **`wordpress`** | `wordpress:6.8-fpm-alpine` | `9000` | 无（仅内部网络） | WordPress 核心程序与 PHP-FPM 运行环境 |
| **`db`** | `mysql:8.0` | `3306` | 无（仅内部网络） | MySQL 关系型数据库，挂载持久化数据目录 |
| **`certbot`** | `certbot/certbot` | 无 | 无（按需启动 Profile） | 自动化申请与签发 Let's Encrypt ACME 证书 |

---

## 核心特性

- **解耦式微服务架构：** WordPress PHP-FPM 与 Nginx 独立运行。PHP-FPM 与 MySQL 端口均不暴露到公网，杜绝外部直接扫描。
- **生产环境安全加固：**
  - **上传目录脚本防执行：** Nginx 严格禁止在 `/wp-content/uploads/` 目录下执行任何 `.php` 脚本，阻断恶意文件上传后门。
  - **敏感文件访问拦截：** 严密拦截隐藏文件（如 `.git`、`.env`）以及敏感文件（如 `wp-config.php`、`readme.html`、`license.txt`）的外部请求。
  - **HTTP 安全响应头：** 默认强制开启 `Strict-Transport-Security` (HSTS)、`X-Frame-Options: SAMEORIGIN`（防点击劫持）、`X-Content-Type-Options: nosniff`（防 MIME 嗅探）和 `Referrer-Policy`。
  - **严格文件安全权限：** 备份快照自动执行 `umask 077` 与 `chmod 700/600`，彻底防止宿主机其他普通用户越权读取密码与数据库转储。
- **高性能与大文件上传支持：**
  - `client_max_body_size 64M`，完美支持大图、多媒体资源及大型插件/主题包上传，不再出现 HTTP 413 错误。
  - 调优 `fastcgi_read_timeout 300` 及 FastCGI 缓冲区，避免在大规模导入或更新时出现 504 Gateway Timeout 超时。
  - 为 CSS、JS、图片、WebP、AVIF 及 Web 字体配置了现代长效浏览器静态缓存规则。
- **全自动化 TLS 与 Certbot 隔离：**
  - 通过 Nginx 的 Webroot 机制无缝进行 Let's Encrypt ACME 验证。
  - Certbot 服务隔离在专属的 Docker Compose profile (`profiles: ["certbot"]`) 中并设置 `restart: "no"`，避免日常执行 `docker compose up -d` 时误触发 Certbot 造成 Let's Encrypt 频次受限（Rate Limiting）。
- **自动化备份与灾难恢复（DR）：**
  - [scripts/backup.sh](scripts/backup.sh)：一键生成带时间戳的安全快照（包含 utf8mb4 MySQL 完整转储、网站核心文件、Nginx 配置、`.env` 与 TLS 证书）。
  - [scripts/restore.sh](scripts/restore.sh)：在停止容器或清空活跃文件前，自动通过 `gzip` 和 `tar` 完整性校验，杜绝因归档损坏导致的灾难性数据丢失。
- **磁盘防爆保护（容器日志轮转）：**
  - 所有容器统一配置 Docker `json-file` 日志轮转（`max-size: 10m`, `max-file: 3`），彻底防止日志无限制暴涨撑爆宿主机磁盘。
- **简明清晰的数据持久化：**
  - 数据库、多媒体资源和证书全量统一存放于根目录下的 `./data/` 目录中，便于管理、迁移与全盘备份。

---

## 目录结构

```text
wordpress/
├── docker-compose.yml        # 容器服务、网络、持久卷与日志配置
├── .env.example              # 环境变量模板文件（已脱敏，纳入版本控制）
├── .env                      # 本地运行真实机密配置（严格 gitignore，杜绝提交）
├── .dockerignore             # 构建排除文件列表
├── .gitignore                # 屏蔽 .env、/backups/ 与 /data/ 等敏感内容
├── README.md                 # 英文部署说明文档
├── README_CN.md              # 中文部署说明文档
├── BACKUP.md                 # 英文备份与灾难恢复实操手册
├── BACKUP_CN.md              # 中文备份与灾难恢复实操手册
├── LICENSE                   # 开源许可协议 (MIT)
├── nginx-conf/
│   ├── default.conf.template # HTTP 80 端口配置模板（启动自动注入 $DOMAIN_NAME）
│   └── ssl.conf.template     # HTTPS 443 端口配置模板（启动自动注入 $DOMAIN_NAME）
├── scripts/
│   ├── backup.sh             # 自动化全量快照备份脚本（带权限加固）
│   └── restore.sh            # 自动化全量快照恢复脚本（带解压完整性校验）
├── backups/                  # 备份快照产物目录（自动生成，gitignore）
└── data/                     # 挂载的本地持久化数据（gitignore）
    ├── dbdata/               # MySQL 数据存储目录 (/var/lib/mysql)
    ├── wordpress/            # WordPress 站点根目录 (/var/www/html)
    └── certbot-etc/          # Let's Encrypt 证书及密钥 (/etc/letsencrypt)
```

---

## 环境准备

- **Docker:** Engine 20.10+
- **Docker Compose:** Compose v2 (推荐使用 `docker compose` 命令行插件)
- **域名解析:** 已将域名的 DNS `A` 或 `CNAME` 记录解析到本台服务器公网 IP
- **网络防火墙:** 确保服务器的 **80** 和 **443** 端口对公网放行

### Cloudflare 用户特别注意
如果您使用了 Cloudflare 的 CDN 代理（橙色小云朵）：
1. 在初次签发证书时，HTTP 80 端口必须能够直达源站。若 ACME 验证失败，可暂时将解析切换为 **仅限 DNS**（灰色小云朵），证书申请成功后再切回代理。
2. 源站 HTTPS 正常运行后，请将 Cloudflare 控制台中的 **SSL/TLS 加密模式** 设置为 **完全（严格）/ Full (strict)**。

---

## 配置说明

### 1. 配置环境变量

从示例模板复制生成本地 `.env` 文件：

```bash
cp .env.example .env
chmod 600 .env
```

编辑 `.env` 设置高强度的数据库密码及真实域名：

```ini
MYSQL_ROOT_PASSWORD=此处设置高强度ROOT密码
MYSQL_USER=wp_user
MYSQL_PASSWORD=此处设置高强度数据库用户密码
# 可选：数据库名称（如不填则默认 wordpress_db）
MYSQL_DATABASE=wordpress_db

# 绑定的正式域名与 Certbot 告警邮箱
DOMAIN_NAME=yourdomain.com
CERTBOT_EMAIL=your-email@example.com
```

Nginx 在容器启动时会自动通过官方模板引擎 (`/docker-entrypoint.d/20-envsubst-on-templates.sh`) 读取 `.env` 中的 `${DOMAIN_NAME}`，自动渲染生成 `/etc/nginx/conf.d/` 下的运行时配置。

---

## 快速上手与首次部署

### 步骤 1：首次初始化 SSL 证书

在全新的服务器上，Nginx 若直接开启 `ssl.conf.template` 会因证书文件尚不存在而启动失败。请遵循以下标准三步初始化：

**a.** 临时停用 HTTPS 模板：
```bash
mv nginx-conf/ssl.conf.template nginx-conf/ssl.conf.template.bak
```

**b.** 启动基础服务并通过 Certbot 获取首次证书：
```bash
docker compose up -d db wordpress webserver
docker compose run --rm certbot
```

**c.** 恢复 HTTPS 模板并重启 Nginx：
```bash
mv nginx-conf/ssl.conf.template.bak nginx-conf/ssl.conf.template
docker compose restart webserver
```

### 步骤 2：完成 WordPress 网页安装向导

1. 浏览器访问 `https://yourdomain.com/`。
2. 按照向导提示选择语言、填写站点名称、管理员用户名与密码。
3. 后台管理面板访问地址：`https://yourdomain.com/wp-admin/`。

---

## 常用运维管理命令

```bash
# 启动所有核心服务 (db, wordpress, webserver)
docker compose up -d

# 停止容器服务 (数据在 ./data/ 中完好保留)
docker compose down

# 查看各容器运行状态
docker compose ps

# 实时追踪日志
docker compose logs -f webserver
docker compose logs -f wordpress
docker compose logs -f db

# 查看 Certbot 历史日志（需指定 profile）
docker compose --profile certbot logs certbot

# 修改 Nginx 配置后重启 webserver
docker compose restart webserver

# 手动执行证书续期
docker compose run --rm certbot renew
docker compose restart webserver
```

---

## 备份与灾难恢复（Disaster Recovery）

更详尽的备份与恢复方案请参阅 **[BACKUP_CN.md](BACKUP_CN.md)**。

### 创建服务器快照备份
```bash
chmod +x scripts/backup.sh scripts/restore.sh
./scripts/backup.sh
```
*自动在 `backups/YYYYMMDD-HHMMSS/` 目录下生成加密加固的安全快照，内含 `wordpress_db.sql.gz`、`wordpress.tar.gz`、`nginx-conf.tar.gz`、`.env` 以及 TLS 证书。*

### 从快照恢复站点
```bash
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```
*恢复脚本在动工前会自动执行完整的归档校验，防止解压不完整破坏现有生产数据。*

---

## 安全最佳实践

1. **绝对不要将敏感凭据提交至 Git：** `.env`、`backups/` 和 `data/` 已默认加入 `.gitignore`，切忌使用 `git add -f` 强制提交。
2. **异地异机备份：** 定期将备份目录同步或传输到远程离线存储（如 AWS S3、SFTP、对象存储或离线硬盘）。
3. **定期更新基座镜像：**
   ```bash
   docker compose pull
   docker compose up -d
   ```
4. **宿主机文件系统权限：** 保持 `.env` 权限为 `chmod 600`，`backups/` 权限为 `chmod 700`。

---

## 常见问题排查（FAQ）

### Nginx 启动崩溃循环：`cannot load certificate ... No such file`
这是由于在尚未生成证书前启用了 HTTPS 配置。请参照上述 [首次初始化 SSL 证书](#步骤-1首次初始化-ssl-证书) 流程重新初始化。

### 大文件导入触发 HTTP 504 Gateway Timeout
当前 FastCGI 超时时间默认放宽为 300 秒。若进行超大型全站数据迁移，可在 [nginx-conf/ssl.conf.template](nginx-conf/ssl.conf.template) 中进一步调整 `fastcgi_read_timeout` 后重启 Nginx。

### 运行脚本提示 Docker Socket 权限不足 (`Permission Denied`)
如果当前 Linux 账号未加入 `docker` 用户组，请执行以下命令将当前用户加入用户组（免 sudo）：
```bash
sudo usermod -aG docker $USER && newgrp docker
```
或者指定环境变量：
```bash
DOCKER_COMPOSE="sudo docker compose" ./scripts/backup.sh
```

---

## 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。
