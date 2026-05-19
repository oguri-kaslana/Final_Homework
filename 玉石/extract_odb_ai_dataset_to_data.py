# -*- coding: utf-8 -*-
# Abaqus ODB batch post-processing script
# File: extract_odb_ai_dataset_to_data.py
#
# 功能：
#   批量扫描 D:\A_homework\Stone_simulation\RESULTS 中的 .odb 文件，
#   根据文件名 H0p2A30_时间.odb 自动解析跌落高度 H 和角度 A，
#   提取最大主应力峰值、峰值时刻、最小主应力、最大位移、能量数据，
#   并输出 AI 训练用 CSV 数据表到：
#       D:\A_homework\Stone_simulation\RESULTS\data
#
# 推荐运行方式：
#   abaqus python extract_odb_ai_dataset_to_data.py
#
# 或：
#   abaqus cae noGUI=extract_odb_ai_dataset_to_data.py


from odbAccess import openOdb
from abaqusConstants import *
import os
import csv
import math
import re
import datetime
import traceback


# ============================================================
# 0. USER PARAMETERS
# ============================================================

# ODB 所在文件夹：你的 Job 输出目录
ODB_DIR = r"D:\A_homework\Stone_simulation\RESULTS"

# 数据表输出文件夹
OUTPUT_DIR = r"D:\A_homework\Stone_simulation\RESULTS\data"

# 输出文件名
RUN_TAG = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
OUTPUT_CSV = "bangle_drop_ai_dataset_%s.csv" % RUN_TAG

# 同时输出一个固定名字的 latest 文件，方便后续 AI 脚本读取
OUTPUT_CSV_LATEST = "bangle_drop_ai_dataset_latest.csv"

# 分析步名称
# 如果 ODB 中没有这个 step，脚本会自动使用第一个分析步
STEP_NAME = "Step-1"

# 单位：mm, s, MPa
G_MM = 9800.0

# 如果文件名中没有 MU，则默认摩擦系数取 0.1
DEFAULT_MU = 0.10

# 参考抗拉强度，用于计算开裂风险系数 R_t = S1_max / SIGMA_T_REF
SIGMA_T_REF = 30.0

# 是否跳过不完整或打不开的 ODB
SKIP_FAILED_ODB = True


# ============================================================
# 1. FILE NAME PARSING
# ============================================================

def tag_to_float(text):
    """
    将 Job 文件名中的数字标签转成 float。
    例如：
        "1"   -> 1.0
        "0p2" -> 0.2
        "0p5" -> 0.5
        "m1p5" -> -1.5
    """
    text = str(text)
    text = text.replace("m", "-").replace("p", ".")
    return float(text)


def parse_case_from_odb_name(odb_name):
    """
    支持的文件名格式：
        H0p2A0_20260517_201800.odb
        H0p2A30_20260517_201800.odb
        H1A90_20260517_201800.odb
        H1A45MU0p1_20260517_201800.odb

    返回：
        case_id, h_m, theta_deg, mu
    """
    base = os.path.splitext(os.path.basename(odb_name))[0]

    # 去掉最后的时间戳：H0p2A30_20260517_201800 -> H0p2A30
    parts = base.split("_")
    if len(parts) >= 3 and parts[-1].isdigit() and parts[-2].isdigit():
        case_id = "_".join(parts[:-2])
    else:
        case_id = base

    # 解析 H、A、可选 MU
    pattern = r"H(?P<h>[0-9mp\.\-]+)A(?P<a>[0-9mp\.\-]+)(MU(?P<mu>[0-9mp\.\-]+))?"
    m = re.search(pattern, case_id)

    if m is None:
        return case_id, None, None, DEFAULT_MU

    h_m = tag_to_float(m.group("h"))
    theta_deg = tag_to_float(m.group("a"))

    if m.group("mu") is None:
        mu = DEFAULT_MU
    else:
        mu = tag_to_float(m.group("mu"))

    return case_id, h_m, theta_deg, mu


