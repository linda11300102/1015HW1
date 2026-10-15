"""
從 sim/*.vcd 畫出報告用的波形圖（PNG），輸出到 wave/。
用法：在 hw1_bonus 目錄下執行  python3 scripts/plot_waves.py
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

sys.path.insert(0, os.path.dirname(__file__))
from vcd import parse_vcd, value_at, to_int  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..")

# 中文字型（找不到就用預設字型）
_names = sorted({f.name for f in font_manager.fontManager.ttflist})
for fam in ["Noto Sans CJK TC", "Noto Sans TC", "Microsoft JhengHei", "PingFang TC",
            "Noto Sans CJK JP", "Noto Sans CJK SC", "Noto Sans CJK KR"]:
    if fam in _names:
        plt.rcParams["font.family"] = fam
        break
else:   # 最後手段：任何名稱含 CJK 的字型
    _cjk = [n for n in _names if "CJK" in n]
    if _cjk:
        plt.rcParams["font.family"] = _cjk[0]

C_LINE = "#1f4e79"
C_BUS = "#e8f0f8"
C_STATE = "#fdf0e6"
C_STATE_EDGE = "#b5541c"
C_X = "#dddddd"
C_BAND = ["#eef6ee", "#f6eef6", "#eef2f8", "#f8f4e8"]


def fmt_bus(v, width):
    n = to_int(v)
    if n is None:
        return None
    if width <= 4:
        return str(n)
    return f"{n:X}"


def draw_bit(ax, chg, y, t0, t1, h=0.6):
    pts_t, pts_v = [t0], [value_at(chg, t0 * 1000)]
    for tt, vv in chg:
        tns = tt / 1000
        if t0 < tns < t1:
            pts_t.append(tns)
            pts_v.append(vv)
    pts_t.append(t1)
    for i in range(len(pts_v)):
        a, b = pts_t[i], pts_t[i + 1]
        v = pts_v[i]
        if v in "xXzZ":
            ax.fill_between([a, b], y, y + h, color=C_X, lw=0)
            continue
        yy = y + (h if v == "1" else 0)
        ax.plot([a, b], [yy, yy], color=C_LINE, lw=1.4)
        if i + 1 < len(pts_v) and pts_v[i + 1] not in "xXzZ" and pts_v[i + 1] != v:
            ax.plot([b, b], [y, y + h], color=C_LINE, lw=1.4)


def draw_bus(ax, chg, y, t0, t1, width, names=None, h=0.6, fill=C_BUS, edge=C_LINE):
    segs = []
    cur = value_at(chg, t0 * 1000)
    start = t0
    for tt, vv in chg:
        tns = tt / 1000
        if t0 < tns < t1 and vv != cur:
            segs.append((start, tns, cur))
            start, cur = tns, vv
    segs.append((start, t1, cur))
    sl = min(1.2, (t1 - t0) / 250)       # 斜邊寬度
    for a, b, v in segs:
        n = to_int(v)
        if n is None:
            ax.fill_between([a, b], y, y + h, color=C_X, lw=0)
            continue
        poly_x = [a, a + sl, b - sl, b, b - sl, a + sl, a]
        poly_y = [y + h / 2, y + h, y + h, y + h / 2, y, y, y + h / 2]
        ax.fill(poly_x, poly_y, color=fill, ec=edge, lw=0.9)
        label = names.get(n, str(n)) if names else fmt_bus(v, width)
        span = b - a
        if label is not None and span > len(label) * (t1 - t0) / 230:
            ax.text((a + b) / 2, y + h / 2, label, ha="center", va="center", fontsize=7.5)


def plot(vcd_file, out_png, title, t0, t1, rows, bands=(), period=10):
    chg = parse_vcd(os.path.join(ROOT, vcd_file))
    n = len(rows)
    fig_h = 0.42 * n + 1.3
    fig, ax = plt.subplots(figsize=(14, fig_h))
    labels = []
    for i, row in enumerate(rows):
        label, sig, kind = row[0], row[1], row[2]
        y = (n - 1 - i) * 1.0
        c = chg[sig]
        if kind == "bit":
            draw_bit(ax, c, y, t0, t1)
        elif kind == "bus":
            draw_bus(ax, c, y, t0, t1, row[3] if len(row) > 3 else 32)
        elif kind == "state":
            draw_bus(ax, c, y, t0, t1, 8, names=row[3], fill=C_STATE, edge=C_STATE_EDGE)
        labels.append((y + 0.3, label))
    # 時脈邊緣格線
    t = (int(t0 // period) + 1) * period - period / 2
    while t < t1:
        if t > t0:
            ax.axvline(t, color="#c8c8c8", lw=0.5, ls=":", zorder=0)
        t += period
    # 測項區段底色與標籤
    for k, (a, b, txt) in enumerate(bands):
        ax.axvspan(a, b, color=C_BAND[k % len(C_BAND)], zorder=-1)
        ax.text((a + b) / 2, n - 0.15, txt, ha="center", va="bottom", fontsize=9, color="#333")
    ax.set_yticks([p for p, _ in labels])
    ax.set_yticklabels([l for _, l in labels], fontsize=8.5, family="monospace")
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.4, n + 0.35)
    ax.set_xlabel("time (ns)")
    ax.set_title(title, fontsize=12, loc="left")
    for s in ["top", "right", "left"]:
        ax.spines[s].set_visible(False)
    ax.tick_params(axis="y", length=0)
    fig.tight_layout()
    fig.savefig(os.path.join(ROOT, out_png), dpi=150)
    plt.close(fig)
    print("wrote", out_png)


# ---------------------------------------------------------------------------
AHBS = {0: "IDLE", 1: "WB_ACCESS", 2: "ERR1", 3: "ERR2"}
AHBM = {0: "IDLE", 1: "BUS_REQ", 2: "ADDR", 3: "DATA"}
AXIS = {0: "IDLE", 1: "W_DATA", 2: "W_RESP", 3: "R_WB", 4: "R_DATA"}
AXIM = {0: "IDLE", 1: "W_SEND", 2: "W_RESP", 3: "R_ADDR", 4: "R_DATA"}
HTR = {0: "IDLE", 1: "BUSY", 2: "NONSEQ", 3: "SEQ"}
HRS = {0: "OKAY", 1: "ERROR", 2: "RETRY", 3: "SPLIT"}


def main():
    os.makedirs(os.path.join(ROOT, "wave"), exist_ok=True)

    # ---------------- AHB slave ----------------
    p = "tb_ahb_slave_wrapper."
    rows = [
        ("HCLK", p + "HCLK", "bit"),
        ("HSEL", p + "HSEL", "bit"),
        ("HTRANS", p + "HTRANS", "state", HTR),
        ("HADDR", p + "HADDR", "bus"),
        ("HWRITE", p + "HWRITE", "bit"),
        ("HWDATA", p + "HWDATA", "bus"),
        ("HREADYOUT", p + "HREADYOUT", "bit"),
        ("HRESP", p + "HRESP", "state", HRS),
        ("HRDATA", p + "HRDATA", "bus"),
        ("FSM state", p + "dut.state", "state", AHBS),
        ("wb_stb_o", p + "wb_stb", "bit"),
        ("wb_adr_o", p + "wb_adr", "bus"),
        ("wb_ack_i", p + "wb_ack", "bit"),
        ("wb_err_i", p + "wb_err", "bit"),
    ]
    plot("sim/tb_ahb_slave_wrapper.vcd", "wave/1a_ahb_slave_burst.png",
         "AHB Slave Wrapper：INCR4 burst 寫入與讀取（每拍插入等待狀態）",
         122, 492, rows, bands=[(125, 290, "T2 burst 寫入 0x20~0x2C"),
                                (290, 490, "T2 burst 讀取 0x20~0x2C")])
    plot("sim/tb_ahb_slave_wrapper.vcd", "wave/1b_ahb_slave_error.png",
         "AHB Slave Wrapper：兩拍 ERROR 回應，之後恢復正常",
         462, 632, rows, bands=[(465, 530, "T3 讀不存在的暫存器"),
                                (530, 630, "T4 錯誤後再寫入/讀回")])

    # ---------------- AHB master ----------------
    p = "tb_ahb_master_wrapper."
    rows = [
        ("HCLK", p + "HCLK", "bit"),
        ("wb_stb_i", p + "wb_stb", "bit"),
        ("wb_we_i", p + "wb_we", "bit"),
        ("wb_adr_i", p + "wb_adr", "bus"),
        ("cpu_req", p + "cpu_req", "bit"),
        ("HBUSREQ", p + "m_HBUSREQ", "bit"),
        ("HGRANT", p + "HGRANT_dma", "bit"),
        ("FSM state", p + "dut.state", "state", AHBM),
        ("HTRANS", p + "HTRANS", "state", HTR),
        ("HADDR", p + "HADDR", "bus"),
        ("HREADY", p + "HREADY", "bit"),
        ("HRESP", p + "HRESP", "state", HRS),
        ("HRDATA", p + "HRDATA", "bus"),
        ("wb_ack_o", p + "wb_ack", "bit"),
        ("wb_err_o", p + "wb_err", "bit"),
    ]
    plot("sim/tb_ahb_master_wrapper.vcd", "wave/2a_ahb_master_arbitration.png",
         "AHB Master Wrapper：CPU 佔用匯流排時停在 BUS_REQ，取得 HGRANT 後才送位址",
         22, 202, rows, bands=[(25, 130, "T1 等待仲裁 -> 寫入 0x00"),
                               (130, 200, "T2 DMA 讀取來源")])
    plot("sim/tb_ahb_master_wrapper.vcd", "wave/2b_ahb_master_retry.png",
         "AHB Master Wrapper：寫入錯誤區收到 ERROR；讀取時收到 RETRY 後重新申請匯流排並重送",
         692, 892, rows, bands=[(695, 765, "T3 寫入錯誤區 -> wb_err"),
                                (765, 890, "T4 RETRY -> 重新申請並重送")])

    # ---------------- AXI slave ----------------
    p = "tb_axi_slave_wrapper."
    rows = [
        ("ACLK", p + "ACLK", "bit"),
        ("AWVALID", p + "AWVALID", "bit"),
        ("AWREADY", p + "AWREADY", "bit"),
        ("AWADDR", p + "AWADDR", "bus"),
        ("AWLEN", p + "AWLEN", "bus", 4),
        ("WVALID", p + "WVALID", "bit"),
        ("WREADY", p + "WREADY", "bit"),
        ("WLAST", p + "WLAST", "bit"),
        ("WDATA", p + "WDATA", "bus"),
        ("BVALID", p + "BVALID", "bit"),
        ("BREADY", p + "BREADY", "bit"),
        ("ARVALID", p + "ARVALID", "bit"),
        ("ARREADY", p + "ARREADY", "bit"),
        ("RVALID", p + "RVALID", "bit"),
        ("RREADY", p + "RREADY", "bit"),
        ("RLAST", p + "RLAST", "bit"),
        ("RDATA", p + "RDATA", "bus"),
        ("FSM state", p + "dut.state", "state", AXIS),
        ("wb_stb_o", p + "wb_stb", "bit"),
        ("wb_adr_o", p + "wb_adr", "bus"),
        ("wb_ack_i", p + "wb_ack", "bit"),
    ]
    plot("sim/tb_axi_slave_wrapper.vcd", "wave/3a_axi_slave_burst.png",
         "AXI Slave Wrapper：4 拍 burst 寫入與讀取（wrapper 自己遞增位址；讀取第 2 拍 RREADY 晚給，RVALID 保持等待）",
         142, 502, rows, bands=[(145, 295, "T2 burst 寫入 (AWLEN=3)"),
                                (295, 500, "T2 burst 讀取 (ARLEN=3)")])
    plot("sim/tb_axi_slave_wrapper.vcd", "wave/3b_axi_slave_priority.png",
         "AXI Slave Wrapper：AW 與 AR 同一拍到達，寫入優先，讀取等寫入完成後才被接受",
         622, 732, rows, bands=[(625, 680, "T4 寫入先服務"), (680, 730, "接著才服務讀取")])

    # ---------------- AXI master ----------------
    p = "tb_axi_master_wrapper."
    rows = [
        ("ACLK", p + "ACLK", "bit"),
        ("wb_stb_i", p + "wb_stb", "bit"),
        ("wb_we_i", p + "wb_we", "bit"),
        ("wb_adr_i", p + "wb_adr", "bus"),
        ("FSM state", p + "dut.state", "state", AXIM),
        ("AWVALID", p + "AWVALID", "bit"),
        ("AWREADY", p + "AWREADY", "bit"),
        ("WVALID", p + "WVALID", "bit"),
        ("WREADY", p + "WREADY", "bit"),
        ("aw_done", p + "dut.aw_done", "bit"),
        ("w_done", p + "dut.w_done", "bit"),
        ("BVALID", p + "BVALID", "bit"),
        ("BREADY", p + "BREADY", "bit"),
        ("ARVALID", p + "ARVALID", "bit"),
        ("ARREADY", p + "ARREADY", "bit"),
        ("RVALID", p + "RVALID", "bit"),
        ("RREADY", p + "RREADY", "bit"),
        ("RDATA", p + "RDATA", "bus"),
        ("wb_ack_o", p + "wb_ack", "bit"),
    ]
    plot("sim/tb_axi_master_wrapper.vcd", "wave/4a_axi_master_write_read.png",
         "AXI Master Wrapper：AW 與 W 同時送出；slave 先收 W、後給 AWREADY，wrapper 用旗標記錄，不會死結",
         22, 182, rows, bands=[(25, 115, "T1 寫入 0x00"), (115, 180, "T1 讀回 0x00")])


if __name__ == "__main__":
    main()
