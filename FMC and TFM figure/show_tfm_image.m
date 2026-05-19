function show_tfm_image(img_show, x_grid, z_grid, title_name, params)
%% =========================================================
% show_tfm_image
%
% 作用：
%   显示 TFM 图像，并使用真实物理坐标。
%
% 输入：
%   img_show   : 待显示图像
%   x_grid     : x 坐标，单位 m
%   z_grid     : z 坐标，单位 m
%   title_name : 图像标题
%   params     : 显示参数，可为空
%% =========================================================

if nargin < 5
    params = [];
end

figure;
imagesc(x_grid * 1e3, z_grid * 1e3, img_show);
axis image;
set(gca, 'YDir', 'normal');
colorbar;
xlabel('x / mm');
ylabel('z / mm');
title(title_name, 'Interpreter', 'none');

if ~isempty(params) && isstruct(params) && isfield(params, 'db_range')
    if min(img_show(:)) < 0
        caxis(params.db_range);
    end
end

end
