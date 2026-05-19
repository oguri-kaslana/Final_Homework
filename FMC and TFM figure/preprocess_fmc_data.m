function fmc_out = preprocess_fmc_data(fmc, fs, params)
%% =========================================================
% preprocess_fmc_data
%
% 作用：
%   对 FMC 数据进行预处理，包括去直流、带通滤波、可选包络、
%   可选归一化。
%
% 输入：
%   fmc    : 原始 FMC 数据，格式 fmc(sample, tx, rx)
%   fs     : 采样频率，单位 Hz
%   params : 预处理参数结构体
%
% 输出：
%   fmc_out : 预处理后的 FMC 数据，格式仍为 fmc(sample, tx, rx)
%% =========================================================

if nargin < 3 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'remove_dc', true);
% 是否去直流。
% true：推荐，去除每条 A 扫信号的均值偏置。

params = set_default_field(params, 'use_bandpass', true);
% 是否使用带通滤波。

params = set_default_field(params, 'filter_order', 4);
% Butterworth 滤波器阶数。

params = set_default_field(params, 'f_low', 1e6);
% 带通下限频率，单位 Hz。

params = set_default_field(params, 'f_high', 10e6);
% 带通上限频率，单位 Hz。

params = set_default_field(params, 'use_envelope', false);
% 是否在预处理阶段做 Hilbert 包络。

params = set_default_field(params, 'normalize_fmc', false);
% 是否对整个 FMC 数据归一化。

params = set_default_field(params, 'output_class', 'single');
% 输出数据类型，'single' 或 'double'。


%% ================== 数据尺寸 ==================

[nSamples, nTx, nRx] = size(fmc);

fmc_work = double(fmc);
% 滤波阶段使用 double，避免整数或低精度数据影响滤波。


%% ================== 去直流 ==================

if params.remove_dc
    fmc_work = fmc_work - mean(fmc_work, 1);
end


%% ================== 展开为二维通道矩阵 ==================

fmc2 = reshape(fmc_work, nSamples, nTx * nRx);
% fmc2(sample, channel)
% channel = tx + (rx - 1) * nTx


%% ================== 带通滤波 ==================

if params.use_bandpass

    nyq = fs / 2;

    f_low = max(params.f_low, 1);
    f_high = min(params.f_high, 0.98 * nyq);

    if f_high <= f_low
        warning('带通滤波频率设置不合理，已跳过滤波。');
    else
        Wn = [f_low, f_high] / nyq;

        [b, a] = butter(params.filter_order, Wn, 'bandpass');

        % filtfilt 沿第一维对每个通道进行零相位滤波。
        % 优点：不会引入明显相位延迟，适合 TFM 延时叠加。
        fmc2 = filtfilt(b, a, fmc2);
    end

end


%% ================== 可选 Hilbert 包络 ==================

if params.use_envelope
    fmc2 = abs(hilbert(fmc2));
end


%% ================== 恢复三维 FMC 格式 ==================

fmc_out = reshape(fmc2, nSamples, nTx, nRx);


%% ================== 可选归一化 ==================

if params.normalize_fmc
    max_val = max(abs(fmc_out(:)));

    if max_val > 0
        fmc_out = fmc_out / max_val;
    end
end


%% ================== 输出数据类型 ==================

switch lower(params.output_class)
    case 'single'
        fmc_out = single(fmc_out);
    case 'double'
        fmc_out = double(fmc_out);
    otherwise
        warning('未知 output_class，默认输出 single。');
        fmc_out = single(fmc_out);
end

end
