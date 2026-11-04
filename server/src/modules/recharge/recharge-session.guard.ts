import { CanActivate, ExecutionContext, ForbiddenException, Injectable, UnauthorizedException } from '@nestjs/common';

import { AuthUser } from '../../common/guards/jwt-auth.guard';

/**
 * `/recharge/*`（充值审核族）的**受限会话闸门**：只接受 `kind='recharge'` 的会话。
 *
 * ## 为什么需要它（不是多此一举）
 *
 * `JwtAuthGuard` 的白名单只约束 **companion / recharge 这类受限会话**；
 * **primary 会话不受白名单限制**（老板、管理员、打手的主会话本来就该能访问各自接口族）。
 * 因此若不在这一层显式要求 `kind='recharge'`，一个普通的 primary 管理员会话
 * 也能打 `/recharge/*` —— 那"受限会话"就不再是进出这族接口的唯一通道，
 * 两条路径的权限语义立刻分叉（受限会话有白名单、primary 没有）。
 *
 * ## 与"管理端也能审核"的关系（负责人 2026-10-06 定案：**双层口径**）
 *
 * - **PC 管理端**：正常 `role=admin` 的 **primary** 登录，走 `/admin/recharge/*` +
 *   `recharge:review` / `recharge:grant` 两个窄权限点。**管理端不需要、也不应该**套受限会话
 *   —— 它本来就是管理员终端，再包一层只剩登录流程变复杂，没有额外安全收益。
 * - **App 内「管理员身份」**：才用受限会话（`kind='recharge'`、12h、白名单 ≤5、默认拒绝一切其它接口），
 *   走 `/recharge/*`。
 *
 * 两条路径**共用同一个服务层**（`RechargeService.reviewList/grant/reject`），
 * 所以"PC 审的和 App 审的是同一套规则、同一套幂等"—— 差的只是入口与会话形态。
 */
@Injectable()
export class RechargeSessionGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<{ user?: AuthUser }>();
    const user = request.user;
    if (!user) {
      throw new UnauthorizedException('未登录');
    }
    // 会话有效性（白名单/封禁）已由 JwtAuthGuard 每请求实时校验；这里只判"是不是受限管理会话"
    if (user.kind !== 'recharge') {
      throw new ForbiddenException('该接口仅限「管理员身份」受限会话调用，请先在身份里绑定管理员账号');
    }
    return true;
  }
}
