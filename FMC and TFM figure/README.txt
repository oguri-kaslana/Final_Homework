FMC_TFM_final_code
==================

本文件夹包含一套整理后的 MATLAB FMC-TFM 成像代码。

主要文件：

1. A_main.m
   主程序。直接读取 fmc.mat，不正式调用 standardize_fmc_data。
   声速、采样率、阵元间距、TFM 范围、缺陷提取阈值等参数都集中在开头。

2. preprocess_fmc_data.m
   FMC 预处理函数：去直流、带通滤波、可选包络、可选归一化。

3. run_tfm_global_local.m
   统一运行全局 TFM 和局部 TFM。
   全局/局部共用同一个 TFM 核心函数，只是成像网格不同。

4. tfm_cpu_fast_core.m
   CPU 优化版 TFM 核心。
   已采用：距离预计算、fmc2 展开、分块向量化、可选 parfor。

5. tfm_gpu_fast_core.m
   GPU 优化版 TFM 核心。
   已采用：GPU 距离预计算、fmc2 展开、分块矩阵计算、最后 gather。

6. postprocess_tfm_image.m
   TFM 图像后处理：取 abs、归一化、dB 转换。

7. extract_defect_region.m
   从全局 TFM 图像提取缺陷 mask 和局部 ROI。
   包含有效深度范围限制，用于排除上方设备伪影。

8. analyze_defect_features.m
   计算缺陷面积、中心位置、尺寸、强度、能量等特征。

9. show_tfm_image.m
   显示 TFM 图像，坐标单位为 mm。

10. save_tfm_results.m
    保存结果图像、MAT 文件、特征表、运行时间和参数。

11. gpu_quick_test.m
    GPU 快速测试函数，用于检查 MATLAB GPU 能否正常工作。

12. run_tfm_realtime_pipeline_demo.m
    实时流水线示例接口。
    思路：global 处理当前帧，local 处理上一帧 ROI。

使用方式：

1. 将本文件夹放到你的项目目录中。
2. 保证 fmc.mat 位于 A_main.m 的上一级目录，或者在 A_main.m 中修改 fmc_file。
3. 在 A_main.m 中修改 fs、c、pitch、成像范围等参数。
4. 运行 A_main.m。

注意：

- 数据格式统一为 fmc(sample, tx, rx)。
- GPU 版本是否更快取决于显卡性能、显存和 block 参数。
- 如果内存不足，优先调小 block_size 和 channel_block_size。
- 如果上方设备伪影被误提取为缺陷，请增大 params.defect.z_valid_range 的下限。