def drop_height_to_velocity(h_m):
    """
    根据跌落高度计算初速度：
        v = sqrt(2 g h)
    h_m 单位 m，返回 mm/s
    """
    if h_m is None:
        return None
    h_mm = h_m * 1000.0
    return math.sqrt(2.0 * G_MM * h_mm)


def list_odb_files(folder):
    odb_files = []
    for fn in os.listdir(folder):
        if fn.lower().endswith(".odb"):
            odb_files.append(os.path.join(folder, fn))
    odb_files.sort()
    return odb_files


# ============================================================
# 2. ODB FIELD OUTPUT EXTRACTION
# ============================================================

def get_analysis_step(odb):
    if STEP_NAME in odb.steps.keys():
        return odb.steps[STEP_NAME]
    return odb.steps[odb.steps.keys()[0]]


def scalar_field_max(field):
    max_val = None
    for item in field.values:
        try:
            val = float(item.data)
            if max_val is None or val > max_val:
                max_val = val
        except:
            pass
    return max_val


def scalar_field_min(field):
    min_val = None
    for item in field.values:
        try:
            val = float(item.data)
            if min_val is None or val < min_val:
                min_val = val
        except:
            pass
    return min_val


def vector_field_max_magnitude(field):
    max_mag = None
    for item in field.values:
        try:
            data = item.data
            mag2 = 0.0
            for x in data:
                mag2 += float(x) ** 2
            mag = math.sqrt(mag2)
            if max_mag is None or mag > max_mag:
                max_mag = mag
        except:
            pass
    return max_mag


def find_peak_s1_frame(step):
    """
    扫描所有帧，找到全过程最大主应力 S1 的峰值帧。
    返回：
        peak_frame_index, peak_time_s, S1_max_MPa
    """
    best_idx = None
    best_time = None
    best_s1 = None

    for i, frame in enumerate(step.frames):
        if "S" not in frame.fieldOutputs.keys():
            continue

        try:
            s_field = frame.fieldOutputs["S"]
            s1_field = s_field.getScalarField(invariant=MAX_PRINCIPAL)
            s1_max = scalar_field_max(s1_field)

            if s1_max is None:
                continue

            if best_s1 is None or s1_max > best_s1:
                best_s1 = s1_max
                best_idx = i
                best_time = float(frame.frameValue)
        except:
            continue

    # 如果没有应力输出，则退回最后一帧
    if best_idx is None:
        best_idx = len(step.frames) - 1
        best_time = float(step.frames[best_idx].frameValue)
        best_s1 = None

    return best_idx, best_time, best_s1


def extract_values_at_frame(step, frame_idx):
    """
    在 S1 峰值帧提取：
        S3_min, U_max, CPRESS_max
    """
    frame = step.frames[frame_idx]

    s3_min = None
    u_max = None
    cpress_max = None

    if "S" in frame.fieldOutputs.keys():
        try:
            s_field = frame.fieldOutputs["S"]
            s3_field = s_field.getScalarField(invariant=MIN_PRINCIPAL)
            s3_min = scalar_field_min(s3_field)
        except:
            s3_min = None

    if "U" in frame.fieldOutputs.keys():
        try:
            u_field = frame.fieldOutputs["U"]
            u_max = vector_field_max_magnitude(u_field)
        except:
            u_max = None

    # 如果 ODB 中存在 CPRESS，则提取最大接触压力
    if "CPRESS" in frame.fieldOutputs.keys():
        try:
            cp_field = frame.fieldOutputs["CPRESS"]
            cpress_max = scalar_field_max(cp_field)
        except:
            cpress_max = None

    return s3_min, u_max, cpress_max


# ============================================================
# 3. HISTORY OUTPUT EXTRACTION
# ============================================================

