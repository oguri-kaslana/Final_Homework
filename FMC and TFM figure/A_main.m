clear; clc; close all;

%% =========================================================
%  A_main.m
%  FMC-TFM 成像主程序
%
%  数据约定：
%      fmc(sample, tx, rx)
%
%  当前主流程：
%      1. 直接读取 fmc.mat
%      2. FMC 预处理
%      3. 全局 TFM 成像
%      4. 缺陷 ROI 提取
%      5. 局部 TFM 成像
%      6. 缺陷特征分析
%      7. 图像显示与结果保存
%% =========================================================


%% ================== 0. 路径设置 ==================

project_root = fileparts(mfilename('fullpath'));
% 当前 A_main.m 所在目录。
% 建议所有函数文件都放在该目录或其子目录中。

addpath(genpath(project_root));
% 将项目目录及子目录加入 MATLAB 搜索路径。

fmc_file = fullfile(project_root, '..', 'fmc.mat');
% 原始 FMC 数据路径。
% 这里默认 fmc.mat 位于 A_main.m 所在文件夹的上一级目录。
% 如果你的 fmc.mat 不在这里，直接修改此路径即可。

result_root = fullfile(project_root, 'results');
% 结果保存根目录。
% TFM 图像、mask、特征表、参数文件等会保存到该目录下。


%% ================== 1. 标准化函数暂不作为正式流程 ==================

% standardize_fmc_data();
% 当前不正式调用 standardize_fmc_data。
% 原因：
%   1. 你的 fmc.mat 结构已经清楚；
%   2. fmc 数据格式确定为 fmc(sample, tx, rx)；
%   3. 声速、采样率、阵元间距等参数由你在 main 中手动指定。


%% ================== 2. 读取 FMC 数据 ==================

S = load(fmc_file);

if ~isfield(S, 'fmc')
    error('fmc.mat 中没有找到变量 fmc，请检查变量名。');
end

fmc = S.fmc;

[nSamples, nTx, nRx] = size(fmc);

fprintf('FMC 数据尺寸：%d × %d × %d\n', nSamples, nTx, nRx);
fprintf('数据格式约定：fmc(sample, tx, rx)\n');


%% ================== 3. 基础物理参数 ==================

params.basic.fs = 100e6;
% 采样频率，单位 Hz。
% 典型值：50e6、100e6、200e6。
% 作用：决定时间采样间隔 dt = 1 / fs。
% 如果设置错误，传播时间对应的采样点会错误，导致缺陷位置偏移或图像模糊。

params.basic.c = 5900;
% 材料纵波声速，单位 m/s。
% 典型值：
%   钢：约 5900 m/s
%   铝：约 6300 m/s
%   复合材料：需要根据方向和实验标定
% 调大：同一回波时间会被解释成更深位置。
% 调小：同一回波时间会被解释成更浅位置。

params.basic.pitch = 0.6e-3;
% 阵元间距，单位 m。
% 0.6e-3 表示 0.6 mm。
% 作用：决定阵元横向坐标。
% 设置错误会导致横向聚焦位置不准。

params.basic.dt = 1 / params.basic.fs;
% 采样时间间隔，单位 s。

time = (0:nSamples-1).' * params.basic.dt;
% FMC 信号时间轴，单位 s。

x_el = ((1:nTx) - (nTx + 1) / 2) * params.basic.pitch;
% 阵元横向坐标，单位 m。
% 阵列中心约位于 x = 0。


%% ================== 4. FMC 预处理参数 ==================

params.pre.remove_dc = true;
% 是否去除每条 A 扫信号的直流分量。
% true：推荐，信号围绕 0 振荡，适合滤波和成像。
% false：保留原始偏置，一般只用于对比测试。

params.pre.use_bandpass = true;
% 是否进行带通滤波。
% true：去除低频漂移和高频噪声。
% false：保留原始频率成分，适合调试对比。

params.pre.filter_order = 4;
% Butterworth 带通滤波器阶数。
% 典型值：2、4、6。
% 调大：滤波过渡更陡，但可能引入更强边界效应。
% 调小：滤波更温和，但噪声抑制能力下降。

params.pre.f_low = 1e6;
% 带通滤波下限频率，单位 Hz。
% 调大：低频漂移减少，但可能损失有效低频回波。
% 调小：保留更多低频信息，但背景噪声可能更重。

params.pre.f_high = 10e6;
% 带通滤波上限频率，单位 Hz。
% 调大：保留更多高频细节，但高频噪声可能增加。
% 调小：图像更平滑，但缺陷边界可能变模糊。

params.pre.use_envelope = false;
% 是否在 FMC 预处理阶段做 Hilbert 包络。
% true：每条 A 扫信号变为正幅值，图像更平滑。
% false：保留相位信息，更适合相干 TFM 叠加。
% 建议：先设为 false，在 TFM 后处理阶段统一 abs 或 dB 显示。

params.pre.normalize_fmc = false;
% 是否对整个 FMC 数据做幅值归一化。
% true：所有信号最大幅值归一到 1，便于不同数据对比。
% false：保留原始相对幅值关系。
% 建议：正式成像可先 false，图像阶段再归一化。

