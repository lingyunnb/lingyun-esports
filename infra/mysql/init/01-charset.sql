-- 容器首次初始化时执行（仅新建数据卷时生效一次）
-- 数据库由 MYSQL_DATABASE 环境变量创建，此处兜底确保 utf8mb4
-- 注意：库名需与 infra/.env 的 MYSQL_DATABASE 保持一致
CREATE DATABASE IF NOT EXISTS fish_platform CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SET NAMES utf8mb4;
