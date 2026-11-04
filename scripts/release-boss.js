/**
 * 老板端发布入口（保留原命令，铁律引用的就是这个脚本）
 *
 *   node scripts/release-boss.js <版本码> <版本名> "<更新说明>" [--force] [--install]
 *
 * 实际逻辑在 scripts/release-app.js（老板端/工作端共用），这里只固定 appType=boss。
 */
process.env.RELEASE_APP_TYPE = 'boss';
require('./release-app.js');