params.pre.output_class = 'single';
% 预处理后数据类型。
% 'single'：内存更小，速度通常更快，适合大规模 TFM。
% 'double'：精度更高，但占用更多内存。
% 当前建议 single，若你怀疑精度问题可改为 double。


%% ================== 5. TFM 运行模式参数 ==================

params.run.backend = 'cpu';
% TFM 计算后端。
% 可选：
%   'cpu'：调用 tfm_cpu_fast_core
%   'gpu'：调用 tfm_gpu_fast_core
% 建议先用 'cpu' 跑通，再改 'gpu' 对比速度和结果。

params.run.use_auto_roi = true;
% 是否根据全局 TFM 自动提取局部 ROI。
% true：先全局 TFM，再缺陷提取，然后局部 TFM。
% false：使用 params.local.x_range 和 params.local.z_range 手动指定局部范围。

params.run.show_figures = true;
% 是否显示图像。
% true：运行后显示全局和局部 TFM 图。
% false：只计算和保存，不弹出图窗。


%% ================== 6. 全局 TFM 参数 ==================

params.global.x_range = [-20e-3, 20e-3];
% 全局成像横向范围，单位 m。
% 范围越大：观察区域越宽，但同样像素数下分辨率降低。
% 范围越小：细节更清楚，但可能漏掉缺陷。

params.global.z_range = [0e-3, 40e-3];
% 全局成像深度范围，单位 m。
% z = 0 通常表示阵列表面或检测起始面。
% 范围过大：计算量增加，背景区域变多。
% 范围过小：可能漏掉深层缺陷。

params.global.nx = 400;
% 全局图像 x 方向像素数。
% 调大：横向采样更密，图像更细，但计算量增加。
% 调小：速度更快，但图像更粗糙。

params.global.nz = 400;
% 全局图像 z 方向像素数。
% 调大：深度方向采样更密，但计算量增加。
% 调小：速度更快，但可能看不清缺陷边界。

params.global.block_size = 1500;
% TFM 分块向量化时每个 block 的像素点数量。
% 调大：矩阵化程度更高，可能更快，但内存/GPU 显存占用增加。
% 调小：更省内存，但 block 数增加，可能变慢。
% 如果内存不足，可改为 500 或 1000。

params.global.channel_block_size = 512;
% 每次处理的 tx-rx 通道数量。
% 64×64 FMC 一共有 4096 个通道。
% 调大：通道方向向量化更充分，可能更快，但内存占用更高。
% 调小：更省内存，但通道循环次数增加。

params.global.use_parfor = true;
% CPU 版本是否使用 parfor 并行。
% true：多核 CPU 加速。
% false：普通 for 循环，便于调试或没有并行工具箱时使用。

params.global.calc_class = 'single';
% TFM 核心计算数据类型。
% 'single'：速度快、内存低。
% 'double'：精度高、内存大。
% 建议默认 single；若结果异常可改 double 对比。


%% ================== 7. 局部 TFM 参数 ==================

params.local.x_range = [5e-3, 15e-3];
% 手动局部成像横向范围，单位 m。
% 仅当 params.run.use_auto_roi = false 时使用。
% 如果自动 ROI 打开，则该参数会被缺陷提取结果覆盖。

params.local.z_range = [15e-3, 30e-3];
% 手动局部成像深度范围，单位 m。
% 仅当 params.run.use_auto_roi = false 时使用。

params.local.nx = 300;
% 局部 TFM x 方向像素数。
% 调大：局部细节更清楚，但计算量增加。
% 调小：速度更快，但图像更粗糙。

params.local.nz = 300;
% 局部 TFM z 方向像素数。
% 调大：深度方向更细。
% 调小：速度更快。

params.local.block_size = 1500;
% 局部 TFM 分块大小。
% 局部像素少时可适当调大。
% 如果 GPU 显存或 CPU 内存不够，应调小。

params.local.channel_block_size = 512;
% 局部 TFM 每次处理的 tx-rx 通道数量。
% 意义同 params.global.channel_block_size。

params.local.use_parfor = true;
% CPU 局部 TFM 是否使用 parfor。

params.local.calc_class = 'single';
% 局部 TFM 核心计算数据类型。


%% ================== 8. TFM 后处理参数 ==================

params.post.use_abs = true;
% 是否对 TFM 图像取绝对值。
% true：显示反射强度，适合缺陷识别。
% false：保留正负号，适合调试相干叠加结果。

params.post.normalize = true;
% 是否将 TFM 图像归一化到 0~1。
% true：便于显示、阈值提取和 AI 输入。
% false：保留原始幅值。

params.post.use_db = true;
% 是否生成 dB 图。
% true：适合人工观察和论文展示。
% false：只生成线性归一化图。

params.post.db_range = [-40, 0];
% dB 图显示范围，单位 dB。
% 典型值：[-40, 0] 或 [-60, 0]。
% 下限越低：弱信号显示更多，但背景噪声更明显。
% 下限越高：图像更干净，但弱缺陷可能看不到。


%% ================== 9. 缺陷区域提取参数 ==================

