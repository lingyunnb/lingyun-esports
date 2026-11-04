/**
 * 工作端发布入口（与老板端同等要求）
 *
 *   node scripts/release-worker.js <版本码> <版本名> "<更新说明>" [--force] [--install]
 *
 * 实际逻辑在 scripts/release-app.js（老板端/工作端共用），这里只固定 appType=worker。
 */
process.env.RELEASE_APP_TYPE = 'worker';
require('./release-app.js');