def collect_history_data(odb, variable_name):
    """
    在所有 history region 中搜索变量，例如 ALLKE、ALLIE、ETOTAL。
    返回 [(time, value), ...]
    """
    data_all = []

    for step_name in odb.steps.keys():
        step = odb.steps[step_name]
        for region_name in step.historyRegions.keys():
            region = step.historyRegions[region_name]
            if variable_name in region.historyOutputs.keys():
                data = region.historyOutputs[variable_name].data
                for t, v in data:
                    data_all.append((float(t), float(v)))

    data_all.sort(key=lambda pair: pair[0])
    return data_all


def hist_first(data):
    if len(data) == 0:
        return None
    return data[0][1]


def hist_last(data):
    if len(data) == 0:
        return None
    return data[-1][1]


def hist_max(data):
    if len(data) == 0:
        return None
    return max([v for t, v in data])


def hist_min(data):
    if len(data) == 0:
        return None
    return min([v for t, v in data])


def calc_relative_error_percent(initial, final):
    if initial is None or final is None:
        return None
    denom = max(abs(initial), 1.0e-12)
    return abs(final - initial) / denom * 100.0


def calc_ratio_percent(num, den):
    if num is None or den is None:
        return None
    if abs(den) < 1.0e-12:
        return None
    return num / den * 100.0


# ============================================================
# 4. RISK ASSESSMENT
# ============================================================

def get_risk_level(rt):
    if rt is None:
        return ""
    if rt < 0.5:
        return "Low"
    elif rt < 1.0:
        return "Medium"
    else:
        return "High"


# ============================================================
# 5. PROCESS ONE ODB
# ============================================================

def process_one_odb(odb_path):
    odb_file = os.path.basename(odb_path)
    case_id, h_m, theta_deg, mu = parse_case_from_odb_name(odb_file)
    v0 = drop_height_to_velocity(h_m)

    print("")
    print("------------------------------------------------------------")
    print("Processing ODB: %s" % odb_file)
    print("  case_id   = %s" % case_id)
    print("  h_m       = %s" % str(h_m))
    print("  angle_deg = %s" % str(theta_deg))
    print("  mu        = %s" % str(mu))
    print("  v0_mm_s   = %s" % str(v0))

    odb = openOdb(path=odb_path, readOnly=True)

    try:
        step = get_analysis_step(odb)

        peak_frame, t_peak_s, s1_max = find_peak_s1_frame(step)
        s3_min, u_max, cpress_max = extract_values_at_frame(step, peak_frame)

        # History variables
        allke = collect_history_data(odb, "ALLKE")
        allie = collect_history_data(odb, "ALLIE")
        allae = collect_history_data(odb, "ALLAE")
        allse = collect_history_data(odb, "ALLSE")
        allwk = collect_history_data(odb, "ALLWK")
        etotal = collect_history_data(odb, "ETOTAL")

        allke_initial = hist_first(allke)
        allke_max = hist_max(allke)
        allie_max = hist_max(allie)
        allae_max = hist_max(allae)
        allse_max = hist_max(allse)
        allwk_final = hist_last(allwk)

        etotal_initial = hist_first(etotal)
        etotal_final = hist_last(etotal)
        etotal_error_pct = calc_relative_error_percent(etotal_initial, etotal_final)
        allae_allie_pct = calc_ratio_percent(allae_max, allie_max)

        if s1_max is None:
            rt = None
        else:
            rt = s1_max / SIGMA_T_REF

        risk_level = get_risk_level(rt)

        row = {
            "odb_file": odb_file,
            "case_id": case_id,

            "h_m": h_m,
            "theta_deg": theta_deg,
            "mu": mu,
            "v0_mm_s": v0,

            "peak_frame": peak_frame,
            "t_peak_s": t_peak_s,
            "t_peak_ms": None if t_peak_s is None else t_peak_s * 1000.0,

            "S1_max_MPa": s1_max,
            "S3_min_MPa_at_S1_peak": s3_min,
            "U_max_mm_at_S1_peak": u_max,
            "CPRESS_max_MPa_at_S1_peak": cpress_max,

            "ALLKE_initial": allke_initial,
            "ALLKE_max": allke_max,
            "ALLIE_max": allie_max,
            "ALLAE_max": allae_max,
            "ALLSE_max": allse_max,
            "ALLWK_final": allwk_final,

            "ETOTAL_initial": etotal_initial,
            "ETOTAL_final": etotal_final,
            "ETOTAL_error_pct": etotal_error_pct,
            "ALLAE_ALLIE_pct": allae_allie_pct,

            "sigma_t_ref_MPa": SIGMA_T_REF,
            "R_t": rt,
            "risk_level": risk_level
        }

        print("  peak_frame = %s" % str(peak_frame))
        print("  t_peak_s   = %s" % str(t_peak_s))
        print("  S1_max     = %s MPa" % str(s1_max))
        print("  R_t        = %s" % str(rt))
        print("  risk       = %s" % risk_level)

        return row

    finally:
        odb.close()


