function gpu_quick_test()
%% =========================================================
% gpu_quick_test
%
% 作用：
%   快速测试 MATLAB 是否能正常调用 GPU，并对比 CPU/GPU 矩阵乘法速度。
%% =========================================================

clearvars -except ans; clc;

fprintf('=== GPU 信息 ===\n');
try
    g = gpuDevice;
    disp(g);
catch ME
    fprintf('无法获取 GPU：%s\n', ME.message);
    return;
end

fprintf('=== CPU/GPU 基础矩阵乘法测试 ===\n');

N = 4000;

A_cpu = rand(N, N, 'single');
B_cpu = rand(N, N, 'single');

tic;
C_cpu = A_cpu * B_cpu;
t_cpu = toc;

A_gpu = gpuArray(A_cpu);
B_gpu = gpuArray(B_cpu);

wait(g);
tic;
C_gpu = A_gpu * B_gpu;
wait(g);
t_gpu = toc;

tic;
C_back = gather(C_gpu);
t_gather = toc;

rel_err = norm(C_cpu(:) - C_back(:)) / norm(C_cpu(:));

fprintf('CPU 矩阵乘法用时: %.4f s\n', t_cpu);
fprintf('GPU 矩阵乘法用时: %.4f s\n', t_gpu);
fprintf('GPU gather 回传用时: %.4f s\n', t_gather);
fprintf('CPU/GPU 相对误差: %.6e\n', rel_err);

end
