"""界面与逻辑共用的小常量/小换算（谁都可能要，又不该归任何一边）。

设计约束：
1. 这里**只能放纯数据与纯函数**：不许 import Qt 控件、不许碰 self。放宽了就会变成
   第二个 main_window。
2. `TAG_TEXT` 是任务 tag → 中文名的唯一来源（日志、错误提示、忙态文案都查它），
   加新任务必须同时加 tag 文案，否则报错时只有英文 tag，现场看不懂。
"""

from __future__ import annotations

import regs

# 连续流刷新一次搬多少点：4096 点 = 1.15 ms @ 3.5 MSPS / 0.29 ms @ 12.5 MSPS。
# 抓包页按像素列包络绘制，点数多不影响重绘时间，只影响一次 numpy 切片。
STREAM_POINTS = 4096

# 任务 tag → 中文名（日志与错误提示用；缺了会退化成 tag 本身）
TAG_TEXT = {"bstatus": "读板上状态", "lutup": "写补偿表", "lutdump": "读补偿表",
            "check": "设备自检", "apply": "应用倍频", "pairs": "写极对数",
            "adv": "写高级参数", "status": "读告警状态", "clear": "清除锁存告警",
            "capture": "抓包", "stream": "开始连续流", "stream_go": "设备开流",
            "stream_stop": "停止连续流"}


def cfg_from_regs(raw):
    """原始寄存器字典（地址→16 位值）→ ABZ/UVW 面板要的解码配置。

    host/abz.py 的 set_regs() 收的是"解码后"的键（inter/div/pairs/zwidth），
    而任务读回的是原始地址字典，所以这里转一道。
    """
    if not raw:
        return {}
    inter, div = regs.decode_inter_div(raw.get(regs.REG_INTER0), raw.get(regs.REG_INTER1))
    pairs, _praw = regs.decode_pairs(raw.get(regs.REG_PAIRS))
    return {"inter": inter, "div": div, "pairs": pairs,
            "zwidth": regs.adv_field_value("zwidth", raw)}
