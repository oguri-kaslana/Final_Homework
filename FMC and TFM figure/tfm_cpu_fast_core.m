function [img, info] = tfm_cpu_fast_core(fmc, fs, c, x_el, x_grid, z_grid, params)
%% =========================================================
% tfm_cpu_fast_core
%
% CPU 优化版 TFM 核心函数。
%
% 优化策略：
%   1. 预计算所有像素点到所有阵元的距离 D(pixel, elem)
%   2. 将 fmc(sample, tx, rx) 展开为 fmc2(sample, channel)
%   3. 分块向量化处理像素点
%   4. 使用手动线性插值，避免内层循环反复调用 interp1
%   5. 可选 parfor 并行 block
%
% 输入：
%   fmc    : fmc(sample, tx, rx)
%   fs     : 采样频率，Hz
%   c      : 声速，m/s
%   x_el   : 阵元横向坐标，m
%   x_grid : 成像横向网格，m
%   z_grid : 成像深度网格，m
%   params : TFM 参数
%
% 输出：
%   img  : TFM 图像，大小为 length(z_grid) × length(x_grid)
%   info : 计算信息结构体
%% =========================================================

if nargin < 7 || isempty(params)
    params = struct();
end

%% ================== 默认参数 ==================

params = set_default_field(params, 'block_size', 1500);
% 每个像素 block 中包含的像素点数。
% 调大：矩阵化程度更高，可能更快，但内存占用增加。
% 调小：更省内存，但 block 数增加。

params = set_default_field(params, 'channel_block_size', 512);
% 每次处理的 tx-rx 通道数。
% 64 阵元 FMC 共 4096 通道。
% 调大：速度可能更快，但内存占用更大。
% 调小：更稳，但循环次数更多。

params = set_default_field(params, 'use_parfor', true);
% 是否使用 parfor 并行处理像素 block。

params = set_default_field(params, 'calc_class', 'single');
% 核心计算数据类型。
% single：更快、更省内存。
% double：精度更高。

calc_class = lower(params.calc_class);

if ~ismember(calc_class, {'single', 'double'})
    warning('未知 calc_class，已改为 single。');
    calc_class = 'single';
end


%% ================== 数据尺寸检查 ==================

[nSamples, nTx, nRx] = size(fmc);
nElem = numel(x_el);

if nTx ~= nElem || nRx ~= nElem
    error('阵元数量不一致：size(fmc) = [%d, %d, %d]，length(x_el) = %d。', ...
        nSamples, nTx, nRx, nElem);
end


%% ================== 展开成像网格 ==================

[X, Z] = meshgrid(x_grid, z_grid);

x_pixel = cast(X(:), calc_class);
z_pixel = cast(Z(:), calc_class);

nPixel = numel(x_pixel);
nx = numel(x_grid);
nz = numel(z_grid);


%% ================== 预计算距离矩阵 D(pixel, elem) ==================

fprintf('CPU TFM：预计算距离矩阵 D(pixel, elem)...\n');

D = zeros(nPixel, nElem, calc_class);
x_el_c = cast(x_el(:).', calc_class);

for elem = 1:nElem
    D(:, elem) = sqrt((x_pixel - x_el_c(elem)).^2 + z_pixel.^2);
end


%% ================== FMC 展开为二维通道矩阵 ==================

fmc2 = reshape(cast(fmc, calc_class), nSamples, nTx * nRx);
% fmc2(sample, channel)
% channel = tx + (rx - 1) * nTx

[TX, RX] = ndgrid(1:nTx, 1:nRx);
tx_ch = TX(:).';
rx_ch = RX(:).';
nChannel = numel(tx_ch);


%% ================== 分块设置 ==================

block_size = params.block_size;
channel_block_size = params.channel_block_size;

block_starts = 1:block_size:nPixel;
nBlock = numel(block_starts);

out_blocks = cell(nBlock, 1);
idx_blocks = cell(nBlock, 1);

fs_over_c = cast(fs / c, calc_class);

fprintf('CPU TFM：nPixel = %d, nChannel = %d, nBlock = %d\n', ...
    nPixel, nChannel, nBlock);


%% ================== 分块计算 ==================

if params.use_parfor && license('test', 'Distrib_Computing_Toolbox')

    pool = gcp('nocreate');
    if isempty(pool)
        try
            parpool;
        catch
            warning('无法启动并行池，改用普通 for 循环。');
        end
    end

end

use_real_parfor = params.use_parfor && ~isempty(gcp('nocreate'));

if use_real_parfor

    parfor ib = 1:nBlock
        [idx_blocks{ib}, out_blocks{ib}] = compute_one_block( ...
            ib, block_starts, block_size, nPixel, ...
            D, fmc2, tx_ch, rx_ch, nSamples, nChannel, ...
            channel_block_size, fs_over_c, calc_class);
    end

else

    for ib = 1:nBlock
        [idx_blocks{ib}, out_blocks{ib}] = compute_one_block( ...
            ib, block_starts, block_size, nPixel, ...
            D, fmc2, tx_ch, rx_ch, nSamples, nChannel, ...
            channel_block_size, fs_over_c, calc_class);
    end

end


%% ================== 拼接图像 ==================

img_vec = zeros(nPixel, 1, calc_class);

for ib = 1:nBlock
    img_vec(idx_blocks{ib}) = out_blocks{ib};
end

img = reshape(img_vec, nz, nx);


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
info.use_parfor = use_real_parfor;
info.calc_class = calc_class;
info.backend = 'cpu';

end


function [p_idx, pixel_value] = compute_one_block( ...
    ib, block_starts, block_size, nPixel, ...
    D, fmc2, tx_ch, rx_ch, nSamples, nChannel, ...
    channel_block_size, fs_over_c, calc_class)
%% 计算一个像素 block 的 TFM 值

p0 = block_starts(ib);
p1 = min(p0 + block_size - 1, nPixel);
p_idx = p0:p1;

nB = numel(p_idx);
pixel_value = zeros(nB, 1, calc_class);

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

    lin0 = double(idx0_safe) + (double(ch_idx) - 1) * double(nSamples);
    lin1 = lin0 + 1;

    s0 = fmc2(lin0);
    s1 = fmc2(lin1);

    amp = (1 - alpha) .* s0 + alpha .* s1;
    amp(~valid) = 0;

    pixel_value = pixel_value + sum(amp, 2);

end

end
