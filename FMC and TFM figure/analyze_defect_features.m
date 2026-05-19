function features = analyze_defect_features(img_norm, mask, x_grid, z_grid, params)
%% =========================================================
% analyze_defect_features
%
% 作用：
%   根据缺陷 mask 和 TFM 图像计算缺陷工程特征。
%
% 输入：
%   img_norm : 归一化 TFM 图像
%   mask     : 缺陷二值掩膜
%   x_grid   : x 方向坐标，单位 m
%   z_grid   : z 方向坐标，单位 m
%   params   : 特征分析参数
%
% 输出：
%   features : 缺陷特征结构体
%% =========================================================

if nargin < 5 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'min_area_pixel', 50);
% 最小有效缺陷面积，单位像素。

params = set_default_field(params, 'use_largest_region_only', true);
% 是否只分析最大连通域。

params = set_default_field(params, 'unit_scale', 1e3);
% 长度单位换算系数。
% 坐标单位为 m 时，乘 1e3 得到 mm。


%% ================== 初始化输出 ==================

features = struct();
features.valid = false;
features.message = '';


%% ================== mask 预处理 ==================

if isempty(mask) || ~any(mask(:))
    features.message = 'mask 为空或没有检测到缺陷区域。';
    warning(features.message);
    return;
end

if exist('bwareaopen', 'file') == 2
    mask = bwareaopen(mask, params.min_area_pixel);
end

if ~any(mask(:))
    features.message = '去除小区域后没有剩余缺陷区域。';
    warning(features.message);
    return;
end


%% ================== 连通域分析 ==================

CC = bwconncomp(mask);
stats = regionprops(CC, 'Area', 'BoundingBox', 'Centroid', 'PixelIdxList');

if isempty(stats)
    features.message = 'regionprops 未得到有效区域。';
    warning(features.message);
    return;
end

areas = [stats.Area];

if params.use_largest_region_only
    [~, idx] = max(areas);
else
    [~, idx] = max(areas);
    % 当前版本仍返回最大区域。
    % 多缺陷特征表可后续扩展。
end

main_region = stats(idx);


%% ================== 坐标与面积单位换算 ==================

x_grid = x_grid(:).';
z_grid = z_grid(:);

dx_m = mean(diff(x_grid));
dz_m = mean(diff(z_grid));

dx_mm = dx_m * params.unit_scale;
dz_mm = dz_m * params.unit_scale;

pixel_area_mm2 = dx_mm * dz_mm;


%% ================== 强度特征 ==================

defect_values = img_norm(main_region.PixelIdxList);

max_intensity = max(defect_values);
mean_intensity = mean(defect_values);
std_intensity = std(defect_values);
energy = sum(defect_values .^ 2);


%% ================== 尺寸与中心位置 ==================

bbox = main_region.BoundingBox;
% bbox = [col_min, row_min, width_pixel, height_pixel]

width_mm = bbox(3) * dx_mm;
height_mm = bbox(4) * dz_mm;
aspect_ratio = width_mm / max(height_mm, eps);

centroid = main_region.Centroid;
col_c = min(max(round(centroid(1)), 1), numel(x_grid));
row_c = min(max(round(centroid(2)), 1), numel(z_grid));

center_x_mm = x_grid(col_c) * params.unit_scale;
center_z_mm = z_grid(row_c) * params.unit_scale;


%% ================== 汇总输出 ==================

features.valid = true;
features.message = '缺陷特征分析完成。';
features.region_index = idx;
features.num_regions = CC.NumObjects;

features.area_pixel = main_region.Area;
features.area_mm2 = main_region.Area * pixel_area_mm2;

features.center_x_mm = center_x_mm;
features.center_z_mm = center_z_mm;

features.width_mm = width_mm;
features.height_mm = height_mm;
features.aspect_ratio = aspect_ratio;

features.max_intensity = max_intensity;
features.mean_intensity = mean_intensity;
features.std_intensity = std_intensity;
features.energy = energy;

features.bbox_pixel = bbox;
features.centroid_pixel = centroid;

end