# ============================================================
# 6. CSV OUTPUT
# ============================================================

def write_csv(rows, csv_path):
    columns = [
        "odb_file",
        "case_id",

        "h_m",
        "theta_deg",
        "mu",
        "v0_mm_s",

        "peak_frame",
        "t_peak_s",
        "t_peak_ms",

        "S1_max_MPa",
        "S3_min_MPa_at_S1_peak",
        "U_max_mm_at_S1_peak",
        "CPRESS_max_MPa_at_S1_peak",

        "ALLKE_initial",
        "ALLKE_max",
        "ALLIE_max",
        "ALLAE_max",
        "ALLSE_max",
        "ALLWK_final",

        "ETOTAL_initial",
        "ETOTAL_final",
        "ETOTAL_error_pct",
        "ALLAE_ALLIE_pct",

        "sigma_t_ref_MPa",
        "R_t",
        "risk_level"
    ]

    f = open(csv_path, "w")
    try:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    finally:
        f.close()


# ============================================================
# 7. MAIN
# ============================================================

def main():
    if not os.path.isdir(ODB_DIR):
        raise RuntimeError("ODB_DIR does not exist: %s" % ODB_DIR)

    if not os.path.isdir(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)

    odb_files = list_odb_files(ODB_DIR)

    if len(odb_files) == 0:
        print("No ODB files found in: %s" % ODB_DIR)
        return

    print("============================================================")
    print("ODB_DIR    : %s" % ODB_DIR)
    print("OUTPUT_DIR : %s" % OUTPUT_DIR)
    print("ODB count  : %d" % len(odb_files))
    print("============================================================")

    rows = []
    failed = []

    for odb_path in odb_files:
        try:
            row = process_one_odb(odb_path)
            rows.append(row)
        except Exception:
            print("")
            print("Failed to process: %s" % odb_path)
            traceback.print_exc()
            failed.append(os.path.basename(odb_path))
            if not SKIP_FAILED_ODB:
                raise

    output_csv_path = os.path.join(OUTPUT_DIR, OUTPUT_CSV)
    latest_csv_path = os.path.join(OUTPUT_DIR, OUTPUT_CSV_LATEST)

    write_csv(rows, output_csv_path)
    write_csv(rows, latest_csv_path)

    # 输出失败列表
    failed_log = os.path.join(OUTPUT_DIR, "failed_odb_%s.txt" % RUN_TAG)
    f = open(failed_log, "w")
    try:
        for name in failed:
            f.write(name + "\n")
    finally:
        f.close()

    print("")
    print("================================================------------")
    print("Finished extracting AI dataset.")
    print("Processed ODB count : %d" % len(rows))
    print("Failed ODB count    : %d" % len(failed))
    print("CSV output          : %s" % output_csv_path)
    print("Latest CSV          : %s" % latest_csv_path)
    print("Failed log          : %s" % failed_log)
    print("============================================================")


main()
