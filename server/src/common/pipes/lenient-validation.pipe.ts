import { ArgumentMetadata, Injectable, Logger, ValidationPipe, ValidationPipeOptions } from '@nestjs/common';
import { buildValidationException } from './validation-messages';

/**
 * 全局校验配置（原来内联在 main.ts，抽出来便于阅读；main.ts 注入它）
 *
 * 铁律（docs/03）：白名单校验 + 未知字段不落库。全局默认仍然**拒绝**未知字段。
 *
 * 2026-10-04（负责人报障）：`exceptionFactory` 把 class-validator 的英文默认消息
 * **翻译成中文并结构化**（`{ code, message, errorCode: 'VALIDATION_FAILED', fields[] }`），
 * 详见 ./validation-messages.ts。宽松语义（LenientUpdateDto）与既有行为完全不变。
 */
export const GLOBAL_VALIDATION_OPTIONS: ValidationPipeOptions = {
  whitelist: true,
  forbidNonWhitelisted: true,
  transform: true,
  // 查询参数默认是字符串，按 DTO 元数据类型隐式转换（page=1 → 1）
  transformOptions: { enableImplicitConversion: true },
  // 英文校验消息 → 中文 + 字段级结构（客户端可把提示落到对应输入框下方）
  exceptionFactory: (errors) => {
    const logger = new Logger('Validation');
    return buildValidationException(errors, logger);
  },
};

/**
 * 「局部更新」DTO 基类（负责人 2026-10-04 报障修复）
 *
 * 用在**更新类 / 简介类** DTO 上：`export class XxxUpdateDto extends LenientUpdateDto { … }`
 *
 * 语义 = 该 DTO 允许请求体里多带字段（如管理端把列表接口返回的整对象回传，
 * 夹带 `id` / `gameName` / `onlineCount` 等只读/计算字段），多出来的字段**静静忽略**，
 * 而不是整请求 400（`property gameName should not exist` → 表现为「改简介就报错」）。
 *
 * 为什么不把管道挂在方法上（`@UsePipes(LenientValidationPipe)`）？
 * Nest 的管道执行顺序是 **全局 → 类 → 方法**（@nestjs/core ContextCreator.createContext），
 * 方法级管道永远晚于全局管道，而全局管道会先抛 400，方法级放宽根本没机会生效；
 * 且 `pipe.transform()` 只拿到 `{ metatype, type, data }`，拿不到 handler 元数据
 * （@nestjs/core PipesConsumer），所以判断依据只能来自 DTO 自身。
 *
 * 安全影响（**不降低安全性**）：
 * - 未知字段先由 `whitelist: true` 按校验元数据删除，再被本管道按「DTO 已声明属性」二次收口，
 *   service / 数据库只会看到 DTO 白名单里的字段；
 * - 业务敏感字段（`userId`、价格、权限位、状态、归属 id…）只要不在 DTO 里就改不动；
 * - 已声明字段的类型/长度/取值校验一个不少，非法值照样 400。
 */
export abstract class LenientUpdateDto {}

/** 全局校验管道：默认严格；DTO 继承 LenientUpdateDto 时对该 DTO 放宽（未知字段忽略） */
@Injectable()
export class LenientValidationPipe extends ValidationPipe {
  constructor() {
    super(GLOBAL_VALIDATION_OPTIONS);
  }

  async transform(value: unknown, metadata: ArgumentMetadata): Promise<unknown> {
    const lenient = this.isLenientTarget(metadata.metatype);
    if (!lenient) {
      return super.transform(value, metadata);
    }

    // 放宽只作用于本次调用：改完立即还原（Nest 路由 handler 构建一次、多请求共用该管道实例）
    const saved = this.validatorOptions.forbidNonWhitelisted;
    this.validatorOptions.forbidNonWhitelisted = false;
    try {
      const result = await super.transform(value, metadata);
      return this.omitUnknownKeys(value, result);
    } finally {
      this.validatorOptions.forbidNonWhitelisted = saved;
    }
  }

  /** 目标 DTO 是否继承 LenientUpdateDto（含多级继承） */
  private isLenientTarget(metatype: unknown): boolean {
    return typeof metatype === 'function' && metatype.prototype instanceof LenientUpdateDto;
  }

  /**
   * 未知字段静默剔除。
   *
   * `whitelist: true` 会按 DTO 校验元数据删掉未声明属性（class-validator 的
   * `whitelist` 分支），这里再按「DTO 已声明且被赋值的键」收口一次，
   * 保证 service 拿到的对象**只含 DTO 声明过的字段**（多余键绝不外溢）。
   */
  private omitUnknownKeys(value: unknown, result: unknown): unknown {
    const isPlainObject = (v: unknown): v is Record<string, unknown> =>
      v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Date);
    if (!isPlainObject(value) || !isPlainObject(result)) {
      return result;
    }
    const allowed = new Set(Object.keys(result));
    for (const key of Object.keys(value)) {
      if (!allowed.has(key)) {
        delete result[key];
      }
    }
    return result;
  }
}
