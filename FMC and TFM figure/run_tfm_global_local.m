function results = run_tfm_global_local(fmc_pre, fs, c, x_el, params)
%% =========================================================
% run_tfm_global_local
%
% 作用：
%   统一运行全局 TFM 和局部 TFM。
%   全局和局部共用同一个 TFM 核心函数，只是成像网格不同。
%
% 输入：
%   fmc_pre : 预处理后的 FMC 数据，格式 fmc(sample, tx, rx)
%   fs      : 采样频率，单位 Hz
%   c       : 声速，单位 m/s
%   x_el    : 阵元横向坐标，单位 m
%   params  : 总参数结构体
%
% 输出：
%   results : 包含全局图、局部图、ROI、运行时间等结果
%% =========================================================

%% ================== 选择计算后端 ==================

backend = lower(params.run.backend);

switch backend
    case 'cpu'
        tfm_core = @tfm_cpu_fast_core;

    case 'gpu'
        tfm_core = @tfm_gpu_fast_core;

    otherwise
        error('未知 TFM 后端：%s。应使用 cpu 或 gpu。', params.run.backend);
end


%% ================== 生成全局成像网格 ==================

x_grid_global = linspace( ...
    params.global.x_range(1), ...
    params.global.x_range(2), ...
    params.global.nx);

z_grid_global = linspace( ...
    params.global.z_range(1), ...
    params.global.z_range(2), ...
    params.global.nz);


%% ================== 全局 TFM 成像 ==================

fprintf('开始全局 TFM 成像，backend = %s ...\n', backend);

tic;
[img_global, info_global] = tfm_core( ...
    fmc_pre, fs, c, x_el, ...
    x_grid_global, z_grid_global, params.global);
time_global = toc;

fprintf('全局 TFM 用时：%.3f s\n', time_global);


%% ================== 全局图像后处理 ==================

[img_global_norm, img_global_db, img_global_abs] = ...
    postprocess_tfm_image(img_global, params.post);


%% ================== 获取局部 ROI ==================

if params.run.use_auto_roi

    [mask_global, roi_range, defect_info] = extract_defect_region( ...
        img_global_norm, ...
        x_grid_global, ...
        z_grid_global, ...
        params.defect);

else

    roi_range.x = params.local.x_range;
    roi_range.z = params.local.z_range;

    mask_global = false(size(img_global_norm));
    defect_info = struct();
    defect_info.message = '使用手动 ROI，未执行自动缺陷提取。';

end


%% ================== 生成局部成像网格 ==================

x_grid_local = linspace( ...
    roi_range.x(1), ...
    roi_range.x(2), ...
    params.local.nx);

z_grid_local = linspace( ...
    roi_range.z(1), ...
    roi_range.z(2), ...
    params.local.nz);


%% ================== 局部 TFM 成像 ==================

fprintf('开始局部 TFM 成像，backend = %s ...\n', backend);

tic;
[img_local, info_local] = tfm_core( ...
    fmc_pre, fs, c, x_el, ...
    x_grid_local, z_grid_local, params.local);
time_local = toc;

fprintf('局部 TFM 用时：%.3f s\n', time_local);


%% ================== 局部图像后处理 ==================

[img_local_norm, img_local_db, img_local_abs] = ...
    postprocess_tfm_image(img_local, params.post);


%% ================== 汇总输出 ==================

results = struct();

results.img_global = img_global;
results.img_global_abs = img_global_abs;
results.img_global_norm = img_global_norm;
results.img_global_db = img_global_db;

results.img_local = img_local;
results.img_local_abs = img_local_abs;
results.img_local_norm = img_local_norm;
results.img_local_db = img_local_db;

results.x_grid_global = x_grid_global;
results.z_grid_global = z_grid_global;

results.x_grid_local = x_grid_local;
results.z_grid_local = z_grid_local;

results.mask_global = mask_global;
results.roi_range = roi_range;
results.defect_info = defect_info;

results.info_global = info_global;
results.info_local = info_local;

results.time_global = time_global;
results.time_local = time_local;

results.backend = backend;

end
