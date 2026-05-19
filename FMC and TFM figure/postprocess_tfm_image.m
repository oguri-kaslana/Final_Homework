function [img_norm, img_db, img_abs] = postprocess_tfm_image(img, params)
%% =========================================================
% postprocess_tfm_image
%
% 作用：
%   对 TFM 图像进行后处理：取绝对值、归一化、dB 转换。
%
% 输入：
%   img    : 原始 TFM 图像
%   params : 后处理参数
%
% 输出：
%   img_norm : 线性归一化图，范围通常为 0~1
%   img_db   : dB 图，最大值约为 0 dB
%   img_abs  : 绝对值图
%% =========================================================

if nargin < 2 || isempty(params)
    params = struct();
end

params = set_default_field(params, 'use_abs', true);
% 是否取绝对值。

params = set_default_field(params, 'normalize', true);
% 是否归一化。

params = set_default_field(params, 'use_db', true);
% 是否生成 dB 图。


%% ================== 取绝对值 ==================

if params.use_abs
    img_abs = abs(img);
else
    img_abs = img;
end


%% ================== 归一化 ==================

if params.normalize
    max_val = max(abs(img_abs(:)));

    if max_val > 0
        img_norm = img_abs / max_val;
    else
        img_norm = img_abs;
    end
else
    img_norm = img_abs;
end


%% ================== dB 转换 ==================

if params.use_db
    img_db = 20 * log10(abs(img_norm) + eps);
else
    img_db = img_norm;
end

end