params.defect.threshold = 0.6;
% 缺陷提取阈值，范围 0~1。
% 调大：只保留强反射区域，误检少，但可能漏掉弱缺陷。
% 调小：保留更多疑似区域，但背景噪声和设备伪影也可能被提取。

params.defect.min_area = 50;
% 最小连通区域面积，单位：像素。
% 调大：过滤更多小噪声，但可能删掉小缺陷。
% 调小：保留小缺陷，但噪声区域可能增多。

params.defect.x_valid_range = params.global.x_range;
% 有效缺陷搜索横向范围，单位 m。
% 用于排除试件外部或边缘伪影。

params.defect.z_valid_range = [5e-3, params.global.z_range(2)];
% 有效缺陷搜索深度范围，单位 m。
% 重要：用于排除靠近上方的设备噪声、耦合伪影或表面强反射。
% 如果上方伪影明显，可适当增大下限，例如 8e-3 或 10e-3。

params.defect.margin_x = 2e-3;
% ROI 横向扩展距离，单位 m。
% 调大：局部 TFM 包含更多背景信息，但计算量增加。
% 调小：局部计算更快，但缺陷边缘可能被裁掉。

params.defect.margin_z = 2e-3;
% ROI 深度方向扩展距离，单位 m。
% 调大：缺陷上下文更完整，但计算量增加。

params.defect.use_largest_region_only = true;
% 是否只选择最大连通区域作为主要缺陷。
% true：适合当前只关注主要缺陷的情况。
% false：适合多缺陷场景，后续可扩展。


%% ================== 10. 缺陷特征分析参数 ==================

params.feature.min_area_pixel = 50;
% 参与特征分析的最小区域面积，单位：像素。
% 调大：特征更稳定，但可能忽略小缺陷。
% 调小：保留更多小区域，但容易受噪声影响。

params.feature.use_largest_region_only = true;
% 是否只分析最大连通域。
% true：适合只关注主要缺陷。
% false：适合多缺陷统计。

params.feature.unit_scale = 1e3;
% 长度单位换算系数。
% x_grid、z_grid 单位为 m 时，乘 1e3 转换为 mm。


%% ================== 11. 结果保存参数 ==================

params.save.output_root = result_root;
% 结果保存根目录。

params.save.case_name = ['case_', datestr(now, 'yyyymmdd_HHMMSS')];
% 当前实验名称。
% 自动加入时间，避免覆盖旧结果。

params.save.save_mat = true;
% 是否保存 MATLAB 原始变量。
% true：便于后续复现和分析，但文件较大。
% false：只保存图片和表格，节省空间。

params.save.save_png = true;
% 是否保存 PNG 图像。
% true：便于报告、论文和人工查看。

params.save.save_csv = true;
% 是否保存 CSV 表格。
% true：便于 Excel、Python 或 MATLAB 后续统计。

params.save.save_params = true;
% 是否保存参数结构体。
% true：强烈建议保留，便于复现实验。

params.save.image_dpi = 300;
% 导出带坐标轴图像的分辨率，单位 dpi。
% 150：快速查看。
% 300：报告常用。
% 600：论文高清图。
% 调大：更清晰，但文件更大、保存更慢。


%% ================== 12. FMC 预处理 ==================

fprintf('\n开始 FMC 预处理...\n');

tic;
fmc_pre = preprocess_fmc_data(fmc, params.basic.fs, params.pre);
time_preprocess = toc;

fprintf('FMC 预处理完成，用时 %.3f s\n', time_preprocess);


%% ================== 13. 全局 + 局部 TFM 成像 ==================

fprintf('\n开始 TFM 成像...\n');

results = run_tfm_global_local( ...
    fmc_pre, ...
    params.basic.fs, ...
    params.basic.c, ...
    x_el, ...
    params);

fprintf('TFM 成像完成。\n');


%% ================== 14. 缺陷特征分析 ==================

fprintf('\n开始缺陷特征分析...\n');

results.features = analyze_defect_features( ...
    results.img_global_norm, ...
    results.mask_global, ...
    results.x_grid_global, ...
    results.z_grid_global, ...
    params.feature);

disp(results.features);


%% ================== 15. 显示结果 ==================

if params.run.show_figures

    show_tfm_image( ...
        results.img_global_db, ...
        results.x_grid_global, ...
        results.z_grid_global, ...
        'Global TFM Image / dB', ...
        params.post);

    show_tfm_image( ...
        results.img_local_db, ...
        results.x_grid_local, ...
        results.z_grid_local, ...
        'Local TFM Image / dB', ...
        params.post);

    show_tfm_image( ...
        double(results.mask_global), ...
        results.x_grid_global, ...
        results.z_grid_global, ...
        'Detected Defect Mask', ...
        []);

end


%% ================== 16. 保存结果 ==================

results.time_preprocess = time_preprocess;
results.params = params;
results.time = time;
results.x_el = x_el;

save_tfm_results(results, params.save);

fprintf('\n全部流程完成。\n');
fprintf('结果保存目录：%s\n', fullfile(params.save.output_root, params.save.case_name));
