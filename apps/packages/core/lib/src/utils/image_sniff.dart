/// 图片魔数嗅探（2026-10-18，为"头像/背景支持动图"配套）
///
/// ## 为什么客户端也要嗅一遍
/// 服务端 `media.service.ts` 已经按魔数决定"要不要 sharp 重编码"（gif 跳过，否则转码会
/// 杀掉动画）。但那是**事后**：等它把文件存成 jpeg、用户看到背景不动，已经很难反推
/// 是哪一环掉的。
///
/// 客户端在**传之前**看一眼首字节，能立刻回答三个问题：
/// 1. 这到底是不是图片（`pickMedia` 允许选视频，必须挡掉）；
/// 2. 用户以为的 gif 是不是真 gif（相册/系统组件可能已经把它转码成静态图）；
/// 3. 传给服务端的 `mime` 是不是和字节一致。
///
/// ## 只认这四种
/// 与服务端 `IMAGE_EXT_BY_MAGIC` 保持同一集合：gif / png / jpg / webp。
/// 别处新增格式时**两边一起加**，否则会出现"客户端放行、服务端拒绝"的割裂。
library;

import 'dart:typed_data';

/// 嗅出来的图片类型（紧凑枚举，避免到处传字符串）
enum ImageKind {
  gif('gif', true),
  png('png', false),
  jpg('jpg', false),
  webp('webp', false);

  const ImageKind(this.ext, this.animated);

  /// 与服务端一致的扩展名
  final String ext;

  /// 是否可能带动画（只有 gif 是；webp 也有动图但我们不区分，
  /// 保守标 false —— 识别成静态不会做出错误承诺）
  final bool animated;

  /// 给用户看的中文名
  String get label => switch (this) {
        ImageKind.gif => 'GIF 动图',
        ImageKind.png => 'PNG',
        ImageKind.jpg => 'JPEG 静态图',
        ImageKind.webp => 'WebP',
      };
}

/// 嗅探图片类型；不是这四种之一（含视频、损坏文件）返回 null
///
/// 只读前 12 字节，不做任何解码 —— 调用成本可以忽略。
ImageKind? sniffImageKind(Uint8List b) {
  if (b.length < 12) return null;

  // GIF87a / GIF89a
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return ImageKind.gif;

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return ImageKind.png;
  }

  // JPEG: FF D8 FF
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return ImageKind.jpg;

  // WebP: "RIFF"????"WEBP"
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return ImageKind.webp;
  }

  return null;
}

/// 文件名看起来是不是 gif（只看后缀，不读内容）
bool looksLikeGifName(String name) => name.toLowerCase().endsWith('.gif');

/// 是不是 mp4 视频（ISO BMFF：offset 4..8 == "ftyp"）
///
/// 加它的理由（2026-10-21）：负责人要「实况背景」。Android 的动态照片是
/// JPEG + 内嵌 mp4，外壳永远只有封面帧；用户从相册导出视频后文件名常常是
/// `MOV_1234` 甚至无扩展名 —— 只能靠魔数认。
///
/// 只认 ISO BMFF 家族的 `ftyp`（mp4/m4v/mov 都是），**不认** mkv/avi/ts：
/// 服务端 `sniffType` 也只放行 mp4，客户端先挡住能省一个来回。
bool looksLikeMp4(Uint8List b) {
  if (b.length < 12) return false;
  return b[4] == 0x66 && // f
      b[5] == 0x74 && // t
      b[6] == 0x79 && // y
      b[7] == 0x70; // p
}
