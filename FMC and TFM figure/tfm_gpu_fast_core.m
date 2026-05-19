function [img, info] = tfm_gpu_fast_core(fmc, fs, c, x_el, x_grid, z_grid, params)
%% =========================================================
% tfm_gpu_fast_core
%
% GPU 优化版 TFM 核心函数。
%
% 优化策略：
%   1. 将 fmc(sample, tx, rx) 展开为 fmc2(sample, channel)
%   2. 在 GPU 上预计算距离矩阵 D(pixel, elem)
%   3. 按像素 block 和通道 block 分块向量化
%   4. 中间过程尽量留在 GPU 上
%   5. 最后只 gather 最终图像
%
% 注意：
%   GPU 是否更快取决于显卡性能、显存、block_size、channel_block_size
%   以及是否避免了频繁 gather。
%% =========================================================

if nargin < 7 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'block_size', 1500);
% 每个像素 block 中包含的像素点数。
% 调大：GPU 矩阵化程度更高，但显存占用增加。
% 调小：更稳，但 GPU 利用率可能降低。

params = set_default_field(params, 'channel_block_size', 512);
% 每次处理的 tx-rx 通道数。
% 调大：速度可能更快，但显存占用更高。
% 调小：更省显存，但循环次数增加。

params = set_default_field(params, 'calc_class', 'single');
% GPU 计算数据类型。
% single：通常更快，显存占用低。
% double：精度高，但很多消费级 GPU 双精度性能较弱。

calc_class = lower(params.calc_class);

if ~ismember(calc_class, {'single', 'double'})
    warning('未知 calc_class，已改为 single。');
    calc_class = 'single';
end


%% ================== GPU 检查 ==================

try
    g = gpuDevice;
catch ME
    error('无法使用 GPU。请检查 Parallel Computing Toolbox、显卡驱动和 MATLAB GPU 支持。原始错误：%s', ME.message);
end

fprintf('GPU TFM：使用 GPU：%s\n', g.Name);


%% ================== 数据尺寸检查 ==================

[nSamples, nTx, nRx] = size(fmc);
nElem = numel(x_el);

if nTx ~= nElem || nRx ~= nElem
    error('阵元数量不一致：size(fmc) = [%d, %d, %d]，length(x_el) = %d。', ...
        nSamples, nTx, nRx, nElem);
end


%% ================== 展开成像网格 ==================

[X, Z] = meshgrid(x_grid, z_grid);

x_pixel = gpuArray(cast(X(:), calc_class));
z_pixel = gpuArray(cast(Z(:), calc_class));

nPixel = numel(X);
nx = numel(x_grid);
nz = numel(z_grid);


%% ================== GPU 上预计算距离矩阵 ==================

fprintf('GPU TFM：预计算距离矩阵 D(pixel, elem)...\n');

D = gpuArray.zeros(nPixel, nElem, calc_class);
x_el_gpu = gpuArray(cast(x_el(:).', calc_class));

for elem = 1:nElem
    D(:, elem) = sqrt((x_pixel - x_el_gpu(elem)).^2 + z_pixel.^2);
end


%% ================== FMC 展开为二维通道矩阵，并放到 GPU ==================

fmc2 = reshape(cast(fmc, calc_class), nSamples, nTx * nRx);
fmc2_gpu = gpuArray(fmc2);
clear fmc2;

[TX, RX] = ndgrid(1:nTx, 1:nRx);
tx_ch = TX(:).';
rx_ch = RX(:).';
nChannel = numel(tx_ch);


%% ================== 分块设置 ==================

block_size = params.block_size;
channel_block_size = params.channel_block_size;

block_starts = 1:block_size:nPixel;
nBlock = numel(block_starts);

fs_over_c = gpuArray(cast(fs / c, calc_class));

img_vec_gpu = gpuArray.zeros(nPixel, 1, calc_class);

fprintf('GPU TFM：nPixel = %d, nChannel = %d, nBlock = %d\n', ...
    nPixel, nChannel, nBlock);


%% ================== 分块计算 ==================

for ib = 1:nBlock

    p0 = block_starts(ib);
    p1 = min(p0 + block_size - 1, nPixel);
    p_idx = p0:p1;

    nB = numel(p_idx);
    pixel_value = gpuArray.zeros(nB, 1, calc_class);

    D_block = D(p_idx, :);

    for ch0 = 1:channel_block_size:nChannel

        ch1 = min(ch0 + channel_block_size - 1, nChannel);
        ch_idx = ch0:ch1;

        d_total = D_block(:, tx_ch(ch_idx)) + D_block(:, rx_ch(ch_idx));

        sample_pos = d_total * fs_over_c + 1;

        idx0 = floor(sample_pos);
        alpha = sample_pos - idx0;

        valid = idx0 >= 1 & idx0 < nSamples;

        idx0_safe = idx0;
        idx0_safe(~valid) = 1;

        % 线性索引：fmc2(sample, channel)
        % 这里用 GPU 上的 double 索引，避免频繁 gather。
        ch_offset = gpuArray(double((ch_idx - 1) * nSamples));
        lin0 = double(idx0_safe) + ch_offset;
        lin1 = lin0 + 1;

        s0 = fmc2_gpu(lin0);
        s1 = fmc2_gpu(lin1);

        amp = (1 - alpha) .* s0 + alpha .* s1;
        amp(~valid) = 0;

        pixel_value = pixel_value + sum(amp, 2);

    end

    img_vec_gpu(p_idx) = pixel_value;

end

wait(g);

img = reshape(gather(img_vec_gpu), nz, nx);


%% ================== 输出信息 ==================

info = struct();
info.nSamples = nSamples;
info.nTx = nTx;
info.nRx = nRx;
info.nPixel = nPixel;
info.nChannel = nChannel;
info.nBlock = nBlock;
info.block_size = block_size;
info.channel_block_size = channel_block_size;
info.calc_class = calc_class;
info.backend = 'gpu';
info.gpu_name = g.Name;
info.gpu_available_memory = g.AvailableMemory;
info.gpu_total_memory = g.TotalMemory;

end
