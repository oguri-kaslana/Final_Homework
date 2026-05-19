function save_tfm_results(results, params)
%% =========================================================
% save_tfm_results
%
% 作用：
%   保存 TFM 成像结果、后处理图像、mask、缺陷特征、运行时间和参数。
%
% 输入：
%   results : 结果结构体
%   params  : 保存参数结构体
%% =========================================================

if nargin < 2 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'output_root', fullfile(pwd, 'results'));
% 结果保存根目录。

params = set_default_field(params, 'case_name', ['case_', datestr(now, 'yyyymmdd_HHMMSS')]);
% 当前实验名称。

params = set_default_field(params, 'save_mat', true);
% 是否保存 MATLAB 数据。

params = set_default_field(params, 'save_png', true);
% 是否保存 PNG 图像。

params = set_default_field(params, 'save_csv', true);
% 是否保存 CSV 表格。

params = set_default_field(params, 'save_params', true);
% 是否保存参数结构体。

params = set_default_field(params, 'image_dpi', 300);
% 带坐标轴图像导出分辨率，单位 dpi。


%% ================== 建立目录 ==================

output_dir = fullfile(params.output_root, params.case_name);
mat_dir = fullfile(output_dir, 'mat_data');
fig_dir = fullfile(output_dir, 'figures');
table_dir = fullfile(output_dir, 'tables');
config_dir = fullfile(output_dir, 'config');

make_dir(output_dir);
make_dir(mat_dir);
make_dir(fig_dir);
make_dir(table_dir);
make_dir(config_dir);


%% ================== 保存 MAT 数据 ==================

if params.save_mat

    save(fullfile(mat_dir, 'tfm_results.mat'), 'results', '-v7.3');

    if isfield(results, 'mask_global')
        mask_global = results.mask_global; %#ok<NASGU>
        save(fullfile(mat_dir, 'defect_mask.mat'), 'mask_global');
    end

end


%% ================== 保存 PNG 图像 ==================

if params.save_png

    if isfield(results, 'img_global_norm')
        imwrite(to_uint8_image(results.img_global_norm), ...
            fullfile(fig_dir, 'global_tfm_norm.png'));
    end

    if isfield(results, 'img_global_db')
        imwrite(to_uint8_image(results.img_global_db), ...
            fullfile(fig_dir, 'global_tfm_db.png'));
    end

    if isfield(results, 'img_local_norm')
        imwrite(to_uint8_image(results.img_local_norm), ...
            fullfile(fig_dir, 'local_tfm_norm.png'));
    end

    if isfield(results, 'img_local_db')
        imwrite(to_uint8_image(results.img_local_db), ...
            fullfile(fig_dir, 'local_tfm_db.png'));
    end

    if isfield(results, 'mask_global')
        imwrite(uint8(results.mask_global) * 255, ...
            fullfile(fig_dir, 'defect_mask.png'));
    end

    % 保存带坐标轴的报告图
    try
        if isfield(results, 'img_global_db')
            export_axis_figure(results.img_global_db, results.x_grid_global, results.z_grid_global, ...
                'Global TFM Image / dB', fullfile(fig_dir, 'global_tfm_db_with_axis.png'), params.image_dpi);
        end

        if isfield(results, 'img_local_db')
            export_axis_figure(results.img_local_db, results.x_grid_local, results.z_grid_local, ...
                'Local TFM Image / dB', fullfile(fig_dir, 'local_tfm_db_with_axis.png'), params.image_dpi);
        end
    catch ME
        warning('带坐标轴图像导出失败：%s', ME.message);
    end

end


%% ================== 保存特征与运行时间表 ==================

if params.save_csv

    if isfield(results, 'features')
        features = results.features;

        try
            feature_table = struct2table(features);
            writetable(feature_table, fullfile(table_dir, 'defect_features.csv'));
        catch
            warning('features 无法转换为 table，已跳过 CSV 保存。');
        end
    end

    runtime_table = table();

    if isfield(results, 'time_preprocess')
        runtime_table.time_preprocess_s = results.time_preprocess;
    end

    if isfield(results, 'time_global')
        runtime_table.time_global_tfm_s = results.time_global;
    end

    if isfield(results, 'time_local')
        runtime_table.time_local_tfm_s = results.time_local;
    end

    if ~isempty(runtime_table)
        writetable(runtime_table, fullfile(table_dir, 'runtime_table.csv'));
    end

end


%% ================== 保存参数 ==================

if params.save_params

    if isfield(results, 'params')
        all_params = results.params; %#ok<NASGU>
        save(fullfile(config_dir, 'params.mat'), 'all_params');
    end

    fid = fopen(fullfile(config_dir, 'readme.txt'), 'w');
    if fid > 0
        fprintf(fid, 'FMC-TFM result folder\n');
        fprintf(fid, 'Case name: %s\n', params.case_name);
        fprintf(fid, 'Created at: %s\n', datestr(now));

        if isfield(results, 'backend')
            fprintf(fid, 'TFM backend: %s\n', results.backend);
        end

        fclose(fid);
    end

end

fprintf('结果已保存到：%s\n', output_dir);

end


function make_dir(folder)
if ~exist(folder, 'dir')
    mkdir(folder);
end
end


function img_uint8 = to_uint8_image(img)
img_norm = mat2gray(img);
img_uint8 = uint8(255 * img_norm);
end


function export_axis_figure(img, x_grid, z_grid, title_name, file_name, dpi)
fig = figure('Visible', 'off');
imagesc(x_grid * 1e3, z_grid * 1e3, img);
axis image;
set(gca, 'YDir', 'normal');
colorbar;
xlabel('x / mm');
ylabel('z / mm');
title(title_name, 'Interpreter', 'none');

if min(img(:)) < 0
    caxis([-40, 0]);
end

exportgraphics(fig, file_name, 'Resolution', dpi);
close(fig);
end
