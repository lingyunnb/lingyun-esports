import { ApiProperty } from '@nestjs/swagger';
import { IsEmail, IsIn, IsOptional, IsString, Length, Matches, ValidateIf } from 'class-validator';

/** 老板端注册（docs/04）：工作端/管理员账号只能由后台创建 */
export class RegisterDto {
  @ApiProperty({ description: '登录名：3-32 位字母数字下划线' })
  @IsString()
  @Length(3, 32)
  @Matches(/^[a-zA-Z0-9_]+$/, { message: '用户名仅支持字母、数字、下划线' })
  username: string;

  @ApiProperty({ description: '密码：8-64 位' })
  @IsString()
  @Length(8, 64)
  password: string;

  @ApiProperty({ description: '昵称（可选，默认同用户名）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 32)
  nickname?: string;

  @ApiProperty({ description: '展示 ID（可选，2-20 位中文/字母/数字/下划线；默认自动生成）', required: false })
  @IsOptional()
  @IsString()
  @Matches(/^[一-龥A-Za-z0-9_]{2,20}$/, { message: 'ID 须为 2-20 位中文、字母、数字或下划线' })
  uid?: string;

  /**
   * 邮箱（可选，负责人 2026-10-05）：**不传时注册行为与老版本完全一致**（老客户端零影响）。
   * 传了就必须带有效 emailCode（服务端强制），否则中文 400。
   */
  @ApiProperty({ description: '邮箱（可选；传入则必须同时传 emailCode）', required: false })
  @IsOptional()
  @IsString()
  // 文案只写规则本身，**不带字段名**：全局校验管道会自动拼上中文标签（email=邮箱），
  // 写成「邮箱格式不正确」会拼成「邮箱邮箱格式不正确」（2026-10-05 实测踩到）
  @IsEmail({}, { message: '格式不正确' })
  @Length(1, 120)
  email?: string;

  @ApiProperty({ description: '邮箱验证码（6 位数字；传了 email 时必填）', required: false })
  @IsOptional()
  @IsString()
  @Matches(/^\d{6}$/, { message: '须为 6 位数字' })
  emailCode?: string;
}

/**
 * 统一登录入参（docs/04）。
 *
 * 2026-10-10 新增「邮箱验证码登录」（负责人拍板 1：**密码登录照旧可用**）：
 * - **只传 username + password**（老客户端）：`email` 缺省 → `@ValidateIf` 让 `username/password`
 *   的校验**逐字照旧**生效（必填 + 长度），服务端走原密码路径，行为逐字节兼容；
 * - **传了 `email`**：走邮箱码路径，`username/password` 一并忽略（客户端因此可以只传
 *   `{ email, emailCode, role }`，无需伪造 username）；
 * - `email: ''`（空串）按「未传」处理（`!o.email` 为真）→ 老路径，不会出现"空邮箱登录"这种半开状态；
 * - `role` 仍然**必填且取值不变**：邮箱码登录同样要声明端角色，服务端会校验「邮箱绑定的账号角色 = role」
 *   （与密码登录同一条既有校验，见 `AuthService.login`）。
 */
export class LoginDto {
  @ApiProperty({ description: '账号（邮箱验证码登录时可不传）', required: false })
  @ValidateIf((o: LoginDto) => !o.email)
  @IsString()
  @Length(1, 32)
  username?: string;

  @ApiProperty({ description: '密码（邮箱验证码登录时可不传）', required: false })
  @ValidateIf((o: LoginDto) => !o.email)
  @IsString()
  @Length(1, 64)
  password?: string;

  @ApiProperty({ description: '端角色：user/worker/admin（与实际账号不符返回 403）' })
  @IsIn(['user', 'worker', 'admin'])
  role: string;

  @ApiProperty({
    description: '邮箱（可选；传了它即走「邮箱验证码登录」，忽略 username/password）',
    required: false,
  })
  @IsOptional()
  @IsString()
  // 文案不带字段名（全局管道会拼上「邮箱」标签，见 RegisterDto 的同款注释）
  @IsEmail({}, { message: '格式不正确' })
  @Length(1, 120)
  email?: string;

  /**
   * 邮箱验证码（6 位数字）。
   * 刻意用 `@IsOptional()` 而不是"传了 email 就必填"：**「缺验证码」与「码不对」要落到同一类失败**，
   * 由服务层统一成中文 400（避免同一路径出现两套文案，也避免泄露"这个邮箱到底存不存在"）。
   */
  @ApiProperty({ description: '邮箱验证码（6 位数字；传了 email 时必填）', required: false })
  @IsOptional()
  @IsString()
  @Matches(/^\d{6}$/, { message: '须为 6 位数字' })
  emailCode?: string;
}

export class RefreshDto {
  @ApiProperty({ description: 'refresh token' })
  @IsString()
  refreshToken: string;
}

export class LogoutDto {
  @ApiProperty({ description: 'refresh token（可选，传入则一并吊销）', required: false })
  @IsOptional()
  @IsString()
  refreshToken?: string;
}

/** 获取邮箱验证码（负责人 2026-10-05；2026-10-10 扩展 bind/login 两个场景） */
export class SendEmailCodeDto {
  @ApiProperty({ description: '邮箱' })
  @IsString()
  @IsEmail({}, { message: '格式不正确' })
  @Length(1, 120)
  email: string;

  @ApiProperty({
    description: '场景：register=注册 / reset=找回密码 / bind=绑定换绑邮箱 / login=邮箱验证码登录',
  })
  @IsIn(['register', 'reset', 'bind', 'login'], { message: '只能是：register、reset、bind、login' })
  scene: 'register' | 'reset' | 'bind' | 'login';
}

/**
 * 绑定 / 换绑邮箱（负责人 2026-10-10 拍板 2：**当前密码 + 新邮箱验证码**，不是旧邮箱码）。
 *
 * 三要素缺一不可：`email`（要绑的新邮箱）+ `emailCode`（发给新邮箱的 6 位码，scene=bind）+ `password`（当前登录密码）。
 * 绑定与换绑**同一个接口、同一套校验**（换绑 = 覆盖旧邮箱，语义写在服务层与审计里）。
 */
export class BindEmailDto {
  @ApiProperty({ description: '要绑定/换绑到的邮箱' })
  @IsString()
  @IsEmail({}, { message: '格式不正确' })
  @Length(1, 120)
  email: string;

  @ApiProperty({ description: '新邮箱收到的验证码（6 位数字）' })
  @IsString()
  @Matches(/^\d{6}$/, { message: '须为 6 位数字' })
  emailCode: string;

  /**
   * 当前登录密码。长度沿用登录口径（1-64）而非新密码口径（8-64）：
   * 历史账号的密码规则由登录侧决定，这里只是"再确认一次是你本人"，不能比登录更严。
   */
  @ApiProperty({ description: '当前登录密码（校验失败 → 中文 400「密码错误」）' })
  @IsString()
  @Length(1, 64)
  password: string;
}

/**
 * QQ 登录 / 绑定入参（2026-10-10）。
 *
 * ⚠️ **`openid` 只用于比对**：服务端一律用 `accessToken` 调腾讯 `oauth2.0/me` 取权威 openid，
 * 客户端传的这一个只做一致性校验（不一致 → 中文 400），**绝不作为身份依据**
 * （客户端数据全部不可信铁律；docs/04「QQ 登录」）。
 *
 * 字段命名：`accessToken` 为本仓库 DTO 的既有驼峰口径（refreshToken / emailCode / oldPassword…），
 * 同时接受腾讯文档里的下划线写法 `access_token` 作为**别名**（两者都给时以 `accessToken` 为准），
 * 免得未来的客户端按腾讯文档原样传参就被 `forbidNonWhitelisted` 判 400。
 */
export class QqLoginDto {
  @ApiProperty({ description: 'QQ 授权返回的 access_token（服务端据此复核 openid）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 512)
  accessToken?: string;

  @ApiProperty({ description: 'access_token 的下划线别名（与 accessToken 二选一）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 512)
  access_token?: string;

  @ApiProperty({ description: '客户端拿到的 openid（仅用于与服务端复核结果比对）', required: false })
  @IsOptional()
  @IsString()
  @Length(1, 64)
  openid?: string;
}

/**
 * 已登录时把 QQ 绑到当前账号（`POST /auth/qq/bind`）：入参与 [QqLoginDto] 完全一致。
 * 主体 id 只取 JWT（`sub`），请求体里没有也不需要 userId。
 */
export class QqBindDto extends QqLoginDto {}

/** 找回密码（邮箱验证码，负责人 2026-10-05）：不依赖旧密码 */
export class ResetPasswordDto {
  @ApiProperty({ description: '注册邮箱' })
  @IsString()
  @IsEmail({}, { message: '格式不正确' })
  @Length(1, 120)
  email: string;

  @ApiProperty({ description: '邮箱验证码（6 位数字）' })
  @IsString()
  @Matches(/^\d{6}$/, { message: '须为 6 位数字' })
  emailCode: string;

  @ApiProperty({ description: '新密码：8-64 位（沿用既有密码规则）' })
  @IsString()
  @Length(8, 64, { message: '须为 8-64 位' })
  newPassword: string;
}
