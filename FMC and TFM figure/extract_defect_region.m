function [mask, roi_range, info] = extract_defect_region(img_norm, x_grid, z_grid, params)
%% =========================================================
% extract_defect_region
%
% 作用：
%   从全局 TFM 归一化图像中提取疑似缺陷区域，并给出局部 TFM 的 ROI。
%
% 输入：
%   img_norm : 归一化 TFM 图像，范围通常为 0~1
%   x_grid   : 图像 x 坐标，单位 m
%   z_grid   : 图像 z 坐标，单位 m
%   params   : 缺陷提取参数
%
% 输出：
%   mask      : 缺陷二值掩膜
%   roi_range : 局部 TFM 成像范围，包含 roi_range.x 和 roi_range.z
%   info      : 缺陷提取信息
%% =========================================================

if nargin < 4 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'threshold', 0.6);
% 缺陷阈值，范围 0~1。
% 调大：只保留强反射，误检少，但可能漏检弱缺陷。
% 调小：保留更多区域，但可能引入设备噪声。

params = set_default_field(params, 'min_area', 50);
% 最小连通区域面积，单位像素。
% 调大：去除更多小噪声，但可能删除小缺陷。
% 调小：保留小缺陷，但噪声更多。

params = set_default_field(params, 'x_valid_range', [min(x_grid), max(x_grid)]);
% 有效横向搜索范围，单位 m。

params = set_default_field(params, 'z_valid_range', [min(z_grid), max(z_grid)]);
% 有效深度搜索范围，单位 m。
% 可用于排除上方设备伪影或表面强反射。

params = set_default_field(params, 'margin_x', 2e-3);
% ROI 横向扩展距离，单位 m。

params = set_default_field(params, 'margin_z', 2e-3);
% ROI 深度扩展距离，单位 m。

params = set_default_field(params, 'use_largest_region_only', true);
% 是否只选择最大连通区域。


%% ================== 有效区域限制 ==================

x_grid = x_grid(:).';
z_grid = z_grid(:);

x_valid = x_grid >= params.x_valid_range(1) & x_grid <= params.x_valid_range(2);
z_valid = z_grid >= params.z_valid_range(1) & z_grid <= params.z_valid_range(2);

valid_map = z_valid * x_valid;


%% ================== 阈值分割 ==================

mask = img_norm > params.threshold;
mask(~valid_map) = false;


%% ================== 去除小连通域 ==================

if exist('bwareaopen', 'file') == 2
    mask = bwareaopen(mask, params.min_area);
else
    warning('未找到 bwareaopen，跳过去小区域步骤。');
end


%% ================== 连通域分析 ==================

info = struct();
info.threshold = params.threshold;
info.min_area = params.min_area;
info.found_defect = false;

CC = bwconncomp(mask);

if CC.NumObjects == 0
    warning('未检测到满足条件的缺陷区域，将使用有效区域内最大亮点附近作为默认 ROI。');

    img_tmp = img_norm;
    img_tmp(~valid_map) = -inf;

    [~, idx_max] = max(img_tmp(:));
    [row_c, col_c] = ind2sub(size(img_norm), idx_max);

    x_c = x_grid(col_c);
    z_c = z_grid(row_c);

    roi_range.x = [x_c - params.margin_x, x_c + params.margin_x];
    roi_range.z = [z_c - params.margin_z, z_c + params.margin_z];

    roi_range.x = [max(roi_range.x(1), min(x_grid)), min(roi_range.x(2), max(x_grid))];
    roi_range.z = [max(roi_range.z(1), min(z_grid)), min(roi_range.z(2), max(z_grid))];

    info.message = '未找到连通缺陷区域，使用最大亮点附近默认 ROI。';
    info.max_point_x_m = x_c;
    info.max_point_z_m = z_c;

    return;
end

stats = regionprops(CC, 'Area', 'BoundingBox', 'Centroid', 'PixelIdxList');

areas = [stats.Area];

if params.use_largest_region_only
    [~, selected_idx] = max(areas);
else
    [~, selected_idx] = max(areas);
    % 当前版本仍默认选择最大区域。
    % 多缺陷版本后续可在这里扩展为多个 ROI。
end

main_region = stats(selected_idx);


%% ================== bbox 像素坐标转换为物理坐标 ==================

bbox = main_region.BoundingBox;
% bbox = [col_min, row_min, width, height]

col1 = max(1, floor(bbox(1)));
row1 = max(1, floor(bbox(2)));
col2 = min(numel(x_grid), ceil(bbox(1) + bbox(3) - 1));
row2 = min(numel(z_grid), ceil(bbox(2) + bbox(4) - 1));

x_roi = [x_grid(col1), x_grid(col2)];
z_roi = [z_grid(row1), z_grid(row2)];

x_roi = [x_roi(1) - params.margin_x, x_roi(2) + params.margin_x];
z_roi = [z_roi(1) - params.margin_z, z_roi(2) + params.margin_z];

x_roi = [max(x_roi(1), min(x_grid)), min(x_roi(2), max(x_grid))];
z_roi = [max(z_roi(1), min(z_grid)), min(z_roi(2), max(z_grid))];

roi_range = struct();
roi_range.x = x_roi;
roi_range.z = z_roi;


%% ================== 输出信息 ==================

info.found_defect = true;
info.num_regions = CC.NumObjects;
info.selected_region_index = selected_idx;
info.selected_area_pixel = main_region.Area;
info.bbox_pixel = bbox;
info.centroid_pixel = main_region.Centroid;
info.roi_range = roi_range;

end
