function pipeline_results = run_tfm_realtime_pipeline_demo(fmc_files, params)
%% =========================================================
% run_tfm_realtime_pipeline_demo
%
% 作用：
%   实时流水线成像示例接口。
%
% 思路：
%   第 k 帧：global TFM 处理当前 FMC_k
%   第 k-1 帧：local TFM 同时处理上一帧 ROI_{k-1}
%
% 注意：
%   这是实时框架示例，不建议一开始直接作为正式流程。
%   你需要先保证 A_main.m 中的普通顺序模式跑通。
%
% 输入：
%   fmc_files : cell 数组，每个元素是一个 fmc.mat 文件路径
%   params    : 与 A_main.m 中一致的参数结构体
%
% 输出：
%   pipeline_results : 每一帧的 global/local 结果摘要
%% =========================================================

if nargin < 2
    error('需要输入 fmc_files 和 params。');
end

num_frames = numel(fmc_files);

if num_frames < 1
    error('fmc_files 为空。');
end

pipeline_results = cell(num_frames, 1);

pool = gcp('nocreate');
if isempty(pool)
    pool = parpool('Processes', 2);
end

prev_fmc_pre = [];
prev_roi = [];
prev_frame_id = [];

for k = 1:num_frames

    fprintf('\n========== 实时流水线：第 %d 帧 ==========%s', k, newline);

    %% 读取当前帧 FMC
    S = load(fmc_files{k});
    if ~isfield(S, 'fmc')
        error('第 %d 帧文件中没有变量 fmc。', k);
    end

    fmc_k = S.fmc;
    [~, nTx, ~] = size(fmc_k);

    x_el = ((1:nTx) - (nTx + 1) / 2) * params.basic.pitch;

    %% 当前帧预处理
    fmc_pre_k = preprocess_fmc_data(fmc_k, params.basic.fs, params.pre);

    %% 后台启动当前帧 global TFM
    future_global = parfeval(pool, @run_global_only_for_pipeline, 1, ...
        fmc_pre_k, params.basic.fs, params.basic.c, x_el, params);

    %% 同时处理上一帧 local TFM
    future_local = [];
    if k > 1 && ~isempty(prev_fmc_pre) && ~isempty(prev_roi)
        future_local = parfeval(pool, @run_local_only_for_pipeline, 1, ...
            prev_fmc_pre, prev_roi, params.basic.fs, params.basic.c, x_el, params, prev_frame_id);
    end

    %% 取回当前帧 global 结果
    global_result_k = fetchOutputs(future_global);

    %% 取回上一帧 local 结果
    local_result_prev = [];
    if ~isempty(future_local)
        local_result_prev = fetchOutputs(future_local);
    end

    %% 保存摘要
    pipeline_results{k}.global = global_result_k;
    pipeline_results{k}.local_prev = local_result_prev;

    %% 更新缓存：当前帧变成下一次的上一帧
    prev_fmc_pre = fmc_pre_k;
    prev_roi = global_result_k.roi_range;
    prev_frame_id = k;

end

end


function global_result = run_global_only_for_pipeline(fmc_pre, fs, c, x_el, params)
%% 当前帧 global TFM + ROI 提取

x_grid_global = linspace(params.global.x_range(1), params.global.x_range(2), params.global.nx);
z_grid_global = linspace(params.global.z_range(1), params.global.z_range(2), params.global.nz);

switch lower(params.run.backend)
    case 'cpu'
        tfm_core = @tfm_cpu_fast_core;
    case 'gpu'
        tfm_core = @tfm_gpu_fast_core;
    otherwise
        error('未知 backend。');
end

tic;
[img_global, info_global] = tfm_core(fmc_pre, fs, c, x_el, x_grid_global, z_grid_global, params.global);
time_global = toc;

[img_global_norm, img_global_db] = postprocess_tfm_image(img_global, params.post);

[mask_global, roi_range, defect_info] = extract_defect_region( ...
    img_global_norm, x_grid_global, z_grid_global, params.defect);

global_result = struct();
global_result.img_global = img_global;
global_result.img_global_norm = img_global_norm;
global_result.img_global_db = img_global_db;
global_result.mask_global = mask_global;
global_result.roi_range = roi_range;
global_result.defect_info = defect_info;
global_result.info_global = info_global;
global_result.time_global = time_global;
global_result.x_grid_global = x_grid_global;
global_result.z_grid_global = z_grid_global;

end


function local_result = run_local_only_for_pipeline(fmc_pre, roi_range, fs, c, x_el, params, frame_id)
%% 上一帧 local TFM

x_grid_local = linspace(roi_range.x(1), roi_range.x(2), params.local.nx);
z_grid_local = linspace(roi_range.z(1), roi_range.z(2), params.local.nz);

switch lower(params.run.backend)
    case 'cpu'
        tfm_core = @tfm_cpu_fast_core;
    case 'gpu'
        tfm_core = @tfm_gpu_fast_core;
    otherwise
        error('未知 backend。');
end

tic;
[img_local, info_local] = tfm_core(fmc_pre, fs, c, x_el, x_grid_local, z_grid_local, params.local);
time_local = toc;

[img_local_norm, img_local_db] = postprocess_tfm_image(img_local, params.post);

local_result = struct();
local_result.frame_id = frame_id;
local_result.img_local = img_local;
local_result.img_local_norm = img_local_norm;
local_result.img_local_db = img_local_db;
local_result.info_local = info_local;
local_result.time_local = time_local;
local_result.x_grid_local = x_grid_local;
local_result.z_grid_local = z_grid_local;

end
